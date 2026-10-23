package transfers

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"avora/backend/internal/ledger"
	"avora/backend/internal/rails"
	"avora/backend/internal/testdb"
	"avora/backend/internal/wallets"
)

type fakeRail struct {
	mu     sync.Mutex
	send   func(rails.SendRequest) (rails.Result, error)
	status func(ref string) (rails.Result, error)
	sends  int
}

func (f *fakeRail) NameEnquiry(_ context.Context, _, acct string) (string, error) {
	return "ADA OBI", nil
}

func (f *fakeRail) Send(_ context.Context, r rails.SendRequest) (rails.Result, error) {
	f.mu.Lock()
	f.sends++
	f.mu.Unlock()
	return f.send(r)
}

func (f *fakeRail) Status(_ context.Context, ref string) (rails.Result, error) {
	return f.status(ref)
}

func succeed(r rails.SendRequest) (rails.Result, error) {
	return rails.Result{Status: rails.Success, SessionID: "S-" + r.Reference}, nil
}

type env struct {
	ctx    context.Context
	pool   *pgxpool.Pool
	sys    wallets.System
	svc    *Service
	rail   *fakeRail
	wallet int64
	clock  time.Time
}

func setup(t *testing.T, cfg Config, fund int64) *env {
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
	e := &env{ctx: ctx, pool: pool, sys: sys, wallet: w.AccountID,
		rail:  &fakeRail{send: succeed},
		clock: time.Date(2026, 10, 23, 9, 0, 0, 0, time.UTC)}
	e.svc = NewService(pool, e.rail, sys, cfg)
	e.svc.now = func() time.Time { return e.clock }

	tx, _ := pool.Begin(ctx)
	if _, err := ledger.Post(ctx, tx, ledger.Journal{IdempotencyKey: "fund", Kind: "test",
		Lines: []ledger.Line{ledger.Debit(sys.Settlement, fund), ledger.Credit(w.AccountID, fund)}}); err != nil {
		t.Fatal(err)
	}
	tx.Commit(ctx)
	return e
}

func (e *env) balance(t *testing.T, id int64) int64 {
	t.Helper()
	b, err := ledger.Balance(e.ctx, e.pool, id)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func (e *env) req(key string, amount int64) InitiateRequest {
	return InitiateRequest{IdempotencyKey: key, WalletAccountID: e.wallet, BankCode: "058",
		AccountNumber: "0123456789", Amount: amount, Narration: "rent"}
}

func noFree() Config {
	c := DefaultConfig()
	c.FreeTransfersPerMonth = 0
	return c
}

func (e *env) check(t *testing.T) {
	t.Helper()
	if err := ledger.Check(e.ctx, e.pool); err != nil {
		t.Error(err)
	}
	if b := e.balance(t, e.sys.InFlight); b < 0 {
		t.Errorf("in-flight went negative: %d", b)
	}
}

func TestDeliveredTransferSettlesAndKeepsFee(t *testing.T) {
	e := setup(t, noFree(), 10_000_00)
	tr, err := e.svc.Initiate(e.ctx, e.req("k1", 2_500_00))
	if err != nil {
		t.Fatal(err)
	}
	if tr.Status != Delivered || tr.Fee != 10_00 || tr.SessionID == "" || tr.AccountName != "ADA OBI" {
		t.Fatalf("transfer = %+v", tr)
	}
	if got := e.balance(t, e.wallet); got != 10_000_00-2_500_00-10_00 {
		t.Errorf("wallet = %d", got)
	}
	if got := e.balance(t, e.sys.InFlight); got != 0 {
		t.Errorf("in-flight = %d, want 0", got)
	}
	if got := e.balance(t, e.sys.FeeRevenue); got != 10_00 {
		t.Errorf("fee revenue = %d", got)
	}
	e.check(t)
}

func TestFreeAllowanceThenFee(t *testing.T) {
	cfg := DefaultConfig()
	cfg.FreeTransfersPerMonth = 2
	e := setup(t, cfg, 10_000_00)
	if q, _ := e.svc.Quote(e.ctx, e.wallet, 100_00); q.Fee != 0 || q.FreeTransfersLeft != 2 {
		t.Errorf("first quote = %+v", q)
	}
	var fees []int64
	for _, k := range []string{"a", "b", "c"} {
		tr, err := e.svc.Initiate(e.ctx, e.req(k, 100_00))
		if err != nil {
			t.Fatal(err)
		}
		fees = append(fees, tr.Fee)
	}
	if fees[0] != 0 || fees[1] != 0 || fees[2] != 10_00 {
		t.Errorf("fees = %v, want [0 0 1000]", fees)
	}
	q, err := e.svc.Quote(e.ctx, e.wallet, 100_00)
	if err != nil || q.Fee != 10_00 || q.Total != 110_00 || q.FreeTransfersLeft != 0 {
		t.Errorf("quote after allowance = %+v %v", q, err)
	}
}

func TestDeclinedTransferIsRefundedInFull(t *testing.T) {
	e := setup(t, noFree(), 5_000_00)
	e.rail.send = func(r rails.SendRequest) (rails.Result, error) {
		return rails.Result{Status: rails.Failed, Reason: "beneficiary bank declined"}, nil
	}
	tr, err := e.svc.Initiate(e.ctx, e.req("k1", 1_000_00))
	if err != nil {
		t.Fatal(err)
	}
	if tr.Status != Refunded || tr.FailureReason == "" {
		t.Fatalf("transfer = %+v", tr)
	}
	if got := e.balance(t, e.wallet); got != 5_000_00 {
		t.Errorf("wallet = %d, want full refund including fee", got)
	}
	e.check(t)
}

func TestTimeoutIsRequeriedNotResent(t *testing.T) {
	e := setup(t, noFree(), 5_000_00)
	e.rail.send = func(rails.SendRequest) (rails.Result, error) {
		return rails.Result{}, errors.New("i/o timeout")
	}
	pending := true
	e.rail.status = func(ref string) (rails.Result, error) {
		if pending {
			return rails.Result{Status: rails.Pending}, nil
		}
		return rails.Result{Status: rails.Success, SessionID: "S-late"}, nil
	}

	tr, err := e.svc.Initiate(e.ctx, e.req("k1", 1_000_00))
	if err != nil {
		t.Fatal(err)
	}
	if tr.Status != Sent {
		t.Fatalf("status = %s, want sent", tr.Status)
	}

	// Not due yet: nothing happens.
	if n, _ := e.svc.RequeryDue(e.ctx, 10); n != 0 {
		t.Errorf("requeried %d before due", n)
	}
	e.clock = e.clock.Add(3 * time.Minute)
	if n, _ := e.svc.RequeryDue(e.ctx, 10); n != 1 {
		t.Errorf("requeried %d, want 1", n)
	}
	pending = false
	e.clock = e.clock.Add(10 * time.Minute)
	e.svc.RequeryDue(e.ctx, 10)

	tr, _ = e.svc.Get(e.ctx, tr.ID)
	if tr.Status != Delivered || tr.SessionID != "S-late" {
		t.Errorf("transfer = %+v, want delivered", tr)
	}
	if e.rail.sends != 1 {
		t.Errorf("sent %d times, want exactly 1", e.rail.sends)
	}
	e.check(t)
}

func TestRequeryFailureRefunds(t *testing.T) {
	e := setup(t, noFree(), 5_000_00)
	e.rail.send = func(rails.SendRequest) (rails.Result, error) { return rails.Result{Status: rails.Pending}, nil }
	e.rail.status = func(string) (rails.Result, error) {
		return rails.Result{Status: rails.Failed, Reason: "account dormant"}, nil
	}
	tr, _ := e.svc.Initiate(e.ctx, e.req("k1", 1_000_00))
	e.clock = e.clock.Add(time.Hour)
	e.svc.RequeryDue(e.ctx, 10)
	tr, _ = e.svc.Get(e.ctx, tr.ID)
	if tr.Status != Refunded {
		t.Fatalf("status = %s, want refunded", tr.Status)
	}
	if got := e.balance(t, e.wallet); got != 5_000_00 {
		t.Errorf("wallet = %d", got)
	}
	e.check(t)
}

func TestHeldButNeverSentIsRefunded(t *testing.T) {
	e := setup(t, noFree(), 5_000_00)
	// Simulate a crash between holding funds and calling the bank.
	tr, created, err := e.svc.hold(e.ctx, e.req("k1", 1_000_00), "ADA OBI")
	if err != nil || !created {
		t.Fatal(err)
	}
	e.rail.status = func(string) (rails.Result, error) { return rails.Result{Status: rails.NotFound}, nil }
	e.clock = e.clock.Add(2 * time.Minute)
	e.svc.RequeryDue(e.ctx, 10)
	tr, _ = e.svc.Get(e.ctx, tr.ID)
	if tr.Status != Refunded {
		t.Fatalf("status = %s, want refunded", tr.Status)
	}
	if got := e.balance(t, e.wallet); got != 5_000_00 {
		t.Errorf("wallet = %d", got)
	}
}

func TestStuckTransferGoesToReviewThenOpsResolve(t *testing.T) {
	e := setup(t, noFree(), 5_000_00)
	e.rail.send = func(rails.SendRequest) (rails.Result, error) { return rails.Result{Status: rails.Pending}, nil }
	e.rail.status = func(string) (rails.Result, error) { return rails.Result{Status: rails.Pending}, nil }
	tr, _ := e.svc.Initiate(e.ctx, e.req("k1", 1_000_00))

	e.clock = e.clock.Add(7 * time.Hour)
	e.svc.RequeryDue(e.ctx, 10)
	tr, _ = e.svc.Get(e.ctx, tr.ID)
	if tr.Status != NeedsReview {
		t.Fatalf("status = %s, want needs_review", tr.Status)
	}
	// Money stays held while ops investigate.
	if got := e.balance(t, e.sys.InFlight); got != 1_000_00+10_00 {
		t.Errorf("in-flight = %d", got)
	}

	tr, err := e.svc.Resolve(e.ctx, tr.ID, Refunded, "", "bank confirmed not received")
	if err != nil || tr.Status != Refunded {
		t.Fatalf("resolve: %+v %v", tr, err)
	}
	if _, err := e.svc.Resolve(e.ctx, tr.ID, Delivered, "", ""); !errors.Is(err, ErrNotResolvable) {
		t.Errorf("second resolve err = %v, want ErrNotResolvable", err)
	}
	if got := e.balance(t, e.wallet); got != 5_000_00 {
		t.Errorf("wallet = %d", got)
	}
	e.check(t)
}

func TestFinalizeIsIdempotent(t *testing.T) {
	e := setup(t, noFree(), 5_000_00)
	tr, _ := e.svc.Initiate(e.ctx, e.req("k1", 1_000_00))
	// A late "failed" answer must not refund a delivered transfer.
	again, err := e.svc.finalize(e.ctx, tr.ID, Refunded, "", "late failure")
	if err != nil || again.Status != Delivered {
		t.Fatalf("finalize after delivery: %+v %v", again, err)
	}
	if got := e.balance(t, e.wallet); got != 5_000_00-1_000_00-10_00 {
		t.Errorf("wallet = %d", got)
	}
	e.check(t)
}

func TestIdempotentInitiate(t *testing.T) {
	e := setup(t, noFree(), 5_000_00)
	first, err := e.svc.Initiate(e.ctx, e.req("k1", 1_000_00))
	if err != nil {
		t.Fatal(err)
	}
	second, err := e.svc.Initiate(e.ctx, e.req("k1", 1_000_00))
	if err != nil || second.ID != first.ID {
		t.Fatalf("replay = %+v %v", second, err)
	}
	if e.rail.sends != 1 {
		t.Errorf("sent %d times", e.rail.sends)
	}
	if _, err := e.svc.Initiate(e.ctx, e.req("k1", 2_000_00)); !errors.Is(err, ErrIdempotencyConflict) {
		t.Errorf("err = %v, want ErrIdempotencyConflict", err)
	}
	if got := e.balance(t, e.wallet); got != 5_000_00-1_000_00-10_00 {
		t.Errorf("wallet = %d", got)
	}
}

func TestConcurrentDuplicateRequestsSendOnce(t *testing.T) {
	e := setup(t, noFree(), 5_000_00)
	var wg sync.WaitGroup
	for range 10 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if _, err := e.svc.Initiate(e.ctx, e.req("same", 1_000_00)); err != nil {
				t.Error(err)
			}
		}()
	}
	wg.Wait()
	if e.rail.sends != 1 {
		t.Errorf("sent %d times, want 1", e.rail.sends)
	}
	e.check(t)
}

func TestInsufficientFundsStoresNothing(t *testing.T) {
	e := setup(t, noFree(), 1_000_00)
	_, err := e.svc.Initiate(e.ctx, e.req("k1", 1_000_00)) // plus ₦10 fee
	if !errors.Is(err, ledger.ErrInsufficientFunds) {
		t.Fatalf("err = %v", err)
	}
	var n int
	e.pool.QueryRow(e.ctx, `select count(*) from transfers`).Scan(&n)
	if n != 0 || e.rail.sends != 0 {
		t.Errorf("transfers = %d, sends = %d; want none", n, e.rail.sends)
	}
}

func TestValidation(t *testing.T) {
	e := setup(t, noFree(), 1_000_00)
	bad := []InitiateRequest{
		{WalletAccountID: e.wallet, BankCode: "058", AccountNumber: "0123456789", Amount: 100},
		{IdempotencyKey: "k", WalletAccountID: e.wallet, BankCode: "058", AccountNumber: "0123456789", Amount: 0},
		{IdempotencyKey: "k", WalletAccountID: e.wallet, BankCode: "058", AccountNumber: "12345", Amount: 100},
		{IdempotencyKey: "k", WalletAccountID: e.wallet, AccountNumber: "0123456789", Amount: 100},
	}
	for _, r := range bad {
		if _, err := e.svc.Initiate(e.ctx, r); !errors.Is(err, ErrInvalid) {
			t.Errorf("%+v: err = %v, want ErrInvalid", r, err)
		}
	}
}
