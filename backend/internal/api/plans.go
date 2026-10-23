package api

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"time"

	"avora/backend/internal/bills"
	"avora/backend/internal/ledger"
	"avora/backend/internal/notify"
	"avora/backend/internal/p2p"
	"avora/backend/internal/rails"
	"avora/backend/internal/savings"
	"avora/backend/internal/schedules"
	"avora/backend/internal/splits"
	"avora/backend/internal/transfers"
)

func (s *Server) listSchedules(w http.ResponseWriter, r *http.Request) {
	list, err := s.Schedules.List(r.Context(), principal(r).UserID)
	if err != nil {
		s.fail(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"schedules": list})
}

// createSchedule checks the payee now, with the PIN, so each run can go
// ahead without asking again.
func (s *Server) createSchedule(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Kind      string           `json:"kind"`
		Name      string           `json:"name"`
		Amount    int64            `json:"amount"`
		Frequency string           `json:"frequency"`
		StartsAt  time.Time        `json:"starts_at"`
		Target    schedules.Target `json:"target"`
		PIN       string           `json:"pin"`
	}
	if !readJSON(w, r, &body) {
		return
	}
	ctx := r.Context()
	p := principal(r)
	if err := s.Auth.CheckPIN(ctx, p.UserID, body.PIN); err != nil {
		s.fail(w, err)
		return
	}
	t := body.Target
	switch body.Kind {
	case "transfer":
		name, err := s.Rail.NameEnquiry(ctx, t.BankCode, t.AccountNumber)
		if errors.Is(err, rails.ErrAccountNotFound) {
			writeError(w, http.StatusNotFound, "account_not_found", "No account found with that number at that bank.")
			return
		}
		if err != nil {
			s.fail(w, err)
			return
		}
		t = schedules.Target{BankCode: t.BankCode, AccountNumber: t.AccountNumber, AccountName: name}
	case "avora":
		who, err := s.P2P.Find(ctx, p.UserID, t.To)
		if err != nil {
			s.fail(w, err)
			return
		}
		to := t.To
		if who.Tag != "" {
			to = "@" + who.Tag
		}
		t = schedules.Target{To: to, AccountName: who.Name}
	case "bill":
		name, err := s.Bills.Validate(ctx, t.BillerID, t.Customer)
		if err != nil {
			s.fail(w, err)
			return
		}
		body.Amount = s.Bills.Price(t.BillerID, t.PlanCode, body.Amount)
		t = schedules.Target{BillerID: t.BillerID, PlanCode: t.PlanCode, Customer: t.Customer, AccountName: name}
	case "savings":
		pot, err := s.Savings.Get(ctx, p.WalletID, t.PotID)
		if err != nil {
			s.fail(w, err)
			return
		}
		if pot.Status != "open" || pot.Kind != savings.Goal {
			writeError(w, http.StatusBadRequest, "invalid_request", "Scheduled saving goes into an open goal pot.")
			return
		}
		t = schedules.Target{PotID: pot.ID, AccountName: pot.Name}
	}
	if body.StartsAt.IsZero() {
		body.StartsAt = s.Now()
	}
	sc, err := s.Schedules.Create(ctx, schedules.Schedule{
		UserID: p.UserID, WalletID: p.WalletID, Kind: body.Kind, Name: body.Name, Amount: body.Amount,
		Frequency: body.Frequency, StartsAt: body.StartsAt, Target: t,
	})
	if err != nil {
		s.fail(w, err)
		return
	}
	writeJSON(w, http.StatusOK, sc)
}

func (s *Server) pauseSchedule(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Paused bool `json:"paused"`
	}
	if !readJSON(w, r, &body) {
		return
	}
	sc, err := s.Schedules.SetPaused(r.Context(), principal(r).UserID, r.PathValue("id"), body.Paused)
	if err != nil {
		s.fail(w, err)
		return
	}
	writeJSON(w, http.StatusOK, sc)
}

func (s *Server) cancelSchedule(w http.ResponseWriter, r *http.Request) {
	if err := s.Schedules.Cancel(r.Context(), principal(r).UserID, r.PathValue("id")); err != nil {
		s.fail(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// sandboxRunSchedule runs a schedule now, so it can be tried out.
func (s *Server) sandboxRunSchedule(w http.ResponseWriter, r *http.Request) {
	sc, err := s.Schedules.ClaimOne(r.Context(), principal(r).UserID, r.PathValue("id"))
	if err != nil {
		s.fail(w, err)
		return
	}
	s.runSchedule(r.Context(), sc)
	sc, err = s.Schedules.Get(r.Context(), principal(r).UserID, sc.ID)
	if err != nil {
		s.fail(w, err)
		return
	}
	writeJSON(w, http.StatusOK, sc)
}

// RunSchedules pays every schedule that is due. Run it every minute.
func (s *Server) RunSchedules(ctx context.Context) (int, error) {
	due, err := s.Schedules.Claim(ctx, 100)
	if err != nil {
		return 0, err
	}
	for _, sc := range due {
		s.runSchedule(ctx, sc)
	}
	return len(due), nil
}

// runSchedule pays one run, under the same limits as a payment made by
// hand, then records and tells the customer how it went.
func (s *Server) runSchedule(ctx context.Context, sc schedules.Schedule) {
	err := s.paySchedule(ctx, sc)
	msg := "Sent"
	if err != nil {
		msg = scheduleFailure(err)
	}
	if rerr := s.Schedules.Record(ctx, sc.ID, err == nil, msg); rerr != nil {
		s.Log.Error("record schedule", "id", sc.ID, "err", rerr)
	}
	title := fmt.Sprintf("Scheduled: %s for %s", notify.Naira(sc.Amount), sc.Name)
	body := "Paid as planned."
	if err != nil {
		title, body = fmt.Sprintf("%s didn't go", sc.Name), msg+" We'll try again at the next date."
		if sc.Frequency == "once" {
			body = msg + " You can pay it from the app."
		}
	}
	if nerr := notify.Add(ctx, s.DB, sc.WalletID, "schedule", title, body, sc.ID); nerr != nil {
		s.Log.Error("notify schedule", "id", sc.ID, "err", nerr)
	}
}

func (s *Server) paySchedule(ctx context.Context, sc schedules.Schedule) error {
	key := fmt.Sprintf("schedule:%s:%d", sc.ID, sc.Runs)
	t := sc.Target
	if sc.Kind != "savings" {
		if err := s.dailyLimit(ctx, sc.UserID, sc.WalletID, sc.Amount); err != nil {
			return err
		}
	}
	var ref string
	switch sc.Kind {
	case "transfer":
		tr, err := s.Transfers.Initiate(ctx, transfers.InitiateRequest{IdempotencyKey: key, WalletAccountID: sc.WalletID,
			BankCode: t.BankCode, AccountNumber: t.AccountNumber, Amount: sc.Amount, Narration: sc.Name})
		if err != nil {
			return err
		}
		ref = tr.ID
	case "avora":
		tr, err := s.P2P.Send(ctx, p2p.SendRequest{IdempotencyKey: key, FromUserID: sc.UserID, FromWallet: sc.WalletID,
			To: t.To, Amount: sc.Amount, Note: sc.Name})
		if err != nil {
			return err
		}
		ref = tr.ID
	case "bill":
		pay, err := s.Bills.Pay(ctx, bills.PayRequest{IdempotencyKey: key, WalletAccountID: sc.WalletID,
			BillerID: t.BillerID, PlanCode: t.PlanCode, Customer: t.Customer, Amount: sc.Amount})
		if err != nil {
			return err
		}
		if pay.Status == bills.Refunded {
			return errors.New("the biller declined it, so the money came back")
		}
		ref = pay.ID
	case "savings":
		_, err := s.Savings.Deposit(ctx, sc.WalletID, t.PotID, key, sc.Amount)
		return err
	}
	s.afterSpend(ctx, sc.WalletID, ref, sc.Amount)
	return nil
}

func scheduleFailure(err error) string {
	var limit *limitError
	switch {
	case errors.As(err, &limit):
		return limit.msg
	case errors.Is(err, ledger.ErrInsufficientFunds):
		return "Your balance was too low."
	case errors.Is(err, p2p.ErrNotFound):
		return "That Avora customer can't be found any more."
	case errors.Is(err, savings.ErrClosed), errors.Is(err, savings.ErrNotFound):
		return "That savings pot is closed."
	}
	return friendly(err)
}

func (s *Server) listSplits(w http.ResponseWriter, r *http.Request) {
	list, err := s.Splits.List(r.Context(), principal(r).UserID)
	if err != nil {
		s.fail(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"splits": list})
}

func (s *Server) createSplit(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Title  string `json:"title"`
		Total  int64  `json:"total"`
		People []struct {
			To     string `json:"to"`
			Amount int64  `json:"amount"`
		} `json:"people"`
	}
	if !readJSON(w, r, &body) {
		return
	}
	p := principal(r)
	var asks []splits.Request
	for _, x := range body.People {
		who, err := s.P2P.Find(r.Context(), p.UserID, x.To)
		if err != nil {
			s.fail(w, err)
			return
		}
		asks = append(asks, splits.Request{UserID: who.UserID(), WalletID: who.WalletID(), Amount: x.Amount})
	}
	sp, err := s.Splits.Create(r.Context(), p.UserID, body.Title, body.Total, asks)
	if err != nil {
		s.fail(w, err)
		return
	}
	writeJSON(w, http.StatusOK, sp)
}

func (s *Server) getSplit(w http.ResponseWriter, r *http.Request) {
	sp, err := s.Splits.Get(r.Context(), principal(r).UserID, r.PathValue("id"))
	if err != nil {
		s.fail(w, err)
		return
	}
	writeJSON(w, http.StatusOK, sp)
}

// paySplit pays the viewer's share to whoever asked, as an Avora transfer.
func (s *Server) paySplit(w http.ResponseWriter, r *http.Request) {
	var body struct {
		PIN string `json:"pin"`
	}
	if !readJSON(w, r, &body) {
		return
	}
	ctx := r.Context()
	p := principal(r)
	if err := s.Auth.CheckPIN(ctx, p.UserID, body.PIN); err != nil {
		s.fail(w, err)
		return
	}
	sp, me, err := s.Splits.MyShare(ctx, p.UserID, r.PathValue("id"))
	if err != nil {
		s.fail(w, err)
		return
	}
	if !s.withinLimits(w, r, p, me.Amount) {
		return
	}
	t, err := s.P2P.Send(ctx, p2p.SendRequest{IdempotencyKey: "split:" + sp.ID, FromUserID: p.UserID,
		FromWallet: p.WalletID, To: sp.PayTo(), Amount: me.Amount, Note: sp.Title})
	if err != nil {
		s.fail(w, err)
		return
	}
	sp, err = s.Splits.Paid(ctx, p.UserID, sp.ID, t.ID)
	if err != nil {
		s.fail(w, err)
		return
	}
	s.afterSpend(ctx, p.WalletID, t.ID, t.Amount)
	writeJSON(w, http.StatusOK, sp)
}

func (s *Server) declineSplit(w http.ResponseWriter, r *http.Request) {
	sp, err := s.Splits.Decline(r.Context(), principal(r).UserID, r.PathValue("id"))
	if err != nil {
		s.fail(w, err)
		return
	}
	writeJSON(w, http.StatusOK, sp)
}
