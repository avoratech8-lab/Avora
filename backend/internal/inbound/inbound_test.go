package inbound_test

import (
	"context"
	"testing"

	"avora/backend/internal/inbound"
	"avora/backend/internal/ledger"
	"avora/backend/internal/testdb"
	"avora/backend/internal/wallets"
)

func TestCreditsWalletOnceAndChargesEMTL(t *testing.T) {
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

	small := inbound.Credit{SessionID: "S1", NUBAN: w.NUBAN, Amount: 9_999_99, SenderName: "TUNDE", SenderBank: "GTBank"}
	big := inbound.Credit{SessionID: "S2", NUBAN: w.NUBAN, Amount: 10_000_00, SenderName: "TUNDE"}

	r, err := inbound.Apply(ctx, pool, sys, small)
	if err != nil || r.Levy != 0 {
		t.Fatalf("small credit: %+v %v", r, err)
	}
	r, err = inbound.Apply(ctx, pool, sys, big)
	if err != nil || r.Levy != inbound.EMTLAmount {
		t.Fatalf("big credit: %+v %v", r, err)
	}
	r, err = inbound.Apply(ctx, pool, sys, big)
	if err != nil || !r.Duplicate {
		t.Fatalf("duplicate: %+v %v", r, err)
	}

	got, _ := ledger.Balance(ctx, pool, w.AccountID)
	if want := int64(9_999_99 + 10_000_00 - 50_00); got != want {
		t.Errorf("wallet = %d, want %d", got, want)
	}
	levy, _ := ledger.Balance(ctx, pool, sys.EMTLPayable)
	if levy != 50_00 {
		t.Errorf("EMTL payable = %d, want 5000", levy)
	}
	if err := ledger.Check(ctx, pool); err != nil {
		t.Error(err)
	}
}

func TestUnknownAccountAndBadInput(t *testing.T) {
	ctx := context.Background()
	pool := testdb.New(t)
	sys, _ := wallets.LoadSystem(ctx, pool)
	if _, err := inbound.Apply(ctx, pool, sys, inbound.Credit{SessionID: "S", NUBAN: "9999999999", Amount: 100}); err == nil {
		t.Error("credit to unknown account succeeded")
	}
	if _, err := inbound.Apply(ctx, pool, sys, inbound.Credit{NUBAN: "9999999999", Amount: 100}); err == nil {
		t.Error("credit without session id succeeded")
	}
}
