package api

import (
	"net/http"
	"time"

	"avora/backend/internal/ledger"
	"avora/backend/internal/wallets"
)

// Account freeze, statements for a period, and reports of a problem with a
// payment.

func (s *Server) freezeStatus(w http.ResponseWriter, r *http.Request) {
	st, err := s.Auth.Frozen(r.Context(), principal(r).UserID)
	if err != nil {
		s.fail(w, err)
		return
	}
	writeJSON(w, http.StatusOK, st)
}

// freeze needs no PIN: it only ever makes the account safer.
func (s *Server) freeze(w http.ResponseWriter, r *http.Request) {
	st, err := s.Auth.Freeze(r.Context(), principal(r))
	if err != nil {
		s.fail(w, err)
		return
	}
	writeJSON(w, http.StatusOK, st)
}

func (s *Server) unfreeze(w http.ResponseWriter, r *http.Request) {
	var body struct {
		PIN string `json:"pin"`
	}
	if !readJSON(w, r, &body) {
		return
	}
	st, err := s.Auth.Unfreeze(r.Context(), principal(r), body.PIN)
	if err != nil {
		s.fail(w, err)
		return
	}
	writeJSON(w, http.StatusOK, st)
}

// periodStatement is an account statement for whole days in Lagos time:
// ?from=2026-10-01&to=2026-10-31, both included, up to a year.
func (s *Server) periodStatement(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	from, err1 := time.ParseInLocation("2006-01-02", q.Get("from"), lagos)
	to, err2 := time.ParseInLocation("2006-01-02", q.Get("to"), lagos)
	if err1 != nil || err2 != nil {
		writeError(w, http.StatusBadRequest, "invalid_request", "Give from and to as dates, like 2026-10-01.")
		return
	}
	if to.Before(from) {
		writeError(w, http.StatusBadRequest, "invalid_request", "The end date must be on or after the start date.")
		return
	}
	if to.Sub(from) > 366*24*time.Hour {
		writeError(w, http.StatusBadRequest, "invalid_request", "A statement can cover up to a year.")
		return
	}
	end := to.AddDate(0, 0, 1)
	if now := s.Now(); end.After(now) {
		end = now
	}
	ctx := r.Context()
	p := principal(r)
	wal, err := wallets.Get(ctx, s.DB, p.WalletID)
	if err != nil {
		s.fail(w, err)
		return
	}
	opening, lines, more, err := ledger.StatementBetween(ctx, s.DB, p.WalletID, from, end)
	if err != nil {
		s.fail(w, err)
		return
	}
	if err := s.nameP2P(ctx, p.WalletID, lines); err != nil {
		s.fail(w, err)
		return
	}
	var in, out int64
	for _, l := range lines {
		if l.Amount > 0 {
			in += l.Amount
		} else {
			out -= l.Amount
		}
	}
	name := ""
	if s.P2P != nil {
		if prof, err := s.P2P.Profile(ctx, p.UserID); err == nil {
			name = prof.Name
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"account_name":    name,
		"account_number":  wal.NUBAN,
		"from":            from.Format("2006-01-02"),
		"to":              to.Format("2006-01-02"),
		"opening_balance": opening,
		"money_in":        in,
		"money_out":       out,
		"closing_balance": opening + in - out,
		"lines":           lines,
		"truncated":       more,
	})
}

func (s *Server) listDisputes(w http.ResponseWriter, r *http.Request) {
	list, err := s.Disputes.List(r.Context(), principal(r).UserID)
	if err != nil {
		s.fail(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"disputes": list})
}

func (s *Server) openDispute(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Ref     string `json:"ref"`
		Reason  string `json:"reason"`
		Details string `json:"details"`
	}
	if !readJSON(w, r, &body) {
		return
	}
	p := principal(r)
	d, err := s.Disputes.Open(r.Context(), p.UserID, p.WalletID, body.Ref, body.Reason, body.Details)
	if err != nil {
		s.fail(w, err)
		return
	}
	writeJSON(w, http.StatusOK, d)
}

func (s *Server) getDispute(w http.ResponseWriter, r *http.Request) {
	d, err := s.Disputes.Get(r.Context(), principal(r).UserID, r.PathValue("id"))
	if err != nil {
		s.fail(w, err)
		return
	}
	writeJSON(w, http.StatusOK, d)
}

func (s *Server) closeDispute(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Outcome string `json:"outcome"`
		Answer  string `json:"answer"`
	}
	if !readJSON(w, r, &body) {
		return
	}
	d, err := s.Disputes.Close(r.Context(), r.PathValue("id"), body.Outcome, body.Answer)
	if err != nil {
		s.fail(w, err)
		return
	}
	writeJSON(w, http.StatusOK, d)
}
