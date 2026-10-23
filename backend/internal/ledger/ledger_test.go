package ledger_test

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"testing"

	"github.com/jackc/pgx/v5/pgxpool"

	"avora/backend/internal/ledger"
	"avora/backend/internal/testdb"
)

func newAccount(t *testing.T, pool *pgxpool.Pool, kind ledger.Kind, allowNegative bool) int64 {
	t.Helper()
	var id int64
	err := pool.QueryRow(context.Background(),
		`insert into accounts (code, kind, allow_negative) values ($1, $2, $3) returning id`,
		fmt.Sprintf("test:%s:%p", kind, &id), kind, allowNegative).Scan(&id)
	if err != nil {
		t.Fatal(err)
	}
	return id
}

func post(ctx context.Context, pool *pgxpool.Pool, j ledger.Journal) (ledger.Posted, error) {
	tx, err := pool.Begin(ctx)
	if err != nil {
		return ledger.Posted{}, err
	}
	defer tx.Rollback(ctx)
	p, err := ledger.Post(ctx, tx, j)
	if err != nil {
		return p, err
	}
	return p, tx.Commit(ctx)
}

func balance(t *testing.T, pool *pgxpool.Pool, id int64) int64 {
	t.Helper()
	b, err := ledger.Balance(context.Background(), pool, id)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func TestPostMovesMoneyOnNormalSides(t *testing.T) {
	ctx := context.Background()
	pool := testdb.New(t)
	bank := newAccount(t, pool, ledger.Asset, true)
	wallet := newAccount(t, pool, ledger.Liability, false)

	_, err := post(ctx, pool, ledger.Journal{
		IdempotencyKey: "fund-1", Kind: "test", Description: "fund",
		Lines: []ledger.Line{ledger.Debit(bank, 5000_00), ledger.Credit(wallet, 5000_00)},
	})
	if err != nil {
		t.Fatal(err)
	}
	if got := balance(t, pool, wallet); got != 5000_00 {
		t.Errorf("wallet balance = %d, want 500000", got)
	}
	if got := balance(t, pool, bank); got != 5000_00 {
		t.Errorf("bank balance = %d, want 500000", got)
	}
	if err := ledger.Check(ctx, pool); err != nil {
		t.Error(err)
	}
}

func TestPostRejectsBadJournals(t *testing.T) {
	ctx := context.Background()
	pool := testdb.New(t)
	a := newAccount(t, pool, ledger.Asset, true)
	b := newAccount(t, pool, ledger.Liability, true)

	cases := map[string]struct {
		j    ledger.Journal
		want error
	}{
		"unbalanced": {ledger.Journal{IdempotencyKey: "k1", Kind: "t",
			Lines: []ledger.Line{ledger.Debit(a, 100), ledger.Credit(b, 99)}}, ledger.ErrUnbalanced},
		"one line": {ledger.Journal{IdempotencyKey: "k2", Kind: "t",
			Lines: []ledger.Line{ledger.Debit(a, 100)}}, ledger.ErrInvalidJournal},
		"zero line": {ledger.Journal{IdempotencyKey: "k3", Kind: "t",
			Lines: []ledger.Line{ledger.Debit(a, 0), ledger.Credit(b, 0)}}, ledger.ErrInvalidJournal},
		"no key": {ledger.Journal{Kind: "t",
			Lines: []ledger.Line{ledger.Debit(a, 1), ledger.Credit(b, 1)}}, ledger.ErrInvalidJournal},
		"unknown account": {ledger.Journal{IdempotencyKey: "k4", Kind: "t",
			Lines: []ledger.Line{ledger.Debit(a, 1), ledger.Credit(999999, 1)}}, ledger.ErrUnknownAccount},
	}
	for name, c := range cases {
		t.Run(name, func(t *testing.T) {
			if _, err := post(ctx, pool, c.j); !errors.Is(err, c.want) {
				t.Errorf("err = %v, want %v", err, c.want)
			}
		})
	}
	if got := balance(t, pool, a); got != 0 {
		t.Errorf("balance changed to %d after rejected journals", got)
	}
}

func TestDatabaseRejectsUnbalancedEntriesWrittenDirectly(t *testing.T) {
	ctx := context.Background()
	pool := testdb.New(t)
	a := newAccount(t, pool, ledger.Asset, true)

	tx, err := pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(ctx)
	var jid int64
	if err := tx.QueryRow(ctx, `insert into journals (idempotency_key, kind, description) values ('raw', 't', 'raw') returning id`).Scan(&jid); err != nil {
		t.Fatal(err)
	}
	if _, err := tx.Exec(ctx, `insert into entries (journal_id, account_id, amount) values ($1, $2, 100)`, jid, a); err != nil {
		t.Fatal(err)
	}
	if err := tx.Commit(ctx); err == nil {
		t.Fatal("commit of an unbalanced journal succeeded")
	}
}

func TestEntriesAreAppendOnly(t *testing.T) {
	ctx := context.Background()
	pool := testdb.New(t)
	a := newAccount(t, pool, ledger.Asset, true)
	b := newAccount(t, pool, ledger.Liability, false)
	if _, err := post(ctx, pool, ledger.Journal{IdempotencyKey: "k", Kind: "t",
		Lines: []ledger.Line{ledger.Debit(a, 100), ledger.Credit(b, 100)}}); err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(ctx, `update entries set amount = 1`); err == nil {
		t.Error("update of entries succeeded")
	}
	if _, err := pool.Exec(ctx, `delete from journals`); err == nil {
		t.Error("delete of journals succeeded")
	}
}

func TestInsufficientFunds(t *testing.T) {
	ctx := context.Background()
	pool := testdb.New(t)
	bank := newAccount(t, pool, ledger.Asset, true)
	wallet := newAccount(t, pool, ledger.Liability, false)
	out := newAccount(t, pool, ledger.Liability, false)

	if _, err := post(ctx, pool, ledger.Journal{IdempotencyKey: "fund", Kind: "t",
		Lines: []ledger.Line{ledger.Debit(bank, 100), ledger.Credit(wallet, 100)}}); err != nil {
		t.Fatal(err)
	}
	_, err := post(ctx, pool, ledger.Journal{IdempotencyKey: "spend", Kind: "t",
		Lines: []ledger.Line{ledger.Debit(wallet, 101), ledger.Credit(out, 101)}})
	if !errors.Is(err, ledger.ErrInsufficientFunds) {
		t.Fatalf("err = %v, want ErrInsufficientFunds", err)
	}
	if got := balance(t, pool, wallet); got != 100 {
		t.Errorf("wallet = %d, want 100", got)
	}
}

func TestIdempotentReplayWritesOnce(t *testing.T) {
	ctx := context.Background()
	pool := testdb.New(t)
	bank := newAccount(t, pool, ledger.Asset, true)
	wallet := newAccount(t, pool, ledger.Liability, false)
	j := ledger.Journal{IdempotencyKey: "same", Kind: "t",
		Lines: []ledger.Line{ledger.Debit(bank, 700), ledger.Credit(wallet, 700)}}

	first, err := post(ctx, pool, j)
	if err != nil {
		t.Fatal(err)
	}
	second, err := post(ctx, pool, j)
	if err != nil {
		t.Fatal(err)
	}
	if !second.Replayed || second.JournalID != first.JournalID {
		t.Errorf("second post = %+v, want replay of journal %d", second, first.JournalID)
	}
	if got := balance(t, pool, wallet); got != 700 {
		t.Errorf("wallet = %d, want 700", got)
	}
}

func TestConcurrentSpendsNeverOverdraw(t *testing.T) {
	ctx := context.Background()
	pool := testdb.New(t)
	bank := newAccount(t, pool, ledger.Asset, true)
	wallet := newAccount(t, pool, ledger.Liability, false)
	out := newAccount(t, pool, ledger.Liability, false)
	if _, err := post(ctx, pool, ledger.Journal{IdempotencyKey: "fund", Kind: "t",
		Lines: []ledger.Line{ledger.Debit(bank, 1000), ledger.Credit(wallet, 1000)}}); err != nil {
		t.Fatal(err)
	}

	var wg sync.WaitGroup
	var mu sync.Mutex
	ok := 0
	for i := range 25 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			_, err := post(ctx, pool, ledger.Journal{IdempotencyKey: fmt.Sprintf("spend-%d", i), Kind: "t",
				Lines: []ledger.Line{ledger.Debit(wallet, 100), ledger.Credit(out, 100)}})
			if err == nil {
				mu.Lock()
				ok++
				mu.Unlock()
			} else if !errors.Is(err, ledger.ErrInsufficientFunds) {
				t.Errorf("unexpected error: %v", err)
			}
		}()
	}
	wg.Wait()
	if ok != 10 {
		t.Errorf("%d spends succeeded, want exactly 10", ok)
	}
	if got := balance(t, pool, wallet); got != 0 {
		t.Errorf("wallet = %d, want 0", got)
	}
	if err := ledger.Check(ctx, pool); err != nil {
		t.Error(err)
	}
}

func TestStatementShowsCustomerView(t *testing.T) {
	ctx := context.Background()
	pool := testdb.New(t)
	bank := newAccount(t, pool, ledger.Asset, true)
	wallet := newAccount(t, pool, ledger.Liability, false)
	out := newAccount(t, pool, ledger.Liability, false)
	post(ctx, pool, ledger.Journal{IdempotencyKey: "in", Kind: "t", Description: "in",
		Lines: []ledger.Line{ledger.Debit(bank, 500), ledger.Credit(wallet, 500)}})
	post(ctx, pool, ledger.Journal{IdempotencyKey: "out", Kind: "t", Description: "out",
		Lines: []ledger.Line{ledger.Debit(wallet, 200), ledger.Credit(out, 200)}})

	lines, err := ledger.Statement(ctx, pool, wallet, 10)
	if err != nil {
		t.Fatal(err)
	}
	if len(lines) != 2 || lines[0].Amount != -200 || lines[1].Amount != 500 {
		t.Errorf("statement = %+v, want [-200, +500] newest first", lines)
	}
}
