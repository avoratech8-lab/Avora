package savings

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"avora/backend/internal/ledger"
	"avora/backend/internal/testdb"
	"avora/backend/internal/wallets"
)

type env struct {
	ctx    context.Context
	pool   *pgxpool.Pool
	svc    *Service
	wallet int64
	clock  time.Time
}

func setup(t *testing.T, fund int64) *env {
	t.Helper()
	ctx := context.Background()
	pool := testdb.New(t)
	sys, err := wallets.LoadSystem(ctx, pool)
	if err != nil {
		t.Fatal(err)
	}
	w, err := wallets.Create(ctx, pool, "user-1", "9000000001")
	if err != nil {
		t.Fatal(err)
	}
	tx, _ := pool.Begin(ctx)
	if _, err := ledger.Post(ctx, tx, ledger.Journal{IdempotencyKey: "fund", Kind: "test",
		Lines: []ledger.Line{ledger.Debit(sys.Settlement, fund), ledger.Credit(w.AccountID, fund)}}); err != nil {
		t.Fatal(err)
	}
	tx.Commit(ctx)
	svc, err := NewService(ctx, pool, DefaultRates())
	if err != nil {
		t.Fatal(err)
	}
	e := &env{ctx: ctx, pool: pool, svc: svc, wallet: w.AccountID, clock: time.Date(2026, 10, 1, 9, 0, 0, 0, time.UTC)}
	svc.now = func() time.Time { return e.clock }
	return e
}

func (e *env) walletBalance(t *testing.T) int64 {
	t.Helper()
	b, err := ledger.Balance(e.ctx, e.pool, e.wallet)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func (e *env) check(t *testing.T) {
	t.Helper()
	if err := ledger.Check(e.ctx, e.pool); err != nil {
		t.Fatal(err)
	}
}

func TestGoalPotInAndOut(t *testing.T) {
	e := setup(t, 100_000_00)
	p, err := e.svc.Create(e.ctx, CreateRequest{IdempotencyKey: "c1", WalletAccountID: e.wallet, Kind: Goal,
		Name: "New phone", Target: 300_000_00, Amount: 20_000_00})
	if err != nil {
		t.Fatal(err)
	}
	if p.Balance != 20_000_00 || p.ExpectedRateBps != 800 || p.Status != "open" {
		t.Fatalf("pot = %+v", p)
	}
	again, err := e.svc.Create(e.ctx, CreateRequest{IdempotencyKey: "c1", WalletAccountID: e.wallet, Kind: Goal,
		Name: "New phone", Target: 300_000_00, Amount: 20_000_00})
	if err != nil || again.ID != p.ID {
		t.Fatalf("replayed create: %v %+v", err, again)
	}

	if p, err = e.svc.Deposit(e.ctx, e.wallet, p.ID, "d1", 5_000_00); err != nil || p.Balance != 25_000_00 {
		t.Fatalf("deposit: %v %+v", err, p)
	}
	if p, err = e.svc.Deposit(e.ctx, e.wallet, p.ID, "d1", 5_000_00); err != nil || p.Balance != 25_000_00 {
		t.Fatalf("replayed deposit: %v %+v", err, p)
	}
	if p, err = e.svc.Withdraw(e.ctx, e.wallet, p.ID, "w1", 10_000_00, false); err != nil || p.Balance != 15_000_00 {
		t.Fatalf("withdraw: %v %+v", err, p)
	}
	if _, err = e.svc.Withdraw(e.ctx, e.wallet, p.ID, "w2", 99_000_00, false); !errors.Is(err, ledger.ErrInsufficientFunds) {
		t.Fatalf("over-withdraw: %v", err)
	}
	if got := e.walletBalance(t); got != 85_000_00 {
		t.Fatalf("wallet = %d", got)
	}
	if _, err := e.svc.Deposit(e.ctx, e.wallet, p.ID, "d2", 1_000_000_00); !errors.Is(err, ledger.ErrInsufficientFunds) {
		t.Fatalf("overspend: %v", err)
	}

	lines, _ := ledger.Statement(e.ctx, e.pool, e.wallet, 10)
	if lines[0].Kind != "savings_withdraw" || lines[0].Description != "From New phone" || lines[0].Amount != 10_000_00 {
		t.Fatalf("statement = %+v", lines[0])
	}
	e.check(t)
}

func TestLockedPlan(t *testing.T) {
	e := setup(t, 100_000_00)
	if _, err := e.svc.Create(e.ctx, CreateRequest{IdempotencyKey: "x", WalletAccountID: e.wallet, Kind: Locked,
		Name: "Rent", LockDays: 45, Amount: 50_000_00}); !errors.Is(err, ErrInvalid) {
		t.Fatalf("odd term: %v", err)
	}
	p, err := e.svc.Create(e.ctx, CreateRequest{IdempotencyKey: "l1", WalletAccountID: e.wallet, Kind: Locked,
		Name: "Rent", LockDays: 90, Amount: 60_000_00})
	if err != nil {
		t.Fatal(err)
	}
	if p.ExpectedRateBps != 1200 || p.MaturesAt == nil || !p.MaturesAt.Equal(e.clock.AddDate(0, 0, 90)) {
		t.Fatalf("pot = %+v", p)
	}
	if _, err := e.svc.Deposit(e.ctx, e.wallet, p.ID, "d", 1_000_00); !errors.Is(err, ErrLocked) {
		t.Fatalf("top up locked: %v", err)
	}
	if _, err := e.svc.Withdraw(e.ctx, e.wallet, p.ID, "w", 0, false); !errors.Is(err, ErrLocked) {
		t.Fatalf("early withdraw: %v", err)
	}

	// October's profit at 12% a year: 60,000 × 12% ÷ 12 = 600.
	run, err := e.svc.DistributeProfit(e.ctx, "2026-10", 800, 1200)
	if err != nil || run.Pots != 1 || run.Total != 600_00 {
		t.Fatalf("profit: %v %+v", err, run)
	}
	if _, err := e.svc.DistributeProfit(e.ctx, "2026-10", 800, 1200); !errors.Is(err, ErrDeclared) {
		t.Fatalf("second run: %v", err)
	}
	p, _ = e.svc.Get(e.ctx, e.wallet, p.ID)
	if p.Balance != 60_600_00 || p.ProfitEarned != 600_00 {
		t.Fatalf("after profit = %+v", p)
	}

	// At maturity the whole balance, profit included, comes back.
	e.clock = e.clock.AddDate(0, 0, 90)
	p, err = e.svc.Withdraw(e.ctx, e.wallet, p.ID, "w", 0, false)
	if err != nil || p.Status != "closed" || p.Balance != 0 {
		t.Fatalf("maturity: %v %+v", err, p)
	}
	if got := e.walletBalance(t); got != 100_600_00 {
		t.Fatalf("wallet = %d", got)
	}
	if _, err := e.svc.Withdraw(e.ctx, e.wallet, p.ID, "w2", 0, false); !errors.Is(err, ErrClosed) {
		t.Fatalf("closed: %v", err)
	}
	e.check(t)
}

func TestBreakingEarlyGivesBackProfit(t *testing.T) {
	e := setup(t, 100_000_00)
	p, err := e.svc.Create(e.ctx, CreateRequest{IdempotencyKey: "l1", WalletAccountID: e.wallet, Kind: Locked,
		Name: "School fees", LockDays: 365, Amount: 30_000_00})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := e.svc.DistributeProfit(e.ctx, "2026-10", 800, 1600); err != nil {
		t.Fatal(err)
	}
	p, err = e.svc.Withdraw(e.ctx, e.wallet, p.ID, "b", 0, true)
	if err != nil || p.Status != "closed" || p.ProfitEarned != 0 {
		t.Fatalf("break: %v %+v", err, p)
	}
	if got := e.walletBalance(t); got != 100_000_00 {
		t.Fatalf("wallet = %d, want the 30,000 back without profit", got)
	}
	e.check(t)
}

func TestOtherWalletsCantTouchPot(t *testing.T) {
	e := setup(t, 10_000_00)
	p, err := e.svc.Create(e.ctx, CreateRequest{IdempotencyKey: "c", WalletAccountID: e.wallet, Kind: Goal, Name: "Mine"})
	if err != nil {
		t.Fatal(err)
	}
	other, _ := wallets.Create(e.ctx, e.pool, "user-2", "9000000002")
	if _, err := e.svc.Get(e.ctx, other.AccountID, p.ID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("get: %v", err)
	}
	if _, err := e.svc.Withdraw(e.ctx, other.AccountID, p.ID, "w", 1, false); !errors.Is(err, ErrNotFound) {
		t.Fatalf("withdraw: %v", err)
	}
	list, _ := e.svc.List(e.ctx, other.AccountID)
	if len(list) != 0 {
		t.Fatalf("list = %+v", list)
	}
}
