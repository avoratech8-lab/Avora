// Package insights totals a wallet's month from the ledger: money in, money
// out by category, what went into savings, and progress against budgets.
//
// Each journal is counted by its net effect on the wallet, so a refund
// cancels the payment it reverses within the same category.
package insights

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"avora/backend/internal/notify"
)

var ErrInvalid = errors.New("insights: invalid request")

// Lagos is where months start and end.
var Lagos = time.FixedZone("WAT", 60*60)

// All is the budget for all spending together.
const All = "all"

// Categories are the spending categories, in display order.
var Categories = []string{
	"transfers", "avora", "cards", "airtime", "data", "electricity", "tv", "internet", "education", "betting", "other",
}

var labels = map[string]string{
	All: "monthly", "transfers": "bank transfers", "avora": "Avora transfers", "cards": "card", "airtime": "airtime", "data": "data",
	"electricity": "electricity", "tv": "TV", "internet": "internet", "education": "exam PINs",
	"betting": "betting", "other": "other",
}

type Category struct {
	Category string `json:"category"`
	Amount   int64  `json:"amount"` // kobo, net of refunds
	Count    int    `json:"count"`
	Budget   int64  `json:"budget"` // 0 if none
}

type Month struct {
	Month       string     `json:"month"` // 2026-10
	MoneyIn     int64      `json:"money_in"`
	MoneyOut    int64      `json:"money_out"` // spending, not savings
	Saved       int64      `json:"saved"`     // into savings, net of withdrawals
	Cashback    int64      `json:"cashback"`
	PreviousOut int64      `json:"previous_out"`
	Budget      int64      `json:"budget"`     // the "all" budget, 0 if none
	Categories  []Category `json:"categories"` // biggest first; budgeted ones even at 0
	Days        []int64    `json:"days"`       // spending on each day of the month
}

type Service struct {
	db  *pgxpool.Pool
	Now func() time.Time
}

func NewService(db *pgxpool.Pool) *Service { return &Service{db: db, Now: time.Now} }

// ParseMonth reads "2026-10"; empty means this month.
func (s *Service) ParseMonth(v string) (time.Time, error) {
	if v == "" {
		n := s.Now().In(Lagos)
		return time.Date(n.Year(), n.Month(), 1, 0, 0, 0, 0, Lagos), nil
	}
	t, err := time.ParseInLocation("2006-01", v, Lagos)
	if err != nil {
		return time.Time{}, fmt.Errorf("%w: month must look like 2026-10", ErrInvalid)
	}
	return t, nil
}

type journal struct {
	kind, category string
	net            int64 // + into the wallet, - out of it
	at             time.Time
}

func (s *Service) journals(ctx context.Context, wallet int64, from, to time.Time) ([]journal, error) {
	rows, err := s.db.Query(ctx, `
		select j.kind, coalesce(b.category, ''), -sum(e.amount), min(e.created_at)
		from entries e
		join journals j on j.id = e.journal_id
		left join bill_payments b on j.kind in ('bill_payment', 'bill_refund') and b.id::text = j.ref
		where e.account_id = $1 and e.created_at >= $2 and e.created_at < $3
		group by j.id, j.kind, b.category`, wallet, from, to)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []journal
	for rows.Next() {
		var j journal
		if err := rows.Scan(&j.kind, &j.category, &j.net, &j.at); err != nil {
			return nil, err
		}
		out = append(out, j)
	}
	return out, rows.Err()
}

// bucket is the spending category a journal belongs to, or "" if it isn't
// spending.
func bucket(j journal) string {
	switch j.kind {
	case "transfer_hold", "transfer_refund":
		return "transfers"
	case "bill_payment", "bill_refund":
		return j.category
	case "card_payment":
		return "cards"
	case "p2p":
		if j.net < 0 {
			return "avora"
		}
		return ""
	case "savings_deposit", "savings_withdraw", "cashback":
		return ""
	}
	if j.net < 0 {
		return "other"
	}
	return ""
}

func isRefund(kind string) bool { return kind == "transfer_refund" || kind == "bill_refund" }

// Month totals one calendar month in Lagos time.
func (s *Service) Month(ctx context.Context, wallet int64, start time.Time) (Month, error) {
	end := start.AddDate(0, 1, 0)
	js, err := s.journals(ctx, wallet, start, end)
	if err != nil {
		return Month{}, err
	}
	m := Month{Month: start.Format("2006-01"), Days: make([]int64, end.AddDate(0, 0, -1).Day())}
	spent := map[string]*Category{}
	for _, j := range js {
		switch b := bucket(j); {
		case b != "":
			c := spent[b]
			if c == nil {
				c = &Category{Category: b}
				spent[b] = c
			}
			c.Amount -= j.net
			if !isRefund(j.kind) {
				c.Count++
			}
			m.Days[j.at.In(Lagos).Day()-1] -= j.net
		case j.kind == "savings_deposit" || j.kind == "savings_withdraw":
			m.Saved -= j.net
		case j.net > 0:
			m.MoneyIn += j.net
			if j.kind == "cashback" {
				m.Cashback += j.net
			}
		}
	}
	for i, d := range m.Days {
		m.Days[i] = max(d, 0)
	}

	budgets, err := s.Budgets(ctx, wallet)
	if err != nil {
		return Month{}, err
	}
	m.Budget = budgets[All]
	for _, name := range Categories {
		c := spent[name]
		if c == nil {
			if budgets[name] == 0 {
				continue
			}
			c = &Category{Category: name}
		}
		c.Amount = max(c.Amount, 0)
		c.Budget = budgets[name]
		m.MoneyOut += c.Amount
		m.Categories = append(m.Categories, *c)
	}
	slices.SortStableFunc(m.Categories, func(a, b Category) int { return int(b.Amount - a.Amount) })

	prev, err := s.journals(ctx, wallet, start.AddDate(0, -1, 0), start)
	if err != nil {
		return Month{}, err
	}
	for _, j := range prev {
		if bucket(j) != "" {
			m.PreviousOut -= j.net
		}
	}
	m.PreviousOut = max(m.PreviousOut, 0)
	return m, nil
}

// Budgets returns the wallet's monthly budgets by category.
func (s *Service) Budgets(ctx context.Context, wallet int64) (map[string]int64, error) {
	rows, err := s.db.Query(ctx, `select category, amount from budgets where wallet_account_id = $1`, wallet)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := map[string]int64{}
	for rows.Next() {
		var c string
		var a int64
		if err := rows.Scan(&c, &a); err != nil {
			return nil, err
		}
		out[c] = a
	}
	return out, rows.Err()
}

// SetBudget sets a monthly budget; an amount of 0 removes it.
func (s *Service) SetBudget(ctx context.Context, wallet int64, category string, amount int64) error {
	if category != All && !slices.Contains(Categories, category) {
		return fmt.Errorf("%w: unknown category", ErrInvalid)
	}
	if amount < 0 || amount > 1_000_000_000_00 {
		return fmt.Errorf("%w: budget must be between ₦0 and ₦1,000,000,000", ErrInvalid)
	}
	if amount == 0 {
		_, err := s.db.Exec(ctx, `delete from budgets where wallet_account_id = $1 and category = $2`, wallet, category)
		return err
	}
	_, err := s.db.Exec(ctx, `
		insert into budgets (wallet_account_id, category, amount) values ($1, $2, $3)
		on conflict (wallet_account_id, category) do update set amount = $3, updated_at = now()`,
		wallet, category, amount)
	return err
}

// Alert notifies once a month when a budget reaches 80%, and again at 100%.
// Call it after each payment.
func (s *Service) Alert(ctx context.Context, wallet int64) error {
	start, _ := s.ParseMonth("")
	m, err := s.Month(ctx, wallet, start)
	if err != nil {
		return err
	}
	check := append([]Category{{Category: All, Amount: m.MoneyOut, Budget: m.Budget}}, m.Categories...)
	for _, c := range check {
		if c.Budget == 0 || c.Amount*100 < c.Budget*80 {
			continue
		}
		level, title := 80, fmt.Sprintf("80%% of your %s budget used", labels[c.Category])
		body := fmt.Sprintf("You've spent %s of %s this month.", notify.Naira(c.Amount), notify.Naira(c.Budget))
		if c.Amount >= c.Budget {
			level, title = 100, fmt.Sprintf("You've reached your %s budget", labels[c.Category])
		}
		tag, err := s.db.Exec(ctx, `
			insert into budget_alerts (wallet_account_id, category, month, level) values ($1, $2, $3, $4)
			on conflict do nothing`, wallet, c.Category, m.Month, level)
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 1 {
			if err := notify.Add(ctx, s.db, wallet, "budget", title, body, ""); err != nil {
				return err
			}
		}
	}
	return nil
}
