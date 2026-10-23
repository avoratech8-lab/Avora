// Package savings runs non-interest savings pots.
//
// A goal pot takes money in and out at any time. A locked pot is funded
// once and held for a term; breaking it early returns the money but gives
// back any profit share it earned. Profit is not interest: after each
// period the partner bank declares a profit rate on the pooled deposits
// and ops shares it out with DistributeProfit. Expected rates shown to
// customers are indicative only.
package savings

import (
	"context"
	"errors"
	"fmt"
	"regexp"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"avora/backend/internal/ledger"
)

var (
	ErrInvalid  = errors.New("savings: invalid request")
	ErrNotFound = errors.New("savings: not found")
	ErrLocked   = errors.New("savings: this plan is locked")
	ErrClosed   = errors.New("savings: this pot is closed")
	ErrDeclared = errors.New("savings: profit for this period was already shared")
)

type Kind string

const (
	Goal   Kind = "goal"
	Locked Kind = "locked"
)

// Term is a locked-plan length with its expected (not promised) profit rate.
type Term struct {
	Days    int `json:"days"`
	RateBps int `json:"rate_bps"`
}

// Rates are the expected yearly profit rates shown before saving. They are
// placeholders until the partner bank publishes its profit-sharing ratios.
type Rates struct {
	GoalBps int    `json:"goal_rate_bps"`
	Terms   []Term `json:"locked_terms"`
}

func DefaultRates() Rates {
	return Rates{GoalBps: 800, Terms: []Term{{30, 1000}, {90, 1200}, {180, 1400}, {365, 1600}}}
}

type Pot struct {
	ID              string     `json:"id"`
	WalletAccountID int64      `json:"-"`
	AccountID       int64      `json:"-"`
	Kind            Kind       `json:"kind"`
	Name            string     `json:"name"`
	Target          int64      `json:"target"`
	LockDays        int        `json:"lock_days"`
	MaturesAt       *time.Time `json:"matures_at"`
	Balance         int64      `json:"balance"`
	ProfitEarned    int64      `json:"profit_earned"`
	ExpectedRateBps int        `json:"expected_rate_bps"`
	Status          string     `json:"status"`
	CreatedAt       time.Time  `json:"created_at"`
}

type Service struct {
	db     *pgxpool.Pool
	profit int64 // system:profit_share
	rates  Rates
	now    func() time.Time
}

func NewService(ctx context.Context, db *pgxpool.Pool, rates Rates) (*Service, error) {
	var profit int64
	if err := db.QueryRow(ctx, `select id from accounts where code = 'system:profit_share'`).Scan(&profit); err != nil {
		return nil, fmt.Errorf("savings: profit account missing; run migrations: %w", err)
	}
	return &Service{db: db, profit: profit, rates: rates, now: time.Now}, nil
}

func (s *Service) Rates() Rates { return s.rates }

func (s *Service) expectedRate(p Pot) int {
	if p.Kind == Goal {
		return s.rates.GoalBps
	}
	for _, t := range s.rates.Terms {
		if t.Days == p.LockDays {
			return t.RateBps
		}
	}
	return 0
}

type CreateRequest struct {
	IdempotencyKey  string
	WalletAccountID int64
	Kind            Kind
	Name            string
	Target          int64 // goal only, optional
	LockDays        int   // locked only
	Amount          int64 // first deposit; required for locked
}

// Create opens a pot and makes its first deposit, if any. Calling it again
// with the same idempotency key returns the same pot.
func (s *Service) Create(ctx context.Context, req CreateRequest) (Pot, error) {
	req.Name = strings.TrimSpace(req.Name)
	switch {
	case req.IdempotencyKey == "":
		return Pot{}, fmt.Errorf("%w: idempotency key is required", ErrInvalid)
	case req.Name == "" || len(req.Name) > 40:
		return Pot{}, fmt.Errorf("%w: give it a name of up to 40 characters", ErrInvalid)
	case req.Amount < 0 || req.Target < 0:
		return Pot{}, fmt.Errorf("%w: amounts can't be negative", ErrInvalid)
	}
	switch req.Kind {
	case Goal:
		req.LockDays = 0
	case Locked:
		ok := false
		for _, t := range s.rates.Terms {
			ok = ok || t.Days == req.LockDays
		}
		if !ok {
			return Pot{}, fmt.Errorf("%w: choose one of the offered terms", ErrInvalid)
		}
		if req.Amount < 1_000_00 {
			return Pot{}, fmt.Errorf("%w: a locked plan starts at ₦1,000", ErrInvalid)
		}
		req.Target = 0
	default:
		return Pot{}, fmt.Errorf("%w: kind must be goal or locked", ErrInvalid)
	}

	tx, err := s.db.Begin(ctx)
	if err != nil {
		return Pot{}, err
	}
	defer tx.Rollback(ctx)

	code := fmt.Sprintf("pot:%d:%s", req.WalletAccountID, req.IdempotencyKey)
	var acct int64
	err = tx.QueryRow(ctx, `
		insert into accounts (code, kind) values ($1, 'liability')
		on conflict (code) do nothing returning id`, code).Scan(&acct)
	if errors.Is(err, pgx.ErrNoRows) {
		// Same key again: return the pot it made.
		tx.Rollback(ctx)
		return s.potByAccountCode(ctx, code)
	}
	if err != nil {
		return Pot{}, err
	}

	now := s.now()
	var matures *time.Time
	if req.Kind == Locked {
		m := now.AddDate(0, 0, req.LockDays)
		matures = &m
	}
	var id string
	err = tx.QueryRow(ctx, `
		insert into savings_pots (wallet_account_id, account_id, kind, name, target, lock_days, matures_at, created_at)
		values ($1, $2, $3, $4, $5, $6, $7, $8) returning id`,
		req.WalletAccountID, acct, req.Kind, req.Name, req.Target, req.LockDays, matures, now).Scan(&id)
	if err != nil {
		return Pot{}, err
	}
	if req.Amount > 0 {
		if _, err := ledger.Post(ctx, tx, ledger.Journal{
			IdempotencyKey: "savings:" + id + ":open",
			Kind:           "savings_deposit",
			Description:    "Saved to " + req.Name,
			Ref:            id,
			Lines:          []ledger.Line{ledger.Debit(req.WalletAccountID, req.Amount), ledger.Credit(acct, req.Amount)},
		}); err != nil {
			return Pot{}, err
		}
	}
	if err := tx.Commit(ctx); err != nil {
		return Pot{}, err
	}
	return s.Get(ctx, req.WalletAccountID, id)
}

// Deposit moves money from the wallet into a goal pot.
func (s *Service) Deposit(ctx context.Context, walletID int64, potID, key string, amount int64) (Pot, error) {
	if key == "" || amount <= 0 {
		return Pot{}, fmt.Errorf("%w: an idempotency key and a positive amount are required", ErrInvalid)
	}
	p, err := s.Get(ctx, walletID, potID)
	if err != nil {
		return Pot{}, err
	}
	if p.Status != "open" {
		return Pot{}, ErrClosed
	}
	if p.Kind == Locked {
		return Pot{}, fmt.Errorf("%w: start a new plan to lock more money", ErrLocked)
	}
	err = s.post(ctx, ledger.Journal{
		IdempotencyKey: fmt.Sprintf("savings:%s:in:%s", p.ID, key),
		Kind:           "savings_deposit",
		Description:    "Saved to " + p.Name,
		Ref:            p.ID,
		Lines:          []ledger.Line{ledger.Debit(walletID, amount), ledger.Credit(p.AccountID, amount)},
	})
	if err != nil {
		return Pot{}, err
	}
	return s.Get(ctx, walletID, potID)
}

// Withdraw moves money back to the wallet. A goal pot pays out any amount
// up to its balance. A locked pot pays out in full and closes: at maturity
// with its profit; before maturity only when breakEarly is set, giving the
// profit share back.
func (s *Service) Withdraw(ctx context.Context, walletID int64, potID, key string, amount int64, breakEarly bool) (Pot, error) {
	if key == "" {
		return Pot{}, fmt.Errorf("%w: idempotency key is required", ErrInvalid)
	}
	tx, err := s.db.Begin(ctx)
	if err != nil {
		return Pot{}, err
	}
	defer tx.Rollback(ctx)

	p, err := s.lock(ctx, tx, walletID, potID)
	if err != nil {
		return Pot{}, err
	}
	if p.Status != "open" {
		return Pot{}, ErrClosed
	}

	ref := fmt.Sprintf("savings:%s:out:%s", p.ID, key)
	forfeit := int64(0)
	switch p.Kind {
	case Goal:
		if amount <= 0 {
			return Pot{}, fmt.Errorf("%w: amount must be positive", ErrInvalid)
		}
	case Locked:
		early := p.MaturesAt != nil && s.now().Before(*p.MaturesAt)
		if early && !breakEarly {
			return Pot{}, fmt.Errorf("%w until %s", ErrLocked, p.MaturesAt.Format("2 Jan 2006"))
		}
		amount = p.Balance
		if early {
			forfeit = min(p.ProfitEarned, p.Balance)
		}
	}

	if amount > 0 {
		lines := []ledger.Line{ledger.Debit(p.AccountID, amount)}
		if amount > forfeit {
			lines = append(lines, ledger.Credit(walletID, amount-forfeit))
		}
		if forfeit > 0 {
			lines = append(lines, ledger.Credit(s.profit, forfeit))
		}
		desc := "From " + p.Name
		if forfeit > 0 {
			desc = fmt.Sprintf("From %s (broken early, profit share returned)", p.Name)
		}
		posted, err := ledger.Post(ctx, tx, ledger.Journal{
			IdempotencyKey: ref, Kind: "savings_withdraw", Description: desc, Ref: p.ID, Lines: lines,
		})
		if err != nil {
			return Pot{}, err
		}
		if posted.Replayed {
			tx.Rollback(ctx)
			return s.Get(ctx, walletID, potID)
		}
	}
	// A locked plan pays out once and closes; a goal stays open at zero.
	if p.Kind == Locked {
		if _, err := tx.Exec(ctx, `
			update savings_pots set status = 'closed', closed_at = $2, profit_earned = profit_earned - $3
			where id = $1`, p.ID, s.now(), forfeit); err != nil {
			return Pot{}, err
		}
	}
	if err := tx.Commit(ctx); err != nil {
		return Pot{}, err
	}
	return s.Get(ctx, walletID, potID)
}

func (s *Service) post(ctx context.Context, j ledger.Journal) error {
	tx, err := s.db.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	if _, err := ledger.Post(ctx, tx, j); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

// List returns a wallet's pots, open ones first.
func (s *Service) List(ctx context.Context, walletID int64) ([]Pot, error) {
	rows, err := s.db.Query(ctx, `select `+columns+` from savings_pots p join accounts a on a.id = p.account_id
		where p.wallet_account_id = $1 order by p.status = 'closed', p.created_at desc`, walletID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Pot{}
	for rows.Next() {
		p, err := s.scan(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, p)
	}
	return out, rows.Err()
}

var uuidRe = regexp.MustCompile(`^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$`)

// Get returns one of the wallet's pots; other wallets' pots are not found.
func (s *Service) Get(ctx context.Context, walletID int64, id string) (Pot, error) {
	if !uuidRe.MatchString(id) {
		return Pot{}, ErrNotFound
	}
	return s.scan(s.db.QueryRow(ctx, `select `+columns+` from savings_pots p join accounts a on a.id = p.account_id
		where p.id = $1 and p.wallet_account_id = $2`, id, walletID))
}

func (s *Service) lock(ctx context.Context, tx pgx.Tx, walletID int64, id string) (Pot, error) {
	if !uuidRe.MatchString(id) {
		return Pot{}, ErrNotFound
	}
	return s.scan(tx.QueryRow(ctx, `select `+columns+` from savings_pots p join accounts a on a.id = p.account_id
		where p.id = $1 and p.wallet_account_id = $2 for update of p`, id, walletID))
}

func (s *Service) potByAccountCode(ctx context.Context, code string) (Pot, error) {
	return s.scan(s.db.QueryRow(ctx, `select `+columns+` from savings_pots p join accounts a on a.id = p.account_id
		where a.code = $1`, code))
}

const columns = `p.id, p.wallet_account_id, p.account_id, p.kind, p.name, p.target, p.lock_days, p.matures_at,
	a.balance, p.profit_earned, p.status, p.created_at`

func (s *Service) scan(row pgx.Row) (Pot, error) {
	var p Pot
	err := row.Scan(&p.ID, &p.WalletAccountID, &p.AccountID, &p.Kind, &p.Name, &p.Target, &p.LockDays, &p.MaturesAt,
		&p.Balance, &p.ProfitEarned, &p.Status, &p.CreatedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return Pot{}, ErrNotFound
	}
	p.ExpectedRateBps = s.expectedRate(p)
	return p, err
}

var periodRe = regexp.MustCompile(`^\d{4}-(0[1-9]|1[0-2])$`)

type ProfitRun struct {
	Period string `json:"period"`
	Pots   int    `json:"pots"`
	Total  int64  `json:"total"`
}

// DistributeProfit shares a month's declared profit: each open pot gets
// balance × yearly rate ÷ 12. Each period can be shared once.
//
// TODO: use average daily balance once the partner bank confirms its
// method; month-end balance is a simplification.
func (s *Service) DistributeProfit(ctx context.Context, period string, goalBps, lockedBps int) (ProfitRun, error) {
	if !periodRe.MatchString(period) || goalBps < 0 || lockedBps < 0 || goalBps > 5000 || lockedBps > 5000 {
		return ProfitRun{}, fmt.Errorf("%w: period is YYYY-MM and rates are 0 to 5000 basis points", ErrInvalid)
	}
	tx, err := s.db.Begin(ctx)
	if err != nil {
		return ProfitRun{}, err
	}
	defer tx.Rollback(ctx)

	tag, err := tx.Exec(ctx, `
		insert into savings_profit_runs (period, goal_rate_bps, locked_rate_bps, pots, total)
		values ($1, $2, $3, 0, 0) on conflict (period) do nothing`, period, goalBps, lockedBps)
	if err != nil {
		return ProfitRun{}, err
	}
	if tag.RowsAffected() == 0 {
		return ProfitRun{}, ErrDeclared
	}

	rows, err := tx.Query(ctx, `select `+columns+` from savings_pots p join accounts a on a.id = p.account_id
		where p.status = 'open' and a.balance > 0 order by p.id for update of p`)
	if err != nil {
		return ProfitRun{}, err
	}
	var pots []Pot
	for rows.Next() {
		p, err := s.scan(rows)
		if err != nil {
			rows.Close()
			return ProfitRun{}, err
		}
		pots = append(pots, p)
	}
	rows.Close()

	run := ProfitRun{Period: period}
	for _, p := range pots {
		rate := goalBps
		if p.Kind == Locked {
			rate = lockedBps
		}
		share := p.Balance * int64(rate) / 10_000 / 12
		if share <= 0 {
			continue
		}
		if _, err := ledger.Post(ctx, tx, ledger.Journal{
			IdempotencyKey: "profit:" + period + ":" + p.ID,
			Kind:           "savings_profit",
			Description:    fmt.Sprintf("Profit share for %s (%s)", p.Name, period),
			Ref:            p.ID,
			Lines:          []ledger.Line{ledger.Debit(s.profit, share), ledger.Credit(p.AccountID, share)},
		}); err != nil {
			return ProfitRun{}, err
		}
		if _, err := tx.Exec(ctx, `update savings_pots set profit_earned = profit_earned + $2 where id = $1`, p.ID, share); err != nil {
			return ProfitRun{}, err
		}
		run.Pots++
		run.Total += share
	}
	if _, err := tx.Exec(ctx, `update savings_profit_runs set pots = $2, total = $3 where period = $1`,
		period, run.Pots, run.Total); err != nil {
		return ProfitRun{}, err
	}
	return run, tx.Commit(ctx)
}
