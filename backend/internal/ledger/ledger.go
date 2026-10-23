// Package ledger is Avora's double-entry ledger, the source of truth for
// every balance. Amounts are int64 kobo. An entry is signed: debit positive,
// credit negative. Every journal sums to zero and is written once per
// idempotency key.
package ledger

import (
	"context"
	"errors"
	"fmt"
	"sort"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

var (
	ErrInvalidJournal    = errors.New("ledger: invalid journal")
	ErrUnbalanced        = errors.New("ledger: journal does not balance")
	ErrInsufficientFunds = errors.New("ledger: insufficient funds")
	ErrUnknownAccount    = errors.New("ledger: unknown account")
)

// DB is satisfied by *pgxpool.Pool and pgx.Tx.
type DB interface {
	Exec(ctx context.Context, sql string, args ...any) (pgconn.CommandTag, error)
	Query(ctx context.Context, sql string, args ...any) (pgx.Rows, error)
	QueryRow(ctx context.Context, sql string, args ...any) pgx.Row
}

type Kind string

const (
	Asset     Kind = "asset"
	Liability Kind = "liability"
	Income    Kind = "income"
	Expense   Kind = "expense"
)

// debitNormal reports whether debits increase the account's balance.
func (k Kind) debitNormal() bool { return k == Asset || k == Expense }

// toBalance converts a signed entry amount into its effect on the balance.
func (k Kind) toBalance(amount int64) int64 {
	if k.debitNormal() {
		return amount
	}
	return -amount
}

type Line struct {
	AccountID int64
	Amount    int64
}

func Debit(accountID, kobo int64) Line  { return Line{accountID, kobo} }
func Credit(accountID, kobo int64) Line { return Line{accountID, -kobo} }

type Journal struct {
	IdempotencyKey string
	Kind           string
	Description    string
	Ref            string
	Lines          []Line
}

type Posted struct {
	JournalID int64
	Replayed  bool // the key was already used; nothing new was written
}

func (j Journal) validate() error {
	if j.IdempotencyKey == "" || j.Kind == "" {
		return fmt.Errorf("%w: idempotency key and kind are required", ErrInvalidJournal)
	}
	if len(j.Lines) < 2 {
		return fmt.Errorf("%w: needs at least two lines", ErrInvalidJournal)
	}
	var sum int64
	for _, l := range j.Lines {
		if l.Amount == 0 {
			return fmt.Errorf("%w: zero amount line", ErrInvalidJournal)
		}
		sum += l.Amount
	}
	if sum != 0 {
		return fmt.Errorf("%w: sum is %d", ErrUnbalanced, sum)
	}
	return nil
}

// Post writes j inside tx; the caller commits. Accounts are locked in id
// order so concurrent posts cannot deadlock or overspend.
func Post(ctx context.Context, tx pgx.Tx, j Journal) (Posted, error) {
	if err := j.validate(); err != nil {
		return Posted{}, err
	}

	var id int64
	err := tx.QueryRow(ctx, `
		insert into journals (idempotency_key, kind, description, ref)
		values ($1, $2, $3, $4)
		on conflict (idempotency_key) do nothing
		returning id`, j.IdempotencyKey, j.Kind, j.Description, j.Ref).Scan(&id)
	if errors.Is(err, pgx.ErrNoRows) {
		err = tx.QueryRow(ctx, `select id from journals where idempotency_key = $1`, j.IdempotencyKey).Scan(&id)
		return Posted{JournalID: id, Replayed: true}, err
	}
	if err != nil {
		return Posted{}, err
	}

	deltas := map[int64]int64{}
	for _, l := range j.Lines {
		deltas[l.AccountID] += l.Amount
	}
	ids := make([]int64, 0, len(deltas))
	for acct := range deltas {
		ids = append(ids, acct)
	}
	sort.Slice(ids, func(a, b int) bool { return ids[a] < ids[b] })

	for _, acct := range ids {
		var kind Kind
		var allowNegative bool
		var balance int64
		err := tx.QueryRow(ctx, `select kind, allow_negative, balance from accounts where id = $1 for update`, acct).
			Scan(&kind, &allowNegative, &balance)
		if errors.Is(err, pgx.ErrNoRows) {
			return Posted{}, fmt.Errorf("%w: %d", ErrUnknownAccount, acct)
		}
		if err != nil {
			return Posted{}, err
		}
		next := balance + kind.toBalance(deltas[acct])
		if next < 0 && !allowNegative {
			return Posted{}, fmt.Errorf("%w: account %d", ErrInsufficientFunds, acct)
		}
		if _, err := tx.Exec(ctx, `update accounts set balance = $2 where id = $1`, acct, next); err != nil {
			return Posted{}, err
		}
	}

	for _, l := range j.Lines {
		if _, err := tx.Exec(ctx, `insert into entries (journal_id, account_id, amount) values ($1, $2, $3)`,
			id, l.AccountID, l.Amount); err != nil {
			return Posted{}, err
		}
	}
	return Posted{JournalID: id}, nil
}

// Balance returns the account's balance on its normal side, in kobo.
func Balance(ctx context.Context, db DB, accountID int64) (int64, error) {
	var b int64
	err := db.QueryRow(ctx, `select balance from accounts where id = $1`, accountID).Scan(&b)
	if errors.Is(err, pgx.ErrNoRows) {
		return 0, fmt.Errorf("%w: %d", ErrUnknownAccount, accountID)
	}
	return b, err
}

type StatementLine struct {
	JournalID   int64     `json:"journal_id"`
	Kind        string    `json:"kind"`
	Description string    `json:"description"`
	Ref         string    `json:"ref"`
	Amount      int64     `json:"amount"` // positive raises the balance, negative lowers it
	At          time.Time `json:"at"`
}

// Statement lists the account's movements, newest first.
func Statement(ctx context.Context, db DB, accountID int64, limit int) ([]StatementLine, error) {
	var kind Kind
	if err := db.QueryRow(ctx, `select kind from accounts where id = $1`, accountID).Scan(&kind); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, fmt.Errorf("%w: %d", ErrUnknownAccount, accountID)
		}
		return nil, err
	}
	rows, err := db.Query(ctx, `
		select j.id, j.kind, j.description, j.ref, e.amount, e.created_at
		from entries e join journals j on j.id = e.journal_id
		where e.account_id = $1
		order by e.id desc
		limit $2`, accountID, limit)
	if err != nil {
		return nil, err
	}
	lines, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (StatementLine, error) {
		var s StatementLine
		err := r.Scan(&s.JournalID, &s.Kind, &s.Description, &s.Ref, &s.Amount, &s.At)
		s.Amount = kind.toBalance(s.Amount)
		return s, err
	})
	if lines == nil {
		lines = []StatementLine{}
	}
	return lines, err
}

// Check verifies that all entries sum to zero and that every cached balance
// matches its entries. Run it nightly and alert on any error.
func Check(ctx context.Context, db DB) error {
	var total int64
	if err := db.QueryRow(ctx, `select coalesce(sum(amount), 0) from entries`).Scan(&total); err != nil {
		return err
	}
	if total != 0 {
		return fmt.Errorf("ledger check: entries sum to %d, want 0", total)
	}
	rows, err := db.Query(ctx, `
		select a.id, a.kind, a.balance, coalesce(sum(e.amount), 0)
		from accounts a left join entries e on e.account_id = a.id
		group by a.id order by a.id`)
	if err != nil {
		return err
	}
	defer rows.Close()
	for rows.Next() {
		var id, balance, sum int64
		var kind Kind
		if err := rows.Scan(&id, &kind, &balance, &sum); err != nil {
			return err
		}
		if want := kind.toBalance(sum); balance != want {
			return fmt.Errorf("ledger check: account %d balance %d, entries say %d", id, balance, want)
		}
	}
	return rows.Err()
}
