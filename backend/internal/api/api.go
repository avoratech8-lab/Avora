// Package api exposes the backend over HTTP/JSON. All amounts are integer
// kobo (₦1 = 100).
//
// Not yet production ready: there is no user authentication. Every route
// except /healthz and the signed webhook must sit behind auth before launch.
package api

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"strconv"

	"github.com/jackc/pgx/v5/pgxpool"

	"avora/backend/internal/inbound"
	"avora/backend/internal/ledger"
	"avora/backend/internal/rails"
	"avora/backend/internal/transfers"
	"avora/backend/internal/wallets"
)

type Server struct {
	DB            *pgxpool.Pool
	Rail          rails.Rail
	System        wallets.System
	Transfers     *transfers.Service
	NewNUBAN      func(ctx context.Context, userRef string) (string, error) // issued by the partner bank
	WebhookSecret string
	Log           *slog.Logger
}

func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
	})
	mux.HandleFunc("POST /v1/wallets", s.createWallet)
	mux.HandleFunc("GET /v1/wallets/{id}", s.getWallet)
	mux.HandleFunc("GET /v1/wallets/{id}/statement", s.statement)
	mux.HandleFunc("POST /v1/name-enquiry", s.nameEnquiry)
	mux.HandleFunc("POST /v1/transfers", s.createTransfer)
	mux.HandleFunc("GET /v1/transfers/{id}", s.getTransfer)
	mux.HandleFunc("POST /v1/webhooks/inbound-credit", s.inboundCredit)
	mux.HandleFunc("POST /v1/ops/transfers/{id}/resolve", s.resolveTransfer)
	return mux
}

func (s *Server) createWallet(w http.ResponseWriter, r *http.Request) {
	var body struct {
		UserRef string `json:"user_ref"`
	}
	if !readJSON(w, r, &body) {
		return
	}
	nuban, err := s.NewNUBAN(r.Context(), body.UserRef)
	if err != nil {
		s.fail(w, err)
		return
	}
	wal, err := wallets.Create(r.Context(), s.DB, body.UserRef, nuban)
	if err != nil {
		s.fail(w, err)
		return
	}
	writeJSON(w, http.StatusCreated, wal)
}

func (s *Server) getWallet(w http.ResponseWriter, r *http.Request) {
	id, ok := pathID(w, r)
	if !ok {
		return
	}
	wal, err := wallets.Get(r.Context(), s.DB, id)
	if err != nil {
		s.fail(w, err)
		return
	}
	writeJSON(w, http.StatusOK, wal)
}

func (s *Server) statement(w http.ResponseWriter, r *http.Request) {
	id, ok := pathID(w, r)
	if !ok {
		return
	}
	if _, err := wallets.Get(r.Context(), s.DB, id); err != nil {
		s.fail(w, err)
		return
	}
	limit := 50
	if v := r.URL.Query().Get("limit"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 && n <= 200 {
			limit = n
		}
	}
	lines, err := ledger.Statement(r.Context(), s.DB, id, limit)
	if err != nil {
		s.fail(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"lines": lines})
}

func (s *Server) nameEnquiry(w http.ResponseWriter, r *http.Request) {
	var body struct {
		BankCode      string `json:"bank_code"`
		AccountNumber string `json:"account_number"`
	}
	if !readJSON(w, r, &body) {
		return
	}
	name, err := s.Rail.NameEnquiry(r.Context(), body.BankCode, body.AccountNumber)
	if errors.Is(err, rails.ErrAccountNotFound) {
		writeError(w, http.StatusNotFound, "account_not_found", "No account found with that number at that bank.")
		return
	}
	if err != nil {
		s.fail(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"account_name": name})
}

func (s *Server) createTransfer(w http.ResponseWriter, r *http.Request) {
	var body struct {
		WalletID      int64  `json:"wallet_id"`
		BankCode      string `json:"bank_code"`
		AccountNumber string `json:"account_number"`
		Amount        int64  `json:"amount"`
		Narration     string `json:"narration"`
	}
	if !readJSON(w, r, &body) {
		return
	}
	t, err := s.Transfers.Initiate(r.Context(), transfers.InitiateRequest{
		IdempotencyKey:  r.Header.Get("Idempotency-Key"),
		WalletAccountID: body.WalletID,
		BankCode:        body.BankCode,
		AccountNumber:   body.AccountNumber,
		Amount:          body.Amount,
		Narration:       body.Narration,
	})
	if err != nil {
		s.fail(w, err)
		return
	}
	writeJSON(w, http.StatusOK, t)
}

func (s *Server) getTransfer(w http.ResponseWriter, r *http.Request) {
	t, err := s.Transfers.Get(r.Context(), r.PathValue("id"))
	if err != nil {
		s.fail(w, err)
		return
	}
	writeJSON(w, http.StatusOK, t)
}

func (s *Server) resolveTransfer(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Outcome   transfers.Status `json:"outcome"`
		SessionID string           `json:"session_id"`
		Note      string           `json:"note"`
	}
	if !readJSON(w, r, &body) {
		return
	}
	t, err := s.Transfers.Resolve(r.Context(), r.PathValue("id"), body.Outcome, body.SessionID, body.Note)
	if err != nil {
		s.fail(w, err)
		return
	}
	writeJSON(w, http.StatusOK, t)
}

// inboundCredit is called by the partner bank. The body must be signed with
// HMAC-SHA256 using the shared secret, hex encoded in X-Signature.
func (s *Server) inboundCredit(w http.ResponseWriter, r *http.Request) {
	raw, err := io.ReadAll(io.LimitReader(r.Body, 1<<20))
	if err != nil {
		writeError(w, http.StatusBadRequest, "bad_request", "Could not read body.")
		return
	}
	if !validSignature(s.WebhookSecret, raw, r.Header.Get("X-Signature")) {
		writeError(w, http.StatusUnauthorized, "bad_signature", "Signature does not match.")
		return
	}
	var c inbound.Credit
	if err := json.Unmarshal(raw, &c); err != nil {
		writeError(w, http.StatusBadRequest, "bad_request", "Body must be valid JSON.")
		return
	}
	res, err := inbound.Apply(r.Context(), s.DB, s.System, c)
	if err != nil {
		s.fail(w, err)
		return
	}
	writeJSON(w, http.StatusOK, res)
}

func validSignature(secret string, body []byte, got string) bool {
	if secret == "" {
		return false
	}
	mac := hmac.New(sha256.New, []byte(secret))
	mac.Write(body)
	want := hex.EncodeToString(mac.Sum(nil))
	return hmac.Equal([]byte(want), []byte(got))
}

// Sign returns the X-Signature value for body; used by tests and the sandbox.
func Sign(secret string, body []byte) string {
	mac := hmac.New(sha256.New, []byte(secret))
	mac.Write(body)
	return hex.EncodeToString(mac.Sum(nil))
}

func (s *Server) fail(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, ledger.ErrInsufficientFunds):
		writeError(w, http.StatusUnprocessableEntity, "insufficient_funds", "Your balance is too low for this transfer and its fee.")
	case errors.Is(err, transfers.ErrInvalid), errors.Is(err, inbound.ErrInvalid):
		writeError(w, http.StatusBadRequest, "invalid_request", err.Error())
	case errors.Is(err, transfers.ErrIdempotencyConflict):
		writeError(w, http.StatusConflict, "idempotency_conflict", err.Error())
	case errors.Is(err, transfers.ErrNotResolvable):
		writeError(w, http.StatusConflict, "not_resolvable", err.Error())
	case errors.Is(err, wallets.ErrExists):
		writeError(w, http.StatusConflict, "wallet_exists", "This user already has a wallet.")
	case errors.Is(err, wallets.ErrNotFound), errors.Is(err, transfers.ErrNotFound):
		writeError(w, http.StatusNotFound, "not_found", "Not found.")
	default:
		s.Log.Error("request failed", "err", err)
		writeError(w, http.StatusInternalServerError, "internal", "Something went wrong on our side. No money was lost; please try again.")
	}
}

func pathID(w http.ResponseWriter, r *http.Request) (int64, bool) {
	id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil {
		writeError(w, http.StatusNotFound, "not_found", "Not found.")
		return 0, false
	}
	return id, true
}

func readJSON(w http.ResponseWriter, r *http.Request, v any) bool {
	dec := json.NewDecoder(io.LimitReader(r.Body, 1<<20))
	dec.DisallowUnknownFields()
	if err := dec.Decode(v); err != nil {
		writeError(w, http.StatusBadRequest, "bad_request", "Body must be valid JSON with known fields.")
		return false
	}
	return true
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(v)
}

func writeError(w http.ResponseWriter, status int, code, msg string) {
	writeJSON(w, status, map[string]any{"error": map[string]string{"code": code, "message": msg}})
}
