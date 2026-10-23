// Package schedules keeps payments that run later or repeat: a bank
// transfer, an Avora transfer, a bill or a savings deposit, once, daily,
// weekly or monthly. It only stores and times them; the API server runs
// each one through the same services (and limits) as a payment made by hand.
package schedules

import (
	"context"
	"errors"
	"fmt"
	"regexp"
	"slices"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

var (
	ErrInvalid  = errors.New("schedules: invalid request")
	ErrNotFound = errors.New("schedules: not found")
)

// MaxActive is how many active or paused schedules a customer can hold.
const MaxActive = 20

var (
	Kinds       = []string{"transfer", "avora", "bill", "savings"}
	Frequencies = []string{"once", "daily", "weekly", "monthly"}
)

// Target is who or what a schedule pays; which fields are set depends on
// the kind.
type Target struct {
	BankCode      string `json:"bank_code,omitempty"`
	AccountNumber string `json:"account_number,omitempty"`
	AccountName   string `json:"account_name,omitempty"`
	To            string `json:"to,omitempty"` // @tag or phone
	BillerID      string `json:"biller_id,omitempty"`
	PlanCode      string `json:"plan_code,omitempty"`
	Customer      string `json:"customer,omitempty"`
	PotID         string `json:"pot_id,omitempty"`
}

type Schedule struct {
	ID          string     `json:"id"`
	UserID      int64      `json:"-"`
	WalletID    int64      `json:"-"`
	Kind        string     `json:"kind"`
	Name        string     `json:"name"`
	Amount      int64      `json:"amount"`
	Frequency   string     `json:"frequency"`
	StartsAt    time.Time  `json:"starts_at"`
	NextRun     time.Time  `json:"next_run"`
	Runs        int        `json:"runs"`
	Status      string     `json:"status"`
	Target      Target     `json:"target"`
	LastRunAt   *time.Time `json:"last_run_at"`
	LastOK      *bool      `json:"last_ok"`
	LastMessage string     `json:"last_message"`
	CreatedAt   time.Time  `json:"created_at"`
}

type Service struct {
	db  *pgxpool.Pool
	Now func() time.Time
}

func NewService(db *pgxpool.Pool) *Service { return &Service{db: db, Now: time.Now} }

// Occurrence returns the n-th run (from 0) of a schedule that starts at
// start. Monthly runs keep the start's day, or the month's last day when
// the month is shorter.
func Occurrence(start time.Time, frequency string, n int) time.Time {
	switch frequency {
	case "daily":
		return start.AddDate(0, 0, n)
	case "weekly":
		return start.AddDate(0, 0, 7*n)
	case "monthly":
		first := time.Date(start.Year(), start.Month()+time.Month(n), 1, start.Hour(), start.Minute(), start.Second(),
			start.Nanosecond(), start.Location())
		last := first.AddDate(0, 1, -1).Day()
		return first.AddDate(0, 0, min(start.Day(), last)-1)
	}
	return start
}

var (
	nubanRe = regexp.MustCompile(`^\d{10}$`)
	bankRe  = regexp.MustCompile(`^\d{3,6}$`)
)

func check(s Schedule, now time.Time) error {
	if !slices.Contains(Kinds, s.Kind) {
		return fmt.Errorf("%w: unknown kind", ErrInvalid)
	}
	if !slices.Contains(Frequencies, s.Frequency) {
		return fmt.Errorf("%w: choose once, daily, weekly or monthly", ErrInvalid)
	}
	if s.Amount <= 0 || s.Amount > 10_000_000_00 {
		return fmt.Errorf("%w: amount must be between ₦0.01 and ₦10,000,000", ErrInvalid)
	}
	if n := len([]rune(s.Name)); n == 0 || n > 40 {
		return fmt.Errorf("%w: give it a name of up to 40 characters", ErrInvalid)
	}
	if s.StartsAt.Before(now.Add(-time.Minute)) || s.StartsAt.After(now.AddDate(1, 0, 0)) {
		return fmt.Errorf("%w: start from now to a year ahead", ErrInvalid)
	}
	t := s.Target
	switch s.Kind {
	case "transfer":
		if !bankRe.MatchString(t.BankCode) || !nubanRe.MatchString(t.AccountNumber) {
			return fmt.Errorf("%w: choose a bank and a 10-digit account number", ErrInvalid)
		}
	case "avora":
		if strings.TrimSpace(t.To) == "" {
			return fmt.Errorf("%w: who should it go to?", ErrInvalid)
		}
	case "bill":
		if t.BillerID == "" || t.Customer == "" {
			return fmt.Errorf("%w: choose a biller and number", ErrInvalid)
		}
	case "savings":
		if t.PotID == "" {
			return fmt.Errorf("%w: choose a savings pot", ErrInvalid)
		}
	}
	return nil
}

const columns = `id, user_id, wallet_account_id, kind, name, amount, frequency, starts_at, next_run, runs, status, target,
	last_run_at, last_ok, last_message, created_at`

func scan(row pgx.Row) (Schedule, error) {
	var s Schedule
	err := row.Scan(&s.ID, &s.UserID, &s.WalletID, &s.Kind, &s.Name, &s.Amount, &s.Frequency, &s.StartsAt, &s.NextRun,
		&s.Runs, &s.Status, &s.Target, &s.LastRunAt, &s.LastOK, &s.LastMessage, &s.CreatedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return Schedule{}, ErrNotFound
	}
	return s, err
}

// Create stores a new schedule. Its first run is at StartsAt.
func (s *Service) Create(ctx context.Context, sc Schedule) (Schedule, error) {
	sc.Name = strings.TrimSpace(sc.Name)
	if err := check(sc, s.Now()); err != nil {
		return Schedule{}, err
	}
	var n int
	if err := s.db.QueryRow(ctx, `select count(*) from schedules where user_id = $1 and status in ('active', 'paused')`,
		sc.UserID).Scan(&n); err != nil {
		return Schedule{}, err
	}
	if n >= MaxActive {
		return Schedule{}, fmt.Errorf("%w: you can have up to %d scheduled payments", ErrInvalid, MaxActive)
	}
	return scan(s.db.QueryRow(ctx, `
		insert into schedules (user_id, wallet_account_id, kind, name, amount, frequency, starts_at, next_run, target)
		values ($1, $2, $3, $4, $5, $6, $7, $7, $8)
		returning `+columns, sc.UserID, sc.WalletID, sc.Kind, sc.Name, sc.Amount, sc.Frequency, sc.StartsAt, sc.Target))
}

var uuidRe = regexp.MustCompile(`^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$`)

func (s *Service) Get(ctx context.Context, userID int64, id string) (Schedule, error) {
	if !uuidRe.MatchString(id) {
		return Schedule{}, ErrNotFound
	}
	return scan(s.db.QueryRow(ctx, `select `+columns+` from schedules where id = $1 and user_id = $2`, id, userID))
}

// List returns a customer's live schedules, soonest first, then finished ones.
func (s *Service) List(ctx context.Context, userID int64) ([]Schedule, error) {
	rows, err := s.db.Query(ctx, `select `+columns+` from schedules where user_id = $1 and status <> 'cancelled'
		order by status in ('done'), next_run limit 50`, userID)
	if err != nil {
		return nil, err
	}
	out, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (Schedule, error) { return scan(r) })
	if out == nil {
		out = []Schedule{}
	}
	return out, err
}

// SetPaused pauses or resumes a schedule. Resuming skips runs that were
// missed while paused.
func (s *Service) SetPaused(ctx context.Context, userID int64, id string, paused bool) (Schedule, error) {
	sc, err := s.Get(ctx, userID, id)
	if err != nil {
		return Schedule{}, err
	}
	if sc.Status != "active" && sc.Status != "paused" {
		return Schedule{}, fmt.Errorf("%w: this payment has finished", ErrInvalid)
	}
	if paused {
		_, err = s.db.Exec(ctx, `update schedules set status = 'paused' where id = $1`, id)
	} else {
		runs, next := sc.Runs, sc.NextRun
		for now := s.Now(); next.Before(now) && sc.Frequency != "once"; {
			runs++
			next = Occurrence(sc.StartsAt, sc.Frequency, runs)
		}
		_, err = s.db.Exec(ctx, `update schedules set status = 'active', runs = $2, next_run = $3 where id = $1`,
			id, runs, next)
	}
	if err != nil {
		return Schedule{}, err
	}
	return s.Get(ctx, userID, id)
}

func (s *Service) Cancel(ctx context.Context, userID int64, id string) error {
	if _, err := s.Get(ctx, userID, id); err != nil {
		return err
	}
	_, err := s.db.Exec(ctx, `update schedules set status = 'cancelled' where id = $1`, id)
	return err
}

// Claim takes up to limit due schedules and moves each to its next run (or
// marks a one-off done) before it is paid, so two workers never pay the
// same run. It returns them with Runs set to the run being paid.
func (s *Service) Claim(ctx context.Context, limit int) ([]Schedule, error) {
	tx, err := s.db.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	rows, err := tx.Query(ctx, `select `+columns+` from schedules where status = 'active' and next_run <= $1
		order by next_run limit $2 for update skip locked`, s.Now(), limit)
	if err != nil {
		return nil, err
	}
	due, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (Schedule, error) { return scan(r) })
	if err != nil {
		return nil, err
	}
	for _, sc := range due {
		if err := s.advance(ctx, tx, sc); err != nil {
			return nil, err
		}
	}
	return due, tx.Commit(ctx)
}

// ClaimOne claims one schedule now, whatever its next run; for trying a
// schedule out in the sandbox.
func (s *Service) ClaimOne(ctx context.Context, userID int64, id string) (Schedule, error) {
	sc, err := s.Get(ctx, userID, id)
	if err != nil {
		return Schedule{}, err
	}
	if sc.Status != "active" {
		return Schedule{}, fmt.Errorf("%w: only an active payment can run", ErrInvalid)
	}
	tx, err := s.db.Begin(ctx)
	if err != nil {
		return Schedule{}, err
	}
	defer tx.Rollback(ctx)
	if err := s.advance(ctx, tx, sc); err != nil {
		return Schedule{}, err
	}
	return sc, tx.Commit(ctx)
}

func (s *Service) advance(ctx context.Context, tx pgx.Tx, sc Schedule) error {
	if sc.Frequency == "once" {
		_, err := tx.Exec(ctx, `update schedules set status = 'done', runs = runs + 1 where id = $1`, sc.ID)
		return err
	}
	runs, next := sc.Runs+1, Occurrence(sc.StartsAt, sc.Frequency, sc.Runs+1)
	// After downtime, skip to the next future run rather than paying a backlog.
	for now := s.Now(); !next.After(now); {
		runs++
		next = Occurrence(sc.StartsAt, sc.Frequency, runs)
	}
	_, err := tx.Exec(ctx, `update schedules set runs = $2, next_run = $3 where id = $1`, sc.ID, runs, next)
	return err
}

// Record notes how a run went.
func (s *Service) Record(ctx context.Context, id string, ok bool, message string) error {
	_, err := s.db.Exec(ctx, `update schedules set last_run_at = $2, last_ok = $3, last_message = $4 where id = $1`,
		id, s.Now(), ok, message)
	return err
}
