// Package api exposes the backend over HTTP/JSON. All amounts are integer
// kobo (₦1 = 100).
//
// Customer routes need "Authorization: Bearer <token>" and "X-Device-ID"
// from the device the session was created on, and only ever see the
// signed-in user's own wallet. Ops routes need X-Ops-Key. The inbound-credit
// webhook is authenticated by its HMAC signature.
package api

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"avora/backend/internal/auth"
	"avora/backend/internal/bills"
	"avora/backend/internal/inbound"
	"avora/backend/internal/kyc"
	"avora/backend/internal/ledger"
	"avora/backend/internal/notify"
	"avora/backend/internal/rails"
	"avora/backend/internal/referrals"
	"avora/backend/internal/savings"
	"avora/backend/internal/support"
	"avora/backend/internal/transfers"
	"avora/backend/internal/wallets"
)

type Server struct {
	DB            *pgxpool.Pool
	Rail          rails.Rail
	System        wallets.System
	Transfers     *transfers.Service
	Bills         *bills.Service
	Savings       *savings.Service
	KYC           *kyc.Service
	Referrals     *referrals.Service
	Support       *support.Service
	Auth          *auth.Service
	WebhookSecret string
	OpsKey        string
	Log           *slog.Logger
	Now           func() time.Time
}

type ctxKey struct{}

func (s *Server) Handler() http.Handler {
	if s.Now == nil {
		s.Now = time.Now
	}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
	})

	mux.HandleFunc("POST /v1/auth/otp", s.startOTP)
	mux.HandleFunc("POST /v1/auth/verify", s.verifyOTP)
	mux.HandleFunc("POST /v1/auth/logout", s.signedIn(s.logout))

	mux.HandleFunc("GET /v1/me/wallet", s.signedIn(s.myWallet))
	mux.HandleFunc("GET /v1/me/statement", s.signedIn(s.statement))
	mux.HandleFunc("POST /v1/me/pin", s.signedIn(s.changePIN))
	mux.HandleFunc("POST /v1/me/pin/verify", s.signedIn(s.verifyPIN))
	mux.HandleFunc("GET /v1/me/devices", s.signedIn(s.listDevices))
	mux.HandleFunc("DELETE /v1/me/devices/{id}", s.signedIn(s.removeDevice))
	mux.HandleFunc("GET /v1/me/kyc", s.signedIn(s.kycStatus))
	mux.HandleFunc("POST /v1/me/kyc", s.signedIn(s.verifyKYC))
	mux.HandleFunc("GET /v1/me/notifications", s.signedIn(s.listNotifications))
	mux.HandleFunc("POST /v1/me/notifications/read", s.signedIn(s.readNotifications))
	mux.HandleFunc("GET /v1/me/referrals", s.signedIn(s.referralSummary))
	mux.HandleFunc("POST /v1/me/referrals", s.signedIn(s.joinReferral))
	mux.HandleFunc("GET /v1/help/articles", s.helpArticles)
	mux.HandleFunc("GET /v1/support/messages", s.signedIn(s.supportMessages))
	mux.HandleFunc("POST /v1/support/messages", s.signedIn(s.sendSupportMessage))
	mux.HandleFunc("POST /v1/name-enquiry", s.signedIn(s.nameEnquiry))
	mux.HandleFunc("POST /v1/transfers", s.signedIn(s.createTransfer))
	mux.HandleFunc("GET /v1/transfers/quote", s.signedIn(s.quoteTransfer))
	mux.HandleFunc("GET /v1/transfers/{id}", s.signedIn(s.getTransfer))

	mux.HandleFunc("GET /v1/bills/billers", s.signedIn(s.listBillers))
	mux.HandleFunc("POST /v1/bills/validate", s.signedIn(s.validateBill))
	mux.HandleFunc("POST /v1/bills/payments", s.signedIn(s.payBill))
	mux.HandleFunc("GET /v1/bills/payments/{id}", s.signedIn(s.getBillPayment))

	mux.HandleFunc("GET /v1/savings", s.signedIn(s.listSavings))
	mux.HandleFunc("POST /v1/savings", s.signedIn(s.createSavings))
	mux.HandleFunc("POST /v1/savings/{id}/deposit", s.signedIn(s.depositSavings))
	mux.HandleFunc("POST /v1/savings/{id}/withdraw", s.signedIn(s.withdrawSavings))

	mux.HandleFunc("POST /v1/webhooks/inbound-credit", s.inboundCredit)
	mux.HandleFunc("POST /v1/ops/transfers/{id}/resolve", s.opsOnly(s.resolveTransfer))
	mux.HandleFunc("POST /v1/ops/savings/profit", s.opsOnly(s.shareProfit))
	mux.HandleFunc("POST /v1/ops/support/{user_id}/reply", s.opsOnly(s.supportReply))
	return mux
}

func (s *Server) signedIn(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		token, _ := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
		p, err := s.Auth.Authenticate(r.Context(), token, r.Header.Get("X-Device-ID"))
		if err != nil {
			s.fail(w, err)
			return
		}
		next(w, r.WithContext(context.WithValue(r.Context(), ctxKey{}, p)))
	}
}

func principal(r *http.Request) auth.Principal {
	return r.Context().Value(ctxKey{}).(auth.Principal)
}

func (s *Server) opsOnly(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		got := r.Header.Get("X-Ops-Key")
		if s.OpsKey == "" || subtle.ConstantTimeCompare([]byte(got), []byte(s.OpsKey)) != 1 {
			writeError(w, http.StatusUnauthorized, "unauthorized", "Ops key required.")
			return
		}
		next(w, r)
	}
}

func (s *Server) startOTP(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Phone string `json:"phone"`
	}
	if !readJSON(w, r, &body) {
		return
	}
	id, err := s.Auth.StartOTP(r.Context(), body.Phone)
	if err != nil {
		s.fail(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"challenge_id": id})
}

func (s *Server) verifyOTP(w http.ResponseWriter, r *http.Request) {
	var body struct {
		ChallengeID string `json:"challenge_id"`
		Code        string `json:"code"`
		PIN         string `json:"pin"`
	}
	if !readJSON(w, r, &body) {
		return
	}
	sess, err := s.Auth.Verify(r.Context(), auth.VerifyRequest{
		ChallengeID: body.ChallengeID,
		Code:        body.Code,
		PIN:         body.PIN,
		DeviceID:    r.Header.Get("X-Device-ID"),
		DeviceName:  r.Header.Get("X-Device-Name"),
	})
	if err != nil {
		s.fail(w, err)
		return
	}
	writeJSON(w, http.StatusOK, sess)
}

func (s *Server) logout(w http.ResponseWriter, r *http.Request) {
	token, _ := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
	if err := s.Auth.Logout(r.Context(), token); err != nil {
		s.fail(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) myWallet(w http.ResponseWriter, r *http.Request) {
	wal, err := wallets.Get(r.Context(), s.DB, principal(r).WalletID)
	if err != nil {
		s.fail(w, err)
		return
	}
	writeJSON(w, http.StatusOK, wal)
}

func (s *Server) statement(w http.ResponseWriter, r *http.Request) {
	limit := 50
	if v := r.URL.Query().Get("limit"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 && n <= 200 {
			limit = n
		}
	}
	lines, err := ledger.Statement(r.Context(), s.DB, principal(r).WalletID, limit)
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
		BankCode      string `json:"bank_code"`
		AccountNumber string `json:"account_number"`
		Amount        int64  `json:"amount"`
		Narration     string `json:"narration"`
		PIN           string `json:"pin"`
	}
	if !readJSON(w, r, &body) {
		return
	}
	p := principal(r)
	if err := s.Auth.CheckPIN(r.Context(), p.UserID, body.PIN); err != nil {
		s.fail(w, err)
		return
	}
	if !s.withinLimits(w, r, p, body.Amount) {
		return
	}
	t, err := s.Transfers.Initiate(r.Context(), transfers.InitiateRequest{
		IdempotencyKey:  r.Header.Get("Idempotency-Key"),
		WalletAccountID: p.WalletID,
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

var lagos = time.FixedZone("WAT", 60*60)

// withinLimits applies the KYC tier's daily send limit and, for a newly
// added phone, the first-24-hours cap. Transfers and bills count together.
// It writes the error when it fails.
func (s *Server) withinLimits(w http.ResponseWriter, r *http.Request, p auth.Principal, amount int64) bool {
	ctx := r.Context()
	spentSince := func(t time.Time) (int64, error) {
		sent, err := s.Transfers.SentSince(ctx, p.WalletID, t)
		if err != nil || s.Bills == nil {
			return sent, err
		}
		paid, err := s.Bills.SpentSince(ctx, p.WalletID, t)
		return sent + paid, err
	}

	if s.KYC != nil {
		st, err := s.KYC.Status(ctx, p.UserID)
		if err != nil {
			s.fail(w, err)
			return false
		}
		now := s.Now().In(lagos)
		today, err := spentSince(time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, lagos))
		if err != nil {
			s.fail(w, err)
			return false
		}
		if today+amount > st.Limits.DailySend {
			msg := fmt.Sprintf("Tier %d accounts can send up to %s a day, and you have %s left today.",
				st.Tier, notify.Naira(st.Limits.DailySend), notify.Naira(max(0, st.Limits.DailySend-today)))
			if st.Tier < 3 {
				msg += " Verify your BVN or NIN under Me → Limits to raise it."
			}
			writeError(w, http.StatusForbidden, "daily_limit", msg)
			return false
		}
	}

	ends := p.NewDeviceWindowEnds(s.Auth.Config())
	if !s.Now().Before(ends) {
		return true
	}
	since, err := spentSince(p.DeviceBoundAt)
	if err != nil {
		s.fail(w, err)
		return false
	}
	if limit := s.Auth.Config().NewDeviceLimit; since+amount > limit {
		writeError(w, http.StatusForbidden, "new_device_limit", fmt.Sprintf(
			"For your safety, a newly added phone can send up to ₦%d in its first 24 hours. The limit lifts at %s.",
			limit/100, ends.In(lagos).Format("3:04 PM on 2 Jan")))
		return false
	}
	return true
}

func (s *Server) changePIN(w http.ResponseWriter, r *http.Request) {
	var body struct {
		OldPIN string `json:"old_pin"`
		NewPIN string `json:"new_pin"`
	}
	if !readJSON(w, r, &body) {
		return
	}
	if err := s.Auth.ChangePIN(r.Context(), principal(r), body.OldPIN, body.NewPIN); err != nil {
		s.fail(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// verifyPIN lets the app unlock itself with the PIN when biometrics fail.
func (s *Server) verifyPIN(w http.ResponseWriter, r *http.Request) {
	var body struct {
		PIN string `json:"pin"`
	}
	if !readJSON(w, r, &body) {
		return
	}
	if err := s.Auth.CheckPIN(r.Context(), principal(r).UserID, body.PIN); err != nil {
		s.fail(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) listDevices(w http.ResponseWriter, r *http.Request) {
	ds, err := s.Auth.Devices(r.Context(), principal(r))
	if err != nil {
		s.fail(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"devices": ds})
}

func (s *Server) removeDevice(w http.ResponseWriter, r *http.Request) {
	id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil {
		writeError(w, http.StatusNotFound, "not_found", "Not found.")
		return
	}
	if err := s.Auth.RemoveDevice(r.Context(), principal(r), id); err != nil {
		s.fail(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) kycStatus(w http.ResponseWriter, r *http.Request) {
	st, err := s.KYC.Status(r.Context(), principal(r).UserID)
	if err != nil {
		s.fail(w, err)
		return
	}
	writeJSON(w, http.StatusOK, st)
}

func (s *Server) verifyKYC(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Type   string `json:"type"`
		Number string `json:"number"`
	}
	if !readJSON(w, r, &body) {
		return
	}
	p := principal(r)
	st, err := s.KYC.Verify(r.Context(), p.UserID, p.WalletID, body.Type, body.Number)
	if err != nil {
		s.fail(w, err)
		return
	}
	writeJSON(w, http.StatusOK, st)
}

func (s *Server) listNotifications(w http.ResponseWriter, r *http.Request) {
	ns, unread, err := notify.List(r.Context(), s.DB, principal(r).WalletID, 50)
	if err != nil {
		s.fail(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"notifications": ns, "unread": unread})
}

func (s *Server) referralSummary(w http.ResponseWriter, r *http.Request) {
	sum, err := s.Referrals.Summary(r.Context(), principal(r).UserID)
	if err != nil {
		s.fail(w, err)
		return
	}
	writeJSON(w, http.StatusOK, sum)
}

func (s *Server) joinReferral(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Code string `json:"code"`
	}
	if !readJSON(w, r, &body) {
		return
	}
	sum, err := s.Referrals.Join(r.Context(), principal(r).UserID, body.Code)
	if err != nil {
		s.fail(w, err)
		return
	}
	writeJSON(w, http.StatusOK, sum)
}

func (s *Server) helpArticles(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{"articles": support.Articles})
}

func (s *Server) supportMessages(w http.ResponseWriter, r *http.Request) {
	ms, err := s.Support.Messages(r.Context(), principal(r).UserID)
	if err != nil {
		s.fail(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"messages": ms})
}

func (s *Server) sendSupportMessage(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Body string `json:"body"`
	}
	if !readJSON(w, r, &body) {
		return
	}
	ms, err := s.Support.Send(r.Context(), principal(r).UserID, body.Body)
	if err != nil {
		s.fail(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"messages": ms})
}

func (s *Server) supportReply(w http.ResponseWriter, r *http.Request) {
	userID, err := strconv.ParseInt(r.PathValue("user_id"), 10, 64)
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid_request", "user_id must be a number.")
		return
	}
	var body struct {
		Body string `json:"body"`
	}
	if !readJSON(w, r, &body) {
		return
	}
	if err := s.Support.Reply(r.Context(), userID, body.Body); err != nil {
		s.fail(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) readNotifications(w http.ResponseWriter, r *http.Request) {
	if err := notify.MarkAllRead(r.Context(), s.DB, principal(r).WalletID, s.Now()); err != nil {
		s.fail(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) listBillers(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{"billers": s.Bills.Billers()})
}

func (s *Server) validateBill(w http.ResponseWriter, r *http.Request) {
	var body struct {
		BillerID string `json:"biller_id"`
		Customer string `json:"customer"`
	}
	if !readJSON(w, r, &body) {
		return
	}
	name, err := s.Bills.Validate(r.Context(), body.BillerID, body.Customer)
	if err != nil {
		s.fail(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"customer_name": name})
}

func (s *Server) payBill(w http.ResponseWriter, r *http.Request) {
	var body struct {
		BillerID string `json:"biller_id"`
		PlanCode string `json:"plan_code"`
		Customer string `json:"customer"`
		Amount   int64  `json:"amount"`
		PIN      string `json:"pin"`
	}
	if !readJSON(w, r, &body) {
		return
	}
	p := principal(r)
	if err := s.Auth.CheckPIN(r.Context(), p.UserID, body.PIN); err != nil {
		s.fail(w, err)
		return
	}
	if !s.withinLimits(w, r, p, s.Bills.Price(body.BillerID, body.PlanCode, body.Amount)) {
		return
	}
	pay, err := s.Bills.Pay(r.Context(), bills.PayRequest{
		IdempotencyKey:  r.Header.Get("Idempotency-Key"),
		WalletAccountID: p.WalletID,
		BillerID:        body.BillerID,
		PlanCode:        body.PlanCode,
		Customer:        body.Customer,
		Amount:          body.Amount,
	})
	if err != nil {
		s.fail(w, err)
		return
	}
	writeJSON(w, http.StatusOK, pay)
}

func (s *Server) listSavings(w http.ResponseWriter, r *http.Request) {
	pots, err := s.Savings.List(r.Context(), principal(r).WalletID)
	if err != nil {
		s.fail(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"pots": pots, "rates": s.Savings.Rates()})
}

func (s *Server) createSavings(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Kind     savings.Kind `json:"kind"`
		Name     string       `json:"name"`
		Target   int64        `json:"target"`
		LockDays int          `json:"lock_days"`
		Amount   int64        `json:"amount"`
	}
	if !readJSON(w, r, &body) {
		return
	}
	pot, err := s.Savings.Create(r.Context(), savings.CreateRequest{
		IdempotencyKey:  r.Header.Get("Idempotency-Key"),
		WalletAccountID: principal(r).WalletID,
		Kind:            body.Kind,
		Name:            body.Name,
		Target:          body.Target,
		LockDays:        body.LockDays,
		Amount:          body.Amount,
	})
	if err != nil {
		s.fail(w, err)
		return
	}
	writeJSON(w, http.StatusOK, pot)
}

func (s *Server) depositSavings(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Amount int64 `json:"amount"`
	}
	if !readJSON(w, r, &body) {
		return
	}
	pot, err := s.Savings.Deposit(r.Context(), principal(r).WalletID, r.PathValue("id"), r.Header.Get("Idempotency-Key"), body.Amount)
	if err != nil {
		s.fail(w, err)
		return
	}
	writeJSON(w, http.StatusOK, pot)
}

func (s *Server) withdrawSavings(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Amount     int64 `json:"amount"`
		BreakEarly bool  `json:"break_early"`
	}
	if !readJSON(w, r, &body) {
		return
	}
	pot, err := s.Savings.Withdraw(r.Context(), principal(r).WalletID, r.PathValue("id"),
		r.Header.Get("Idempotency-Key"), body.Amount, body.BreakEarly)
	if err != nil {
		s.fail(w, err)
		return
	}
	writeJSON(w, http.StatusOK, pot)
}

func (s *Server) shareProfit(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Period        string `json:"period"`
		GoalRateBps   int    `json:"goal_rate_bps"`
		LockedRateBps int    `json:"locked_rate_bps"`
	}
	if !readJSON(w, r, &body) {
		return
	}
	run, err := s.Savings.DistributeProfit(r.Context(), body.Period, body.GoalRateBps, body.LockedRateBps)
	if err != nil {
		s.fail(w, err)
		return
	}
	writeJSON(w, http.StatusOK, run)
}

func (s *Server) getBillPayment(w http.ResponseWriter, r *http.Request) {
	pay, err := s.Bills.Get(r.Context(), r.PathValue("id"))
	if err == nil && pay.WalletAccountID != principal(r).WalletID {
		err = bills.ErrNotFound // never reveal other users' payments
	}
	if err != nil {
		s.fail(w, err)
		return
	}
	writeJSON(w, http.StatusOK, pay)
}

func (s *Server) quoteTransfer(w http.ResponseWriter, r *http.Request) {
	amount, err := strconv.ParseInt(r.URL.Query().Get("amount"), 10, 64)
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid_request", "amount must be a whole number of kobo")
		return
	}
	q, err := s.Transfers.Quote(r.Context(), principal(r).WalletID, amount)
	if err != nil {
		s.fail(w, err)
		return
	}
	writeJSON(w, http.StatusOK, q)
}

func (s *Server) getTransfer(w http.ResponseWriter, r *http.Request) {
	t, err := s.Transfers.Get(r.Context(), r.PathValue("id"))
	if err == nil && t.WalletAccountID != principal(r).WalletID {
		err = transfers.ErrNotFound // never reveal other users' transfers
	}
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
	return hmac.Equal([]byte(Sign(secret, body)), []byte(got))
}

// Sign returns the X-Signature value for body; used by tests and the sandbox.
func Sign(secret string, body []byte) string {
	mac := hmac.New(sha256.New, []byte(secret))
	mac.Write(body)
	return hex.EncodeToString(mac.Sum(nil))
}

func (s *Server) fail(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, auth.ErrUnauthorized):
		writeError(w, http.StatusUnauthorized, "unauthorized", "Please sign in again.")
	case errors.Is(err, auth.ErrWrongPIN):
		writeError(w, http.StatusUnauthorized, "wrong_pin", "That PIN is wrong.")
	case errors.Is(err, auth.ErrLocked):
		writeError(w, http.StatusLocked, "pin_locked", "Too many wrong PINs. For your safety, try again in 30 minutes.")
	case errors.Is(err, auth.ErrTooManyRequests):
		writeError(w, http.StatusTooManyRequests, "too_many_codes", "Too many codes requested. Wait a few minutes and try again.")
	case errors.Is(err, auth.ErrInvalidCode):
		writeError(w, http.StatusUnauthorized, "invalid_code", "That code is wrong or has expired.")
	case errors.Is(err, auth.ErrInvalidPhone), errors.Is(err, auth.ErrWeakPIN), errors.Is(err, auth.ErrInvalidDevice),
		errors.Is(err, auth.ErrSamePIN), errors.Is(err, kyc.ErrInvalid):
		writeError(w, http.StatusBadRequest, "invalid_request", friendly(err))
	case errors.Is(err, ledger.ErrInsufficientFunds):
		writeError(w, http.StatusUnprocessableEntity, "insufficient_funds", "Your balance is too low for this payment, including any fee.")
	case errors.Is(err, kyc.ErrMismatch):
		writeError(w, http.StatusUnprocessableEntity, "kyc_mismatch", "Those details don't match the records. Check the number and try again.")
	case errors.Is(err, referrals.ErrUnknownCode):
		writeError(w, http.StatusNotFound, "unknown_code", "We don't recognise that invite code. Check it and try again.")
	case errors.Is(err, referrals.ErrOwnCode):
		writeError(w, http.StatusBadRequest, "own_code", "That's your own invite code. Share it with friends instead.")
	case errors.Is(err, referrals.ErrAlreadyUsed):
		writeError(w, http.StatusConflict, "code_used", "You've already joined with an invite code.")
	case errors.Is(err, referrals.ErrTooLate):
		writeError(w, http.StatusConflict, "code_too_late", "Invite codes can only be added in your first 30 days.")
	case errors.Is(err, referrals.ErrInvalid), errors.Is(err, support.ErrInvalid):
		writeError(w, http.StatusBadRequest, "invalid_request", friendly(err))
	case errors.Is(err, auth.ErrThisDevice):
		writeError(w, http.StatusConflict, "this_device", "This is the phone you're using. Sign out instead.")
	case errors.Is(err, auth.ErrNoSuchDevice):
		writeError(w, http.StatusNotFound, "not_found", "Not found.")
	case errors.Is(err, savings.ErrLocked):
		writeError(w, http.StatusConflict, "savings_locked", "This plan is locked until it matures. You can break it early, but you'll give back its profit share.")
	case errors.Is(err, savings.ErrClosed):
		writeError(w, http.StatusConflict, "savings_closed", "This savings pot is closed.")
	case errors.Is(err, savings.ErrDeclared):
		writeError(w, http.StatusConflict, "already_declared", err.Error())
	case errors.Is(err, bills.ErrCustomerNotFound):
		writeError(w, http.StatusNotFound, "customer_not_found", "We could not find that number. Check it and try again.")
	case errors.Is(err, transfers.ErrInvalid), errors.Is(err, inbound.ErrInvalid), errors.Is(err, bills.ErrInvalid),
		errors.Is(err, savings.ErrInvalid):
		writeError(w, http.StatusBadRequest, "invalid_request", friendly(err))
	case errors.Is(err, transfers.ErrIdempotencyConflict), errors.Is(err, bills.ErrIdempotencyConflict):
		writeError(w, http.StatusConflict, "idempotency_conflict", err.Error())
	case errors.Is(err, transfers.ErrNotResolvable):
		writeError(w, http.StatusConflict, "not_resolvable", err.Error())
	case errors.Is(err, wallets.ErrNotFound), errors.Is(err, transfers.ErrNotFound), errors.Is(err, bills.ErrNotFound),
		errors.Is(err, savings.ErrNotFound):
		writeError(w, http.StatusNotFound, "not_found", "Not found.")
	default:
		s.Log.Error("request failed", "err", err)
		writeError(w, http.StatusInternalServerError, "internal", "Something went wrong on our side. No money was lost; please try again.")
	}
}

var errPrefix = regexp.MustCompile(`^(\w+: )+(invalid request: )?`)

// friendly turns "bills: invalid request: choose a plan" into "Choose a plan."
func friendly(err error) string {
	msg := errPrefix.ReplaceAllString(err.Error(), "")
	if msg == "" {
		return "Please check your details and try again."
	}
	msg = strings.ToUpper(msg[:1]) + msg[1:]
	if !strings.HasSuffix(msg, ".") {
		msg += "."
	}
	return msg
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
