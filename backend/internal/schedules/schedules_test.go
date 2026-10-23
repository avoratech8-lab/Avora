package schedules

import (
	"context"
	"testing"
	"time"

	"avora/backend/internal/testdb"
	"avora/backend/internal/wallets"
)

func TestOccurrenceKeepsTheDayOrUsesTheMonthEnd(t *testing.T) {
	start := time.Date(2026, 1, 31, 9, 0, 0, 0, time.UTC)
	for n, want := range []string{"2026-01-31", "2026-02-28", "2026-03-31", "2026-04-30"} {
		if got := Occurrence(start, "monthly", n).Format("2006-01-02"); got != want {
			t.Errorf("monthly %d = %s, want %s", n, got, want)
		}
	}
	if got := Occurrence(start, "weekly", 2).Format("2006-01-02"); got != "2026-02-14" {
		t.Errorf("weekly = %s", got)
	}
}

func TestClaimPausesAndSkipsMissedRuns(t *testing.T) {
	ctx := context.Background()
	pool := testdb.New(t)
	w, _ := wallets.Create(ctx, pool, "ada", "9000000001")
	var user int64
	if err := pool.QueryRow(ctx, `insert into users (phone, pin_hash, wallet_account_id) values ('+2348031234567', 'x', $1)
		returning id`, w.AccountID).Scan(&user); err != nil {
		t.Fatal(err)
	}
	now := time.Date(2026, 10, 23, 12, 0, 0, 0, time.UTC)
	s := NewService(pool)
	s.Now = func() time.Time { return now }

	daily, err := s.Create(ctx, Schedule{UserID: user, WalletID: w.AccountID, Kind: "savings", Name: "Daily jar",
		Amount: 500_00, Frequency: "daily", StartsAt: now, Target: Target{PotID: "p"}})
	if err != nil {
		t.Fatal(err)
	}
	once, _ := s.Create(ctx, Schedule{UserID: user, WalletID: w.AccountID, Kind: "avora", Name: "Rent",
		Amount: 50_000_00, Frequency: "once", StartsAt: now.Add(time.Hour), Target: Target{To: "@bola"}})
	if _, err := s.Create(ctx, Schedule{UserID: user, WalletID: w.AccountID, Kind: "avora", Name: "Old",
		Amount: 1, Frequency: "once", StartsAt: now.AddDate(0, 0, -2), Target: Target{To: "@bola"}}); err == nil {
		t.Fatal("a start in the past was accepted")
	}

	due, _ := s.Claim(ctx, 10)
	if len(due) != 1 || due[0].ID != daily.ID || due[0].Runs != 0 {
		t.Fatalf("due = %+v", due)
	}
	if again, _ := s.Claim(ctx, 10); len(again) != 0 {
		t.Fatalf("claimed twice: %+v", again)
	}

	// Three days later, the one-off has run once and the daily one skips to tomorrow.
	now = now.AddDate(0, 0, 3)
	due, _ = s.Claim(ctx, 10)
	if len(due) != 2 {
		t.Fatalf("due = %+v", due)
	}
	got, _ := s.Get(ctx, user, daily.ID)
	if !got.NextRun.Equal(now.AddDate(0, 0, 1)) || got.Runs != 4 {
		t.Fatalf("daily = next %v, runs %d", got.NextRun, got.Runs)
	}
	if o, _ := s.Get(ctx, user, once.ID); o.Status != "done" {
		t.Fatalf("once = %s", o.Status)
	}

	s.SetPaused(ctx, user, daily.ID, true)
	now = now.AddDate(0, 0, 5)
	if due, _ := s.Claim(ctx, 10); len(due) != 0 {
		t.Fatalf("paused but claimed: %+v", due)
	}
	resumed, _ := s.SetPaused(ctx, user, daily.ID, false)
	if resumed.Status != "active" || resumed.NextRun.Before(now) {
		t.Fatalf("resumed = %+v", resumed)
	}
}
