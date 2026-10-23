// Package inbound credits wallets when money arrives from another bank.
package inbound

import (
	"context"
	"errors"
	"fmt"

	"github.com/jackc/pgx/v5/pgxpool"

	"avora/backend/internal/ledger"
	"avora/backend/internal/wallets"
)

var ErrInvalid = errors.New("inbound: invalid credit")

const (
	// EMTL: ₦50 on electronic receipts of ₦10,000 or more, paid by the receiver.
	EMTLThreshold = 10_000_00
	EMTLAmount    = 50_00
)

type Credit struct {
	SessionID  string `json:"session_id"` // NIP session id; unique per credit
	NUBAN      string `json:"account_number"`
	Amount     int64  `json:"amount"`
	SenderName string `json:"sender_name"`
	SenderBank string `json:"sender_bank"`
}

type Result struct {
	WalletAccountID int64 `json:"wallet_id"`
	Amount          int64 `json:"amount"`
	Levy            int64 `json:"levy"`
	Duplicate       bool  `json:"duplicate"`
}

// Apply credits the wallet once per session id; repeats are ignored.
func Apply(ctx context.Context, pool *pgxpool.Pool, sys wallets.System, c Credit) (Result, error) {
	if c.SessionID == "" || c.Amount <= 0 {
		return Result{}, fmt.Errorf("%w: session id and a positive amount are required", ErrInvalid)
	}
	w, err := wallets.ByNUBAN(ctx, pool, c.NUBAN)
	if err != nil {
		return Result{}, err
	}

	var levy int64
	if c.Amount >= EMTLThreshold {
		levy = EMTLAmount
	}

	tx, err := pool.Begin(ctx)
	if err != nil {
		return Result{}, err
	}
	defer tx.Rollback(ctx)

	tag, err := tx.Exec(ctx, `
		insert into inbound_credits (session_id, wallet_account_id, amount, levy, sender_name, sender_bank)
		values ($1, $2, $3, $4, $5, $6) on conflict (session_id) do nothing`,
		c.SessionID, w.AccountID, c.Amount, levy, c.SenderName, c.SenderBank)
	if err != nil {
		return Result{}, err
	}
	res := Result{WalletAccountID: w.AccountID, Amount: c.Amount, Levy: levy}
	if tag.RowsAffected() == 0 {
		res.Duplicate = true
		return res, nil
	}

	lines := []ledger.Line{
		ledger.Debit(sys.Settlement, c.Amount),
		ledger.Credit(w.AccountID, c.Amount-levy),
	}
	if levy > 0 {
		lines = append(lines, ledger.Credit(sys.EMTLPayable, levy))
	}
	desc := fmt.Sprintf("Received from %s", c.SenderName)
	if c.SenderBank != "" {
		desc += " (" + c.SenderBank + ")"
	}
	if levy > 0 {
		desc += ", less ₦50 EMTL levy"
	}
	if _, err := ledger.Post(ctx, tx, ledger.Journal{
		IdempotencyKey: "inbound:" + c.SessionID,
		Kind:           "inbound_credit",
		Description:    desc,
		Ref:            c.SessionID,
		Lines:          lines,
	}); err != nil {
		return Result{}, err
	}
	return res, tx.Commit(ctx)
}
