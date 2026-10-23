// Package wallets manages customer wallets and the system ledger accounts.
package wallets

import (
	"context"
	"errors"
	"fmt"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"

	"avora/backend/internal/ledger"
)

var (
	ErrNotFound = errors.New("wallets: not found")
	ErrExists   = errors.New("wallets: already exists")
)

// System holds the ids of the ledger accounts seeded by the first migration.
type System struct {
	InFlight    int64 // debited from wallets, not yet confirmed by the bank rail
	Settlement  int64 // our pooled funds at the partner bank
	FeeRevenue  int64
	EMTLPayable int64 // electronic money transfer levy owed to government
}

func LoadSystem(ctx context.Context, db ledger.DB) (System, error) {
	rows, err := db.Query(ctx, `select code, id from accounts where code like 'system:%'`)
	if err != nil {
		return System{}, err
	}
	defer rows.Close()
	var s System
	for rows.Next() {
		var code string
		var id int64
		if err := rows.Scan(&code, &id); err != nil {
			return System{}, err
		}
		switch code {
		case "system:in_flight":
			s.InFlight = id
		case "system:settlement":
			s.Settlement = id
		case "system:fee_revenue":
			s.FeeRevenue = id
		case "system:emtl_payable":
			s.EMTLPayable = id
		}
	}
	if s.InFlight == 0 || s.Settlement == 0 || s.FeeRevenue == 0 || s.EMTLPayable == 0 {
		return System{}, errors.New("wallets: system accounts missing; run migrations")
	}
	return s, rows.Err()
}

type Wallet struct {
	AccountID int64  `json:"id"`
	UserRef   string `json:"user_ref"`
	NUBAN     string `json:"account_number"`
	Balance   int64  `json:"balance"`
}

// Create opens a wallet. The NUBAN comes from the partner bank.
func Create(ctx context.Context, pool *pgxpool.Pool, userRef, nuban string) (Wallet, error) {
	if userRef == "" || len(nuban) != 10 {
		return Wallet{}, errors.New("wallets: user ref and a 10-digit account number are required")
	}
	tx, err := pool.Begin(ctx)
	if err != nil {
		return Wallet{}, err
	}
	defer tx.Rollback(ctx)

	w := Wallet{UserRef: userRef, NUBAN: nuban}
	err = tx.QueryRow(ctx, `insert into accounts (code, kind) values ($1, 'liability') returning id`,
		"wallet:"+userRef).Scan(&w.AccountID)
	if err == nil {
		_, err = tx.Exec(ctx, `insert into wallets (account_id, user_ref, nuban) values ($1, $2, $3)`,
			w.AccountID, userRef, nuban)
	}
	var pgErr *pgconn.PgError
	if errors.As(err, &pgErr) && pgErr.Code == "23505" {
		return Wallet{}, ErrExists
	}
	if err != nil {
		return Wallet{}, err
	}
	return w, tx.Commit(ctx)
}

func Get(ctx context.Context, db ledger.DB, accountID int64) (Wallet, error) {
	return get(ctx, db, `w.account_id = $1`, accountID)
}

func ByNUBAN(ctx context.Context, db ledger.DB, nuban string) (Wallet, error) {
	return get(ctx, db, `w.nuban = $1`, nuban)
}

func get(ctx context.Context, db ledger.DB, where string, arg any) (Wallet, error) {
	var w Wallet
	err := db.QueryRow(ctx, `
		select w.account_id, w.user_ref, w.nuban, a.balance
		from wallets w join accounts a on a.id = w.account_id
		where `+where, arg).Scan(&w.AccountID, &w.UserRef, &w.NUBAN, &w.Balance)
	if errors.Is(err, pgx.ErrNoRows) {
		return Wallet{}, fmt.Errorf("%w: %v", ErrNotFound, arg)
	}
	return w, err
}
