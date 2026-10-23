// Package transfers moves money from a wallet to any Nigerian bank account.
//
// Lifecycle: held -> sent -> delivered | refunded. Money (amount plus fee)
// moves from the wallet into the in-flight account when the transfer is
// held. It leaves in-flight exactly once: to settlement and fee revenue on
// delivery, or back to the wallet on refund. A transfer without a final
// answer is requeried on a backoff and never resent; if the bank still has
// not answered after Config.ReviewAfter it goes to needs_review for ops.
package transfers

import (
	"context"
	"errors"
	"fmt"
	"regexp"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"avora/backend/internal/ledger"
	"avora/backend/internal/rails"
	"avora/backend/internal/wallets"
)

var (
	ErrInvalid             = errors.New("transfers: invalid request")
	ErrNotFound            = errors.New("transfers: not found")
	ErrIdempotencyConflict = errors.New("transfers: idempotency key reused with different details")
	ErrNotResolvable       = errors.New("transfers: only transfers in needs_review can be resolved by hand")
)

type Status string

const (
	Held        Status = "held"
	Sent        Status = "sent"
	Delivered   Status = "delivered"
	Refunded    Status = "refunded"
	NeedsReview Status = "needs_review"
)

func (s Status) final() bool { return s == Delivered || s == Refunded }

type Transfer struct {
	ID              string     `json:"id"`
	IdempotencyKey  string     `json:"-"`
	WalletAccountID int64      `json:"wallet_id"`
	BankCode        string     `json:"bank_code"`
	AccountNumber   string     `json:"account_number"`
	AccountName     string     `json:"account_name"`
	Narration       string     `json:"narration"`
	Amount          int64      `json:"amount"`
	Fee             int64      `json:"fee"`
	Status          Status     `json:"status"`
	SessionID       string     `json:"session_id,omitempty"`
	FailureReason   string     `json:"failure_reason,omitempty"`
	RequeryCount    int        `json:"-"`
	NextRequeryAt   *time.Time `json:"-"`
	CreatedAt       time.Time  `json:"created_at"`
	UpdatedAt       time.Time  `json:"updated_at"`
}

type Config struct {
	InterbankFee          int64 // kobo, charged after the free allowance
	FreeTransfersPerMonth int
	RequeryBackoff        []time.Duration
	ReviewAfter           time.Duration
}

// DefaultConfig uses placeholder pricing until it is decided: 5 free
// transfers a month, then ₦10 each.
func DefaultConfig() Config {
	return Config{
		InterbankFee:          10_00,
		FreeTransfersPerMonth: 5,
		RequeryBackoff: []time.Duration{
			time.Minute, 2 * time.Minute, 5 * time.Minute, 10 * time.Minute, 30 * time.Minute, time.Hour,
		},
		ReviewAfter: 6 * time.Hour,
	}
}

type Service struct {
	db   *pgxpool.Pool
	rail rails.Rail
	sys  wallets.System
	cfg  Config
	now  func() time.Time
}

func NewService(db *pgxpool.Pool, rail rails.Rail, sys wallets.System, cfg Config) *Service {
	return &Service{db: db, rail: rail, sys: sys, cfg: cfg, now: time.Now}
}

type InitiateRequest struct {
	IdempotencyKey  string
	WalletAccountID int64
	BankCode        string
	AccountNumber   string
	Amount          int64
	Narration       string
}

var nubanRe = regexp.MustCompile(`^\d{10}$`)

func (r InitiateRequest) validate() error {
	switch {
	case r.IdempotencyKey == "":
		return fmt.Errorf("%w: idempotency key is required", ErrInvalid)
	case r.Amount <= 0:
		return fmt.Errorf("%w: amount must be positive", ErrInvalid)
	case r.BankCode == "":
		return fmt.Errorf("%w: bank code is required", ErrInvalid)
	case !nubanRe.MatchString(r.AccountNumber):
		return fmt.Errorf("%w: account number must be 10 digits", ErrInvalid)
	case len(r.Narration) > 100:
		return fmt.Errorf("%w: narration is limited to 100 characters", ErrInvalid)
	}
	return nil
}

// Initiate holds the funds and sends the transfer. Calling it again with
// the same idempotency key returns the same transfer and moves no money.
func (s *Service) Initiate(ctx context.Context, req InitiateRequest) (Transfer, error) {
	if err := req.validate(); err != nil {
		return Transfer{}, err
	}
	if t, err := s.byKey(ctx, s.db, req.IdempotencyKey); err == nil {
		return t, sameRequest(t, req)
	} else if !errors.Is(err, ErrNotFound) {
		return Transfer{}, err
	}

	name, err := s.rail.NameEnquiry(ctx, req.BankCode, req.AccountNumber)
	if err != nil {
		return Transfer{}, fmt.Errorf("%w: name enquiry: %v", ErrInvalid, err)
	}

	t, created, err := s.hold(ctx, req, name)
	if err != nil || !created {
		return t, err
	}
	return s.dispatch(ctx, t)
}

func sameRequest(t Transfer, req InitiateRequest) error {
	if t.WalletAccountID != req.WalletAccountID || t.Amount != req.Amount ||
		t.BankCode != req.BankCode || t.AccountNumber != req.AccountNumber {
		return ErrIdempotencyConflict
	}
	return nil
}

func (s *Service) hold(ctx context.Context, req InitiateRequest, name string) (Transfer, bool, error) {
	tx, err := s.db.Begin(ctx)
	if err != nil {
		return Transfer{}, false, err
	}
	defer tx.Rollback(ctx)

	// Lock the wallet first so the free-transfer count can't race.
	if _, err := tx.Exec(ctx, `select 1 from wallets where account_id = $1 for update`, req.WalletAccountID); err != nil {
		return Transfer{}, false, err
	}
	if _, err := wallets.Get(ctx, tx, req.WalletAccountID); err != nil {
		return Transfer{}, false, err
	}

	fee, err := s.fee(ctx, tx, req.WalletAccountID)
	if err != nil {
		return Transfer{}, false, err
	}

	now := s.now()
	retry := now.Add(s.cfg.RequeryBackoff[0])
	var id string
	err = tx.QueryRow(ctx, `
		insert into transfers (idempotency_key, wallet_account_id, bank_code, account_number,
			account_name, narration, amount, fee, status, next_requery_at, created_at, updated_at)
		values ($1, $2, $3, $4, $5, $6, $7, $8, 'held', $9, $10, $10)
		on conflict (idempotency_key) do nothing
		returning id`,
		req.IdempotencyKey, req.WalletAccountID, req.BankCode, req.AccountNumber,
		name, req.Narration, req.Amount, fee, retry, now).Scan(&id)
	if errors.Is(err, pgx.ErrNoRows) {
		// A concurrent request with the same key won the race.
		tx.Rollback(ctx)
		t, err := s.byKey(ctx, s.db, req.IdempotencyKey)
		if err != nil {
			return Transfer{}, false, err
		}
		return t, false, sameRequest(t, req)
	}
	if err != nil {
		return Transfer{}, false, err
	}

	total := req.Amount + fee
	if _, err := ledger.Post(ctx, tx, ledger.Journal{
		IdempotencyKey: "transfer:" + id + ":hold",
		Kind:           "transfer_hold",
		Description:    fmt.Sprintf("Transfer to %s (%s)", name, req.AccountNumber),
		Ref:            id,
		Lines: []ledger.Line{
			ledger.Debit(req.WalletAccountID, total),
			ledger.Credit(s.sys.InFlight, total),
		},
	}); err != nil {
		return Transfer{}, false, err
	}

	t, err := s.get(ctx, tx, id)
	if err != nil {
		return Transfer{}, false, err
	}
	return t, true, tx.Commit(ctx)
}

func (s *Service) fee(ctx context.Context, db ledger.DB, walletID int64) (int64, error) {
	used, err := s.usedThisMonth(ctx, db, walletID)
	if err != nil {
		return 0, err
	}
	if used < s.cfg.FreeTransfersPerMonth {
		return 0, nil
	}
	return s.cfg.InterbankFee, nil
}

func (s *Service) usedThisMonth(ctx context.Context, db ledger.DB, walletID int64) (int, error) {
	now := s.now().UTC()
	monthStart := time.Date(now.Year(), now.Month(), 1, 0, 0, 0, 0, time.UTC)
	var used int
	err := db.QueryRow(ctx, `
		select count(*) from transfers
		where wallet_account_id = $1 and created_at >= $2 and status <> 'refunded'`,
		walletID, monthStart).Scan(&used)
	return used, err
}

type Quote struct {
	Amount            int64 `json:"amount"`
	Fee               int64 `json:"fee"`
	Total             int64 `json:"total"`
	FreeTransfersLeft int   `json:"free_transfers_left"`
}

// Quote shows the fee a transfer would cost right now, so the app can
// show the total before the customer confirms.
func (s *Service) Quote(ctx context.Context, walletID, amount int64) (Quote, error) {
	if amount <= 0 {
		return Quote{}, fmt.Errorf("%w: amount must be positive", ErrInvalid)
	}
	used, err := s.usedThisMonth(ctx, s.db, walletID)
	if err != nil {
		return Quote{}, err
	}
	q := Quote{Amount: amount, FreeTransfersLeft: max(0, s.cfg.FreeTransfersPerMonth-used)}
	if q.FreeTransfersLeft == 0 {
		q.Fee = s.cfg.InterbankFee
	}
	q.Total = q.Amount + q.Fee
	return q, nil
}

func (s *Service) dispatch(ctx context.Context, t Transfer) (Transfer, error) {
	res, err := s.rail.Send(ctx, rails.SendRequest{
		Reference:     t.ID,
		BankCode:      t.BankCode,
		AccountNumber: t.AccountNumber,
		AccountName:   t.AccountName,
		Amount:        t.Amount,
		Narration:     t.Narration,
	})
	if err != nil {
		res = rails.Result{Status: rails.Pending}
	}
	return s.apply(ctx, t, res)
}

// apply moves a transfer forward from a rail result.
func (s *Service) apply(ctx context.Context, t Transfer, res rails.Result) (Transfer, error) {
	switch res.Status {
	case rails.Success:
		return s.finalize(ctx, t.ID, Delivered, res.SessionID, "")
	case rails.Failed:
		return s.finalize(ctx, t.ID, Refunded, res.SessionID, res.Reason)
	case rails.NotFound:
		if t.Status == Held {
			return s.finalize(ctx, t.ID, Refunded, "", "transfer never reached the bank")
		}
	}
	return s.waitLonger(ctx, t)
}

func (s *Service) waitLonger(ctx context.Context, t Transfer) (Transfer, error) {
	now := s.now()
	if now.Sub(t.CreatedAt) >= s.cfg.ReviewAfter {
		_, err := s.db.Exec(ctx, `
			update transfers set status = 'needs_review', next_requery_at = null, updated_at = $2
			where id = $1 and status in ('held', 'sent')`, t.ID, now)
		if err != nil {
			return Transfer{}, err
		}
		return s.get(ctx, s.db, t.ID)
	}
	i := min(t.RequeryCount, len(s.cfg.RequeryBackoff)-1)
	_, err := s.db.Exec(ctx, `
		update transfers set status = 'sent', requery_count = requery_count + 1,
			next_requery_at = $2, updated_at = $3
		where id = $1 and status in ('held', 'sent')`, t.ID, now.Add(s.cfg.RequeryBackoff[i]), now)
	if err != nil {
		return Transfer{}, err
	}
	return s.get(ctx, s.db, t.ID)
}

// finalize posts the closing journal and sets the final status. It is safe
// to call more than once: a transfer already final is returned unchanged.
func (s *Service) finalize(ctx context.Context, id string, to Status, sessionID, reason string) (Transfer, error) {
	tx, err := s.db.Begin(ctx)
	if err != nil {
		return Transfer{}, err
	}
	defer tx.Rollback(ctx)

	t, err := s.getForUpdate(ctx, tx, id)
	if err != nil {
		return Transfer{}, err
	}
	if t.Status.final() {
		return t, nil
	}

	total := t.Amount + t.Fee
	j := ledger.Journal{IdempotencyKey: "transfer:" + id + ":" + string(to), Ref: id}
	switch to {
	case Delivered:
		j.Kind, j.Description = "transfer_settle", fmt.Sprintf("Transfer to %s delivered", t.AccountName)
		j.Lines = []ledger.Line{ledger.Debit(s.sys.InFlight, total), ledger.Credit(s.sys.Settlement, t.Amount)}
		if t.Fee > 0 {
			j.Lines = append(j.Lines, ledger.Credit(s.sys.FeeRevenue, t.Fee))
		}
	case Refunded:
		j.Kind, j.Description = "transfer_refund", fmt.Sprintf("Refund: transfer to %s did not go through", t.AccountName)
		j.Lines = []ledger.Line{ledger.Debit(s.sys.InFlight, total), ledger.Credit(t.WalletAccountID, total)}
	default:
		return Transfer{}, fmt.Errorf("transfers: cannot finalize to %q", to)
	}
	if _, err := ledger.Post(ctx, tx, j); err != nil {
		return Transfer{}, err
	}

	_, err = tx.Exec(ctx, `
		update transfers set status = $2, session_id = coalesce(nullif($3, ''), session_id),
			failure_reason = nullif($4, ''), next_requery_at = null, updated_at = $5
		where id = $1`, id, to, sessionID, reason, s.now())
	if err != nil {
		return Transfer{}, err
	}
	t, err = s.get(ctx, tx, id)
	if err != nil {
		return Transfer{}, err
	}
	return t, tx.Commit(ctx)
}

// RequeryDue asks the rail about transfers whose retry time has passed.
// Run it on a short interval; it returns how many transfers it checked.
func (s *Service) RequeryDue(ctx context.Context, limit int) (int, error) {
	rows, err := s.db.Query(ctx, `
		select id from transfers
		where status in ('held', 'sent') and next_requery_at <= $1
		order by next_requery_at limit $2`, s.now(), limit)
	if err != nil {
		return 0, err
	}
	ids, err := pgx.CollectRows(rows, pgx.RowTo[string])
	if err != nil {
		return 0, err
	}
	for _, id := range ids {
		t, err := s.get(ctx, s.db, id)
		if err != nil {
			return 0, err
		}
		res, err := s.rail.Status(ctx, id)
		if err != nil {
			res = rails.Result{Status: rails.Pending}
		}
		if _, err := s.apply(ctx, t, res); err != nil {
			return 0, err
		}
	}
	return len(ids), nil
}

// Resolve lets operations close a transfer in needs_review once the bank
// has confirmed the outcome out of band.
func (s *Service) Resolve(ctx context.Context, id string, to Status, sessionID, note string) (Transfer, error) {
	t, err := s.get(ctx, s.db, id)
	if err != nil {
		return Transfer{}, err
	}
	if t.Status != NeedsReview {
		return Transfer{}, ErrNotResolvable
	}
	if to != Delivered && to != Refunded {
		return Transfer{}, fmt.Errorf("%w: outcome must be delivered or refunded", ErrInvalid)
	}
	return s.finalize(ctx, id, to, sessionID, note)
}

func (s *Service) Get(ctx context.Context, id string) (Transfer, error) { return s.get(ctx, s.db, id) }

// SentSince totals what a wallet has sent (or has in flight) since t,
// excluding refunds. Used for per-device and per-tier limits.
func (s *Service) SentSince(ctx context.Context, walletID int64, t time.Time) (int64, error) {
	var total int64
	err := s.db.QueryRow(ctx, `
		select coalesce(sum(amount), 0) from transfers
		where wallet_account_id = $1 and created_at >= $2 and status <> 'refunded'`, walletID, t).Scan(&total)
	return total, err
}

const columns = `id, idempotency_key, wallet_account_id, bank_code, account_number, account_name,
	narration, amount, fee, status, coalesce(session_id, ''), coalesce(failure_reason, ''),
	requery_count, next_requery_at, created_at, updated_at`

var uuidRe = regexp.MustCompile(`^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$`)

func (s *Service) get(ctx context.Context, db ledger.DB, id string) (Transfer, error) {
	if !uuidRe.MatchString(id) {
		return Transfer{}, ErrNotFound
	}
	return scanOne(db.QueryRow(ctx, `select `+columns+` from transfers where id = $1`, id))
}

func (s *Service) getForUpdate(ctx context.Context, tx pgx.Tx, id string) (Transfer, error) {
	if !uuidRe.MatchString(id) {
		return Transfer{}, ErrNotFound
	}
	return scanOne(tx.QueryRow(ctx, `select `+columns+` from transfers where id = $1 for update`, id))
}

func (s *Service) byKey(ctx context.Context, db ledger.DB, key string) (Transfer, error) {
	return scanOne(db.QueryRow(ctx, `select `+columns+` from transfers where idempotency_key = $1`, key))
}

func scanOne(row pgx.Row) (Transfer, error) {
	var t Transfer
	err := row.Scan(&t.ID, &t.IdempotencyKey, &t.WalletAccountID, &t.BankCode, &t.AccountNumber,
		&t.AccountName, &t.Narration, &t.Amount, &t.Fee, &t.Status, &t.SessionID, &t.FailureReason,
		&t.RequeryCount, &t.NextRequeryAt, &t.CreatedAt, &t.UpdatedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return Transfer{}, ErrNotFound
	}
	return t, err
}
