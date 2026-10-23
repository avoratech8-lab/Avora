package cards

import (
	"context"
	"errors"
	"strconv"
	"testing"

	"avora/backend/internal/ledger"
	"avora/backend/internal/testdb"
	"avora/backend/internal/wallets"
)

func TestCardsFreezeLimitAndCharge(t *testing.T) {
	ctx := context.Background()
	pool := testdb.New(t)
	sys, err := wallets.LoadSystem(ctx, pool)
	if err != nil {
		t.Fatal(err)
	}
	w, _ := wallets.Create(ctx, pool, "ada", "9000000001")
	other, _ := wallets.Create(ctx, pool, "bola", "9000000002")
	tx, _ := pool.Begin(ctx)
	ledger.Post(ctx, tx, ledger.Journal{IdempotencyKey: "fund", Kind: "t",
		Lines: []ledger.Line{ledger.Debit(sys.Settlement, 10_000_00), ledger.Credit(w.AccountID, 10_000_00)}})
	tx.Commit(ctx)
	s := NewService(pool, sys, []byte("secret"))

	c, err := s.Create(ctx, w.AccountID, "  Netflix  ")
	if err != nil || c.Name != "Netflix" || c.Status != Active || len(c.Last4) != 4 || len(c.Expiry) != 5 {
		t.Fatalf("create = %+v, %v", c, err)
	}
	d, _ := s.Details(ctx, w.AccountID, c.ID, "Ada Obi")
	if len(d.Number) != 16 || d.Number[12:] != c.Last4 || len(d.CVV) != 3 || d.Name != "ADA OBI" || !luhnOK(d.Number) {
		t.Fatalf("details = %+v", d)
	}
	if _, err := s.Get(ctx, other.AccountID, c.ID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("other wallet sees the card: %v", err)
	}

	charge := func(key string, amount int64) Payment {
		t.Helper()
		p, err := s.Charge(ctx, c.ID, key, "Netflix", amount)
		if err != nil {
			t.Fatal(err)
		}
		return p
	}
	if p := charge("1", 4_400_00); p.Status != "approved" {
		t.Fatalf("first = %+v", p)
	}
	if p := charge("1", 4_400_00); p.Status != "approved" { // a retry moves nothing
		t.Fatalf("retry = %+v", p)
	}
	s.SetFrozen(ctx, w.AccountID, c.ID, true)
	if p := charge("2", 100_00); p.DeclineReason != "card frozen" {
		t.Fatalf("frozen = %+v", p)
	}
	s.SetFrozen(ctx, w.AccountID, c.ID, false)
	s.SetLimit(ctx, w.AccountID, c.ID, 5_000_00)
	if p := charge("3", 1_000_00); p.DeclineReason != "over monthly limit" {
		t.Fatalf("limit = %+v", p)
	}
	s.SetLimit(ctx, w.AccountID, c.ID, 0)
	if p := charge("4", 7_000_00); p.DeclineReason != "insufficient funds" {
		t.Fatalf("short = %+v", p)
	}
	if b, _ := ledger.Balance(ctx, pool, w.AccountID); b != 5_600_00 {
		t.Fatalf("wallet = %d", b)
	}
	got, _ := s.Get(ctx, w.AccountID, c.ID)
	if got.SpentMonth != 4_400_00 {
		t.Fatalf("spent = %d", got.SpentMonth)
	}
	pays, _ := s.Payments(ctx, w.AccountID, c.ID)
	if len(pays) != 4 {
		t.Fatalf("payments = %d", len(pays))
	}

	for i := range MaxCards - 1 {
		if _, err := s.Create(ctx, w.AccountID, "Card "+strconv.Itoa(i)); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := s.Create(ctx, w.AccountID, ""); !errors.Is(err, ErrTooMany) {
		t.Fatalf("fourth card: %v", err)
	}
	if err := s.Terminate(ctx, w.AccountID, c.ID); err != nil {
		t.Fatal(err)
	}
	if p := charge("5", 100_00); p.DeclineReason != "card terminated" {
		t.Fatalf("terminated = %+v", p)
	}
	if list, _ := s.List(ctx, w.AccountID); len(list) != MaxCards-1 {
		t.Fatalf("list = %d", len(list))
	}
	if err := ledger.Check(ctx, pool); err != nil {
		t.Fatal(err)
	}
}

func luhnOK(n string) bool { return luhn(n[:15]) == n[15:] }
