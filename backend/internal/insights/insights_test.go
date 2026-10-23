package insights

import (
	"context"
	"testing"
	"time"

	"avora/backend/internal/ledger"
	"avora/backend/internal/testdb"
	"avora/backend/internal/wallets"
)

func TestMonthCountsEachJournalByItsNetEffect(t *testing.T) {
	ctx := context.Background()
	pool := testdb.New(t)
	sys, err := wallets.LoadSystem(ctx, pool)
	if err != nil {
		t.Fatal(err)
	}
	ada, _ := wallets.Create(ctx, pool, "ada", "9000000001")
	bola, _ := wallets.Create(ctx, pool, "bola", "9000000002")
	n := 0
	post := func(kind string, from, to, amount int64) {
		t.Helper()
		n++
		tx, _ := pool.Begin(ctx)
		if _, err := ledger.Post(ctx, tx, ledger.Journal{IdempotencyKey: string(rune('a' + n)), Kind: kind,
			Lines: []ledger.Line{ledger.Debit(from, amount), ledger.Credit(to, amount)}}); err != nil {
			t.Fatal(err)
		}
		tx.Commit(ctx)
	}
	post("inbound_credit", sys.Settlement, ada.AccountID, 50_000_00)
	post("transfer_hold", ada.AccountID, sys.InFlight, 10_000_00)
	post("transfer_hold", ada.AccountID, sys.InFlight, 3_000_00)
	post("transfer_refund", sys.InFlight, ada.AccountID, 3_000_00) // the second one bounced
	post("p2p", ada.AccountID, bola.AccountID, 2_500_00)
	post("p2p", bola.AccountID, ada.AccountID, 700_00)
	post("savings_deposit", ada.AccountID, sys.InFlight, 5_000_00) // any account stands in for the pot

	s := NewService(pool)
	start, _ := s.ParseMonth("")
	m, err := s.Month(ctx, ada.AccountID, start)
	if err != nil {
		t.Fatal(err)
	}
	if m.MoneyIn != 50_700_00 || m.MoneyOut != 12_500_00 || m.Saved != 5_000_00 {
		t.Fatalf("in %d, out %d, saved %d", m.MoneyIn, m.MoneyOut, m.Saved)
	}
	if len(m.Categories) != 2 || m.Categories[0] != (Category{Category: "transfers", Amount: 10_000_00, Count: 2}) ||
		m.Categories[1] != (Category{Category: "avora", Amount: 2_500_00, Count: 1}) {
		t.Fatalf("categories = %+v", m.Categories)
	}
	if today := time.Now().In(Lagos).Day(); m.Days[today-1] != 12_500_00 {
		t.Fatalf("days = %v", m.Days)
	}
	if prev, _ := s.Month(ctx, ada.AccountID, start.AddDate(0, -1, 0)); prev.MoneyOut != 0 || len(prev.Days) < 28 {
		t.Fatalf("last month = %+v", prev)
	}
}
