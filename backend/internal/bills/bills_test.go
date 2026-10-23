package bills

import (
	"context"
	"errors"
	"sync"
	"testing"

	"github.com/jackc/pgx/v5/pgxpool"

	"avora/backend/internal/ledger"
	"avora/backend/internal/testdb"
	"avora/backend/internal/wallets"
)

type env struct {
	ctx    context.Context
	pool   *pgxpool.Pool
	sys    wallets.System
	svc    *Service
	wallet int64
}

func setup(t *testing.T, p Provider, fund int64) *env {
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
	return &env{ctx: ctx, pool: pool, sys: sys, svc: NewService(pool, p, sys), wallet: w.AccountID}
}

func (e *env) balance(t *testing.T, acct int64) int64 {
	t.Helper()
	b, err := ledger.Balance(e.ctx, e.pool, acct)
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

func TestAirtimeSucceeds(t *testing.T) {
	e := setup(t, Sandbox{}, 10_000_00)
	p, err := e.svc.Pay(e.ctx, PayRequest{IdempotencyKey: "k1", WalletAccountID: e.wallet,
		BillerID: "mtn-airtime", Customer: "08031234567", Amount: 500_00})
	if err != nil {
		t.Fatal(err)
	}
	if p.Status != Success || p.Reference == "" || p.Amount != 500_00 {
		t.Fatalf("got %+v", p)
	}
	if got := e.balance(t, e.wallet); got != 9_500_00 {
		t.Fatalf("wallet = %d", got)
	}
	if got := e.balance(t, e.sys.InFlight); got != 0 {
		t.Fatalf("in flight = %d", got)
	}
	lines, err := ledger.Statement(e.ctx, e.pool, e.wallet, 10)
	if err != nil {
		t.Fatal(err)
	}
	if lines[0].Kind != "bill_payment" || lines[0].Description != "MTN airtime · 08031234567" || lines[0].Ref != p.ID {
		t.Fatalf("statement line = %+v", lines[0])
	}
	e.check(t)
}

func TestPlansSetThePriceAndElectricityGetsAToken(t *testing.T) {
	e := setup(t, Sandbox{}, 50_000_00)
	p, err := e.svc.Pay(e.ctx, PayRequest{IdempotencyKey: "tv", WalletAccountID: e.wallet,
		BillerID: "dstv", PlanCode: "dstv-compact", Customer: "1234567891", Amount: 1})
	if err != nil {
		t.Fatal(err)
	}
	if p.Amount != 19_000_00 || p.PlanName != "Compact" || p.CustomerName != "SANDBOX CUSTOMER 7891" {
		t.Fatalf("tv = %+v", p)
	}

	p, err = e.svc.Pay(e.ctx, PayRequest{IdempotencyKey: "light", WalletAccountID: e.wallet,
		BillerID: "ikedc", Customer: "45123456781", Amount: 5_000_00})
	if err != nil {
		t.Fatal(err)
	}
	if p.Status != Success || len(p.Token) != 24 {
		t.Fatalf("electricity = %+v", p)
	}
	if got := e.balance(t, e.wallet); got != 26_000_00 {
		t.Fatalf("wallet = %d", got)
	}
	e.check(t)
}

func TestDeclineRefundsInFull(t *testing.T) {
	e := setup(t, Sandbox{}, 10_000_00)
	p, err := e.svc.Pay(e.ctx, PayRequest{IdempotencyKey: "k", WalletAccountID: e.wallet,
		BillerID: "glo-data", PlanCode: "glo-2gb-7d", Customer: "08051234560"})
	if err != nil {
		t.Fatal(err)
	}
	if p.Status != Refunded || p.FailureReason == "" {
		t.Fatalf("got %+v", p)
	}
	if got := e.balance(t, e.wallet); got != 10_000_00 {
		t.Fatalf("wallet = %d", got)
	}
	e.check(t)
}

func TestSameKeyPaysOnce(t *testing.T) {
	e := setup(t, Sandbox{}, 10_000_00)
	req := PayRequest{IdempotencyKey: "same", WalletAccountID: e.wallet, BillerID: "airtel-airtime",
		Customer: "08021234567", Amount: 1_000_00}
	var wg sync.WaitGroup
	ids := make([]string, 5)
	for i := range ids {
		wg.Add(1)
		go func() {
			defer wg.Done()
			p, err := e.svc.Pay(e.ctx, req)
			if err != nil {
				t.Error(err)
			}
			ids[i] = p.ID
		}()
	}
	wg.Wait()
	for _, id := range ids {
		if id != ids[0] {
			t.Fatalf("ids differ: %v", ids)
		}
	}
	if got := e.balance(t, e.wallet); got != 9_000_00 {
		t.Fatalf("wallet = %d", got)
	}
	req.Amount = 2_000_00
	if _, err := e.svc.Pay(e.ctx, req); !errors.Is(err, ErrIdempotencyConflict) {
		t.Fatalf("err = %v", err)
	}
	e.check(t)
}

type silentProvider struct{ Sandbox }

func (silentProvider) Pay(context.Context, ProviderRequest) (PayResult, error) {
	return PayResult{}, errors.New("timeout")
}

func TestNoAnswerKeepsMoneyHeld(t *testing.T) {
	e := setup(t, silentProvider{}, 10_000_00)
	p, err := e.svc.Pay(e.ctx, PayRequest{IdempotencyKey: "k", WalletAccountID: e.wallet,
		BillerID: "mtn-airtime", Customer: "08031234567", Amount: 1_000_00})
	if err != nil {
		t.Fatal(err)
	}
	if p.Status != Pending {
		t.Fatalf("status = %s", p.Status)
	}
	if got := e.balance(t, e.sys.InFlight); got != 1_000_00 {
		t.Fatalf("in flight = %d", got)
	}
	e.check(t)
}

func TestRefusals(t *testing.T) {
	e := setup(t, Sandbox{}, 1_000_00)
	cases := []struct {
		name string
		req  PayRequest
		want error
	}{
		{"unknown biller", PayRequest{BillerID: "nope", Customer: "08031234567", Amount: 100_00}, ErrInvalid},
		{"bad phone", PayRequest{BillerID: "mtn-airtime", Customer: "12345", Amount: 100_00}, ErrInvalid},
		{"below minimum", PayRequest{BillerID: "mtn-airtime", Customer: "08031234567", Amount: 10_00}, ErrInvalid},
		{"no plan", PayRequest{BillerID: "gotv", Customer: "1234567891"}, ErrInvalid},
		{"meter not found", PayRequest{BillerID: "ikedc", Customer: "45123456788", Amount: 1_000_00}, ErrCustomerNotFound},
		{"too little money", PayRequest{BillerID: "mtn-airtime", Customer: "08031234567", Amount: 2_000_00}, ledger.ErrInsufficientFunds},
	}
	for i, c := range cases {
		c.req.IdempotencyKey = c.name
		c.req.WalletAccountID = e.wallet
		if _, err := e.svc.Pay(e.ctx, c.req); !errors.Is(err, c.want) {
			t.Errorf("%d %s: err = %v, want %v", i, c.name, err, c.want)
		}
	}
	if got := e.balance(t, e.wallet); got != 1_000_00 {
		t.Fatalf("wallet = %d", got)
	}
	var n int
	e.pool.QueryRow(e.ctx, `select count(*) from bill_payments`).Scan(&n)
	if n != 0 {
		t.Fatalf("%d payments recorded for refused requests", n)
	}
}
