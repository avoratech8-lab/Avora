// Package bills pays for airtime, data, electricity and TV from a wallet.
//
// The amount moves from the wallet into in-flight before the provider is
// asked. On success it settles out of the pooled settlement account; on a
// decline it goes back to the wallet in full. If the provider gives no
// answer the payment stays pending, with the money held, for ops to check.
package bills

import (
	"context"
	"errors"
	"fmt"
	"regexp"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"avora/backend/internal/ledger"
	"avora/backend/internal/notify"
	"avora/backend/internal/wallets"
)

var (
	ErrInvalid             = errors.New("bills: invalid request")
	ErrNotFound            = errors.New("bills: not found")
	ErrIdempotencyConflict = errors.New("bills: idempotency key reused with different details")
)

type Status string

const (
	Pending  Status = "pending"
	Success  Status = "success"
	Refunded Status = "refunded"
)

type Payment struct {
	ID              string    `json:"id"`
	IdempotencyKey  string    `json:"-"`
	WalletAccountID int64     `json:"wallet_id"`
	BillerID        string    `json:"biller_id"`
	BillerName      string    `json:"biller_name"`
	Category        Category  `json:"category"`
	PlanCode        string    `json:"plan_code"`
	PlanName        string    `json:"plan_name"`
	Customer        string    `json:"customer"`
	CustomerName    string    `json:"customer_name"`
	Amount          int64     `json:"amount"`
	Status          Status    `json:"status"`
	Token           string    `json:"token,omitempty"`
	Reference       string    `json:"reference,omitempty"`
	FailureReason   string    `json:"failure_reason,omitempty"`
	CreatedAt       time.Time `json:"created_at"`
	UpdatedAt       time.Time `json:"updated_at"`
}

type Service struct {
	db       *pgxpool.Pool
	provider Provider
	sys      wallets.System
	billers  map[string]Biller
	order    []Biller
	now      func() time.Time
}

func NewService(db *pgxpool.Pool, p Provider, sys wallets.System) *Service {
	s := &Service{db: db, provider: p, sys: sys, billers: map[string]Biller{}, now: time.Now}
	for _, b := range p.Catalog() {
		s.billers[b.ID] = b
		s.order = append(s.order, b)
	}
	return s
}

func (s *Service) Billers() []Biller { return s.order }

var (
	phoneRe    = regexp.MustCompile(`^0[789][01]\d{8}$`)
	customerRe = regexp.MustCompile(`^\d{10,13}$`)
)

func (s *Service) biller(id string) (Biller, error) {
	b, ok := s.billers[id]
	if !ok {
		return Biller{}, fmt.Errorf("%w: unknown biller", ErrInvalid)
	}
	return b, nil
}

func checkCustomer(b Biller, customer string) error {
	if b.Category == Airtime || b.Category == Data {
		if !phoneRe.MatchString(customer) {
			return fmt.Errorf("%w: phone number must be 11 digits, like 08031234567", ErrInvalid)
		}
		return nil
	}
	if !customerRe.MatchString(customer) {
		return fmt.Errorf("%w: %s must be 10 to 13 digits", ErrInvalid, b.CustomerLabel)
	}
	return nil
}

// Validate returns the name on a meter or smartcard ("" for phones).
func (s *Service) Validate(ctx context.Context, billerID, customer string) (string, error) {
	b, err := s.biller(billerID)
	if err != nil {
		return "", err
	}
	if err := checkCustomer(b, customer); err != nil {
		return "", err
	}
	return s.provider.Validate(ctx, b, customer)
}

type PayRequest struct {
	IdempotencyKey  string
	WalletAccountID int64
	BillerID        string
	PlanCode        string
	Customer        string
	Amount          int64 // ignored for billers with plans
}

// Pay holds the money, asks the provider, and settles or refunds. Calling
// it again with the same idempotency key returns the same payment and moves
// no money.
func (s *Service) Pay(ctx context.Context, req PayRequest) (Payment, error) {
	if req.IdempotencyKey == "" {
		return Payment{}, fmt.Errorf("%w: idempotency key is required", ErrInvalid)
	}
	b, err := s.biller(req.BillerID)
	if err != nil {
		return Payment{}, err
	}
	var plan Plan
	if len(b.Plans) > 0 {
		p, ok := b.plan(req.PlanCode)
		if !ok {
			return Payment{}, fmt.Errorf("%w: choose a plan", ErrInvalid)
		}
		plan, req.Amount = p, p.Amount
	} else if req.Amount < b.MinAmount || req.Amount > b.MaxAmount {
		return Payment{}, fmt.Errorf("%w: amount must be between ₦%d and ₦%d", ErrInvalid, b.MinAmount/100, b.MaxAmount/100)
	}
	if err := checkCustomer(b, req.Customer); err != nil {
		return Payment{}, err
	}

	if p, err := s.byKey(ctx, s.db, req.IdempotencyKey); err == nil {
		return p, samePayment(p, req)
	} else if !errors.Is(err, ErrNotFound) {
		return Payment{}, err
	}

	name, err := s.provider.Validate(ctx, b, req.Customer)
	if err != nil {
		return Payment{}, err
	}

	p, created, err := s.hold(ctx, req, b, plan, name)
	if err != nil || !created {
		return p, err
	}

	res, err := s.provider.Pay(ctx, ProviderRequest{Reference: p.ID, Biller: b, PlanCode: plan.Code, Customer: req.Customer, Amount: p.Amount})
	if err != nil {
		// No answer: the money stays held and the payment pending for ops.
		return p, nil
	}
	switch res.Status {
	case ProviderSuccess:
		return s.finalize(ctx, p.ID, Success, res)
	case ProviderFailed:
		return s.finalize(ctx, p.ID, Refunded, res)
	default:
		return p, nil
	}
}

func samePayment(p Payment, req PayRequest) error {
	if p.WalletAccountID != req.WalletAccountID || p.BillerID != req.BillerID || p.Customer != req.Customer ||
		p.PlanCode != req.PlanCode || p.Amount != req.Amount {
		return ErrIdempotencyConflict
	}
	return nil
}

// Description is how a payment reads on the statement.
func Description(b Biller, plan, customer string) string {
	switch b.Category {
	case Airtime:
		return fmt.Sprintf("%s airtime · %s", b.Name, customer)
	case Data:
		return fmt.Sprintf("%s data %s · %s", b.Name, plan, customer)
	case Electricity:
		return fmt.Sprintf("%s · meter %s", b.Name, customer)
	default:
		return fmt.Sprintf("%s %s · %s", b.Name, plan, customer)
	}
}

func (s *Service) hold(ctx context.Context, req PayRequest, b Biller, plan Plan, name string) (Payment, bool, error) {
	tx, err := s.db.Begin(ctx)
	if err != nil {
		return Payment{}, false, err
	}
	defer tx.Rollback(ctx)

	now := s.now()
	var id string
	err = tx.QueryRow(ctx, `
		insert into bill_payments (idempotency_key, wallet_account_id, biller_id, biller_name, category,
			plan_code, plan_name, customer, customer_name, amount, status, created_at, updated_at)
		values ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, 'pending', $11, $11)
		on conflict (idempotency_key) do nothing
		returning id`,
		req.IdempotencyKey, req.WalletAccountID, b.ID, b.Name, b.Category, plan.Code, plan.Name,
		req.Customer, name, req.Amount, now).Scan(&id)
	if errors.Is(err, pgx.ErrNoRows) {
		// A concurrent request with the same key won the race.
		tx.Rollback(ctx)
		p, err := s.byKey(ctx, s.db, req.IdempotencyKey)
		if err != nil {
			return Payment{}, false, err
		}
		return p, false, samePayment(p, req)
	}
	if err != nil {
		return Payment{}, false, err
	}

	if _, err := ledger.Post(ctx, tx, ledger.Journal{
		IdempotencyKey: "bill:" + id + ":hold",
		Kind:           "bill_payment",
		Description:    Description(b, plan.Name, req.Customer),
		Ref:            id,
		Lines: []ledger.Line{
			ledger.Debit(req.WalletAccountID, req.Amount),
			ledger.Credit(s.sys.InFlight, req.Amount),
		},
	}); err != nil {
		return Payment{}, false, err
	}
	p, err := s.get(ctx, tx, id)
	if err != nil {
		return Payment{}, false, err
	}
	return p, true, tx.Commit(ctx)
}

// finalize posts the closing journal once and sets the final status.
func (s *Service) finalize(ctx context.Context, id string, to Status, res PayResult) (Payment, error) {
	tx, err := s.db.Begin(ctx)
	if err != nil {
		return Payment{}, err
	}
	defer tx.Rollback(ctx)

	p, err := scanOne(tx.QueryRow(ctx, `select `+columns+` from bill_payments where id = $1 for update`, id))
	if err != nil {
		return Payment{}, err
	}
	if p.Status != Pending {
		return p, nil
	}

	j := ledger.Journal{IdempotencyKey: "bill:" + id + ":" + string(to), Ref: id}
	b, _ := s.biller(p.BillerID)
	what := Description(b, p.PlanName, p.Customer)
	switch to {
	case Success:
		j.Kind, j.Description = "bill_settle", what
		j.Lines = []ledger.Line{ledger.Debit(s.sys.InFlight, p.Amount), ledger.Credit(s.sys.Settlement, p.Amount)}
	case Refunded:
		j.Kind, j.Description = "bill_refund", "Refund: "+what
		j.Lines = []ledger.Line{ledger.Debit(s.sys.InFlight, p.Amount), ledger.Credit(p.WalletAccountID, p.Amount)}
	default:
		return Payment{}, fmt.Errorf("bills: cannot finalize to %q", to)
	}
	if _, err := ledger.Post(ctx, tx, j); err != nil {
		return Payment{}, err
	}
	_, err = tx.Exec(ctx, `
		update bill_payments set status = $2, token = $3, reference = $4, failure_reason = $5, updated_at = $6
		where id = $1`, id, to, res.Token, res.Reference, res.Reason, s.now())
	if err != nil {
		return Payment{}, err
	}
	if to == Refunded {
		if err := notify.Add(ctx, tx, p.WalletAccountID, "bill", "Payment refunded",
			fmt.Sprintf("%s didn't go through. %s is back in your wallet.", what, notify.Naira(p.Amount)), id); err != nil {
			return Payment{}, err
		}
	}
	p, err = s.get(ctx, tx, id)
	if err != nil {
		return Payment{}, err
	}
	return p, tx.Commit(ctx)
}

func (s *Service) Get(ctx context.Context, id string) (Payment, error) { return s.get(ctx, s.db, id) }

const columns = `id, idempotency_key, wallet_account_id, biller_id, biller_name, category, plan_code, plan_name,
	customer, customer_name, amount, status, token, reference, failure_reason, created_at, updated_at`

var uuidRe = regexp.MustCompile(`^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$`)

func (s *Service) get(ctx context.Context, db ledger.DB, id string) (Payment, error) {
	if !uuidRe.MatchString(id) {
		return Payment{}, ErrNotFound
	}
	return scanOne(db.QueryRow(ctx, `select `+columns+` from bill_payments where id = $1`, id))
}

func (s *Service) byKey(ctx context.Context, db ledger.DB, key string) (Payment, error) {
	return scanOne(db.QueryRow(ctx, `select `+columns+` from bill_payments where idempotency_key = $1`, key))
}

func scanOne(row pgx.Row) (Payment, error) {
	var p Payment
	err := row.Scan(&p.ID, &p.IdempotencyKey, &p.WalletAccountID, &p.BillerID, &p.BillerName, &p.Category,
		&p.PlanCode, &p.PlanName, &p.Customer, &p.CustomerName, &p.Amount, &p.Status, &p.Token, &p.Reference,
		&p.FailureReason, &p.CreatedAt, &p.UpdatedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return Payment{}, ErrNotFound
	}
	return p, err
}

// SpentSince totals a wallet's bill payments since t, excluding refunds.
func (s *Service) SpentSince(ctx context.Context, walletID int64, t time.Time) (int64, error) {
	var total int64
	err := s.db.QueryRow(ctx, `
		select coalesce(sum(amount), 0) from bill_payments
		where wallet_account_id = $1 and created_at >= $2 and status <> 'refunded'`, walletID, t).Scan(&total)
	return total, err
}

// Price is what a payment will cost: the plan's price for billers with
// plans, otherwise the amount asked for.
func (s *Service) Price(billerID, planCode string, amount int64) int64 {
	if b, ok := s.billers[billerID]; ok && len(b.Plans) > 0 {
		if p, ok := b.plan(planCode); ok {
			return p.Amount
		}
	}
	return amount
}
