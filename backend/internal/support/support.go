// Package support runs the help centre and the in-app chat. A bot answers
// first from the help articles; anything it can't answer, or a customer
// asking for a person, is left for an agent to reply to through the ops
// API.
package support

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/jackc/pgx/v5/pgxpool"

	"avora/backend/internal/notify"
)

var ErrInvalid = errors.New("support: invalid request")

type Article struct {
	ID       string   `json:"id"`
	Topic    string   `json:"topic"`
	Title    string   `json:"title"`
	Body     string   `json:"body"`
	keywords []string // lower case
}

// Articles is the help centre. The app shows the same list.
var Articles = []Article{
	{ID: "transfer-pending", Topic: "Transfers", Title: "My transfer hasn't arrived",
		Body: "Most transfers arrive in seconds. If the other bank is slow, your receipt says \"With the bank\" and we keep checking. " +
			"If the bank declines it or doesn't confirm, the full amount and fee come back to your wallet automatically. You don't need to call anyone.",
		keywords: []string{"transfer", "not arrived", "pending", "hasn't", "didn't receive", "delay", "stuck", "sent"}},
	{ID: "transfer-fees", Topic: "Transfers", Title: "How much do transfers cost?",
		Body:     "Your first 5 transfers each month are free. After that each transfer costs ₦10. The fee is always shown before you approve.",
		keywords: []string{"fee", "charge", "cost", "free", "how much"}},
	{ID: "wrong-account", Topic: "Transfers", Title: "I sent money to the wrong account",
		Body: "We check the account name before you send, so look at the receipt first. If it went to the wrong person, chat with an agent here " +
			"with the receipt; we will ask the other bank to recall it. Recalls depend on the receiver's bank and aren't guaranteed.",
		keywords: []string{"wrong account", "wrong person", "mistake", "reverse", "recall"}},
	{ID: "add-money", Topic: "Wallet", Title: "How do I add money?",
		Body: "Send money from any bank app to your Avora account number at TAJBank. It shows on Home and under Add money. " +
			"Credits of ₦10,000 or more carry the government's ₦50 electronic money transfer levy.",
		keywords: []string{"add money", "fund", "deposit", "top up", "account number", "receive"}},
	{ID: "limits", Topic: "Account", Title: "Why can't I send more?",
		Body: "Each account tier has a daily limit set by the CBN: Tier 1 ₦50,000, Tier 2 ₦200,000 and Tier 3 ₦5,000,000. " +
			"Verify your BVN or NIN under Me → Limits to move up. A newly added phone can send up to ₦20,000 in its first 24 hours.",
		keywords: []string{"limit", "tier", "upgrade", "bvn", "nin", "can't send", "maximum"}},
	{ID: "pin", Topic: "Security", Title: "I forgot my PIN or it's locked",
		Body: "After 5 wrong PINs the account locks for 30 minutes to keep it safe. If you remember your PIN, change it under Me → Security. " +
			"If you've forgotten it, chat with an agent and we will verify you and help you reset it.",
		keywords: []string{"pin", "forgot", "locked", "reset", "password"}},
	{ID: "fraud", Topic: "Security", Title: "I think someone else is using my account",
		Body: "Change your PIN now under Me → Security, which signs out your other phones, and remove any phone you don't know under " +
			"Phones signed in. Then chat with an agent. Avora staff will never ask for your PIN or sign-in code.",
		keywords: []string{"fraud", "hacked", "scam", "stolen", "someone else", "unauthorized", "unauthorised"}},
	{ID: "bill-failed", Topic: "Bills", Title: "My airtime, data or electricity didn't come",
		Body: "If the provider declines a payment, the full amount comes back to your wallet automatically and your receipt shows it. " +
			"For electricity, the token is on the receipt; type it into your meter.",
		keywords: []string{"airtime", "data", "electricity", "token", "meter", "dstv", "gotv", "startimes", "bill", "recharge"}},
	{ID: "savings-profit", Topic: "Savings", Title: "How does interest-free savings work?",
		Body: "Avora savings are non-interest. Your savings are invested with our partner bank under mudarabah, and you get a share of the " +
			"profit it actually makes, paid after each month. The rates shown are expected, not promised. Goal pots can be emptied any time; " +
			"locked plans earn more but give back their profit share if you break them early.",
		keywords: []string{"saving", "profit", "interest", "halal", "mudarabah", "locked", "goal"}},
	{ID: "referrals", Topic: "Account", Title: "How do referral rewards work?",
		Body: "Share your invite code from Me → Invite friends. When a friend joins with it and verifies their BVN or NIN, you get a reward " +
			"in your wallet. Friends can add a code within 30 days of joining.",
		keywords: []string{"refer", "invite", "code", "reward", "bonus"}},
}

type Message struct {
	ID        int64     `json:"id"`
	Sender    string    `json:"sender"`
	Body      string    `json:"body"`
	CreatedAt time.Time `json:"created_at"`
}

type Service struct {
	db  *pgxpool.Pool
	now func() time.Time
}

func NewService(db *pgxpool.Pool) *Service { return &Service{db: db, now: time.Now} }

func (s *Service) Messages(ctx context.Context, userID int64) ([]Message, error) {
	rows, err := s.db.Query(ctx, `
		select id, sender, body, created_at from support_messages
		where user_id = $1 order by id desc limit 100`, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Message{}
	for rows.Next() {
		var m Message
		if err := rows.Scan(&m.ID, &m.Sender, &m.Body, &m.CreatedAt); err != nil {
			return nil, err
		}
		out = append(out, m)
	}
	// Oldest first, as a chat reads.
	for i, j := 0, len(out)-1; i < j; i, j = i+1, j-1 {
		out[i], out[j] = out[j], out[i]
	}
	return out, rows.Err()
}

const handoff = "I've passed this to our support team. An agent will reply here, usually within 15 minutes between 7am and 10pm."

// Send stores the customer's message and the bot's answer, and returns the
// whole conversation.
func (s *Service) Send(ctx context.Context, userID int64, body string) ([]Message, error) {
	body = strings.TrimSpace(body)
	if body == "" || utf8.RuneCountInString(body) > 2000 {
		return nil, fmt.Errorf("%w: write a message of up to 2,000 characters", ErrInvalid)
	}
	tx, err := s.db.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	if _, err := tx.Exec(ctx, `insert into support_messages (user_id, sender, body) values ($1, 'customer', $2)`,
		userID, body); err != nil {
		return nil, err
	}
	if _, err := tx.Exec(ctx, `insert into support_messages (user_id, sender, body) values ($1, 'bot', $2)`,
		userID, Answer(body)); err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	return s.Messages(ctx, userID)
}

// Reply posts an agent's answer and tells the customer.
func (s *Service) Reply(ctx context.Context, userID int64, body string) error {
	body = strings.TrimSpace(body)
	if body == "" {
		return fmt.Errorf("%w: reply is empty", ErrInvalid)
	}
	tx, err := s.db.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	var wallet int64
	if err := tx.QueryRow(ctx, `select wallet_account_id from users where id = $1`, userID).Scan(&wallet); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `insert into support_messages (user_id, sender, body) values ($1, 'agent', $2)`,
		userID, body); err != nil {
		return err
	}
	preview := body
	if utf8.RuneCountInString(preview) > 80 {
		preview = string([]rune(preview)[:80]) + "…"
	}
	if err := notify.Add(ctx, tx, wallet, "support", "Support replied", preview, ""); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

// Answer picks the help article that best matches the question, or hands
// over to a person.
func Answer(question string) string {
	q := strings.ToLower(question)
	for _, w := range []string{"agent", "human", "person", "customer care", "speak to"} {
		if strings.Contains(q, w) {
			return handoff
		}
	}
	best, score := -1, 0
	for i, a := range Articles {
		n := 0
		for _, k := range a.keywords {
			if strings.Contains(q, k) {
				n++
			}
		}
		if n > score {
			best, score = i, n
		}
	}
	if best < 0 {
		return handoff
	}
	a := Articles[best]
	return a.Title + "\n\n" + a.Body + "\n\nIf that doesn't help, type \"agent\" to talk to a person."
}
