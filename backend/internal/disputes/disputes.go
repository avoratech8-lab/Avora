// Package disputes lets a customer report a problem with a payment on their
// statement: it didn't arrive, the amount was wrong, they didn't make it, or
// they were charged twice. Each report is tracked until an agent answers it
// through the ops API, and the customer is notified of the answer.
package disputes

import (
	"context"
	"errors"
	"fmt"
	"regexp"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"

	"avora/backend/internal/notify"
)

var (
	ErrInvalid  = errors.New("disputes: invalid request")
	ErrNotFound = errors.New("disputes: not found")
	ErrOpen     = errors.New("disputes: already open")
	ErrClosed   = errors.New("disputes: already answered")
)

// Reasons a customer can pick, with the words the app shows.
var Reasons = map[string]string{
	"not_received":  "The money didn't arrive",
	"wrong_amount":  "The amount is wrong",
	"not_me":        "I didn't make this payment",
	"charged_twice": "I was charged twice",
	"other":         "Something else",
}

type Dispute struct {
	ID          string     `json:"id"`
	Ref         string     `json:"ref"`
	Kind        string     `json:"kind"`
	Description string     `json:"description"`
	Amount      int64      `json:"amount"` // as on the statement: negative is money out
	Reason      string     `json:"reason"`
	Details     string     `json:"details"`
	Status      string     `json:"status"` // open, resolved or rejected
	Answer      string     `json:"answer"`
	CreatedAt   time.Time  `json:"created_at"`
	ClosedAt    *time.Time `json:"closed_at"`
}

type Service struct{ db *pgxpool.Pool }

func NewService(db *pgxpool.Pool) *Service { return &Service{db: db} }

const cols = `id::text, ref, kind, description, amount, reason, details, status, answer, created_at, closed_at`

func scan(row pgx.Row) (Dispute, error) {
	var d Dispute
	err := row.Scan(&d.ID, &d.Ref, &d.Kind, &d.Description, &d.Amount, &d.Reason, &d.Details, &d.Status, &d.Answer,
		&d.CreatedAt, &d.ClosedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return d, ErrNotFound
	}
	return d, err
}

// Open reports a problem with the payment [ref] on the customer's own
// statement. A payment can have one open report at a time.
func (s *Service) Open(ctx context.Context, userID, walletID int64, ref, reason, details string) (Dispute, error) {
	ref = strings.TrimSpace(ref)
	details = strings.TrimSpace(details)
	if _, ok := Reasons[reason]; !ok {
		return Dispute{}, fmt.Errorf("%w: choose what went wrong", ErrInvalid)
	}
	if ref == "" {
		return Dispute{}, fmt.Errorf("%w: choose a payment", ErrInvalid)
	}
	if utf8.RuneCountInString(details) > 500 {
		return Dispute{}, fmt.Errorf("%w: keep the details under 500 characters", ErrInvalid)
	}
	if reason == "other" && details == "" {
		return Dispute{}, fmt.Errorf("%w: tell us what went wrong", ErrInvalid)
	}

	tx, err := s.db.Begin(ctx)
	if err != nil {
		return Dispute{}, err
	}
	defer tx.Rollback(ctx)

	// The payment must be on this wallet's statement. A transfer has a hold
	// and maybe a refund under the same ref; the first line is the payment.
	var kind, desc string
	var amount int64
	err = tx.QueryRow(ctx, `
		select j.kind, j.description, case when a.kind in ('asset', 'expense') then e.amount else -e.amount end
		from entries e join journals j on j.id = e.journal_id join accounts a on a.id = e.account_id
		where e.account_id = $1 and j.ref = $2
		order by e.id limit 1`, walletID, ref).Scan(&kind, &desc, &amount)
	if errors.Is(err, pgx.ErrNoRows) {
		return Dispute{}, ErrNotFound
	}
	if err != nil {
		return Dispute{}, err
	}

	d, err := scan(tx.QueryRow(ctx, `
		insert into disputes (user_id, wallet_account_id, ref, kind, description, amount, reason, details)
		values ($1, $2, $3, $4, $5, $6, $7, $8) returning `+cols,
		userID, walletID, ref, kind, desc, amount, reason, details))
	var pgErr *pgconn.PgError
	if errors.As(err, &pgErr) && pgErr.Code == "23505" {
		return Dispute{}, ErrOpen
	}
	if err != nil {
		return Dispute{}, err
	}
	if err := notify.Add(ctx, tx, walletID, "dispute", "We're looking into it",
		fmt.Sprintf("We got your report about %s (%s). We'll reply here, usually within 24 hours.",
			desc, notify.Naira(abs(amount))), d.ID); err != nil {
		return Dispute{}, err
	}
	return d, tx.Commit(ctx)
}

// List returns the customer's reports, newest first.
func (s *Service) List(ctx context.Context, userID int64) ([]Dispute, error) {
	rows, err := s.db.Query(ctx, `select `+cols+` from disputes where user_id = $1 order by created_at desc limit 100`, userID)
	if err != nil {
		return nil, err
	}
	out := []Dispute{}
	for rows.Next() {
		d, err := scan(rows)
		if err != nil {
			rows.Close()
			return nil, err
		}
		out = append(out, d)
	}
	return out, rows.Err()
}

var uuidRe = regexp.MustCompile(`^[0-9a-fA-F-]{36}$`)

// Get returns one of the customer's reports.
func (s *Service) Get(ctx context.Context, userID int64, id string) (Dispute, error) {
	if !uuidRe.MatchString(id) {
		return Dispute{}, ErrNotFound
	}
	return scan(s.db.QueryRow(ctx, `select `+cols+` from disputes where id = $1 and user_id = $2`, id, userID))
}

// Close answers an open report as resolved or rejected and tells the
// customer. Any money owed is returned separately, through the ledger.
func (s *Service) Close(ctx context.Context, id, outcome, answer string) (Dispute, error) {
	answer = strings.TrimSpace(answer)
	if outcome != "resolved" && outcome != "rejected" {
		return Dispute{}, fmt.Errorf("%w: outcome must be resolved or rejected", ErrInvalid)
	}
	if answer == "" {
		return Dispute{}, fmt.Errorf("%w: write an answer for the customer", ErrInvalid)
	}
	if !uuidRe.MatchString(id) {
		return Dispute{}, ErrNotFound
	}
	tx, err := s.db.Begin(ctx)
	if err != nil {
		return Dispute{}, err
	}
	defer tx.Rollback(ctx)
	var status string
	var wallet int64
	err = tx.QueryRow(ctx, `select status, wallet_account_id from disputes where id = $1 for update`, id).Scan(&status, &wallet)
	if errors.Is(err, pgx.ErrNoRows) {
		return Dispute{}, ErrNotFound
	}
	if err != nil {
		return Dispute{}, err
	}
	if status != "open" {
		return Dispute{}, ErrClosed
	}
	d, err := scan(tx.QueryRow(ctx, `
		update disputes set status = $2, answer = $3, closed_at = now() where id = $1 returning `+cols, id, outcome, answer))
	if err != nil {
		return Dispute{}, err
	}
	title := "Your report is resolved"
	if outcome == "rejected" {
		title = "We've answered your report"
	}
	if err := notify.Add(ctx, tx, wallet, "dispute", title, answer, d.ID); err != nil {
		return Dispute{}, err
	}
	return d, tx.Commit(ctx)
}

func abs(n int64) int64 {
	if n < 0 {
		return -n
	}
	return n
}
