// Package cards runs virtual cards that spend straight from the wallet.
//
// The card scheme asks us to authorise each payment; Charge approves it
// (moving the money out of the wallet) or declines it with a reason the
// customer can act on: the card is frozen, over its monthly limit, or the
// wallet is short. Until a card issuer is signed, cards run in the sandbox
// and their numbers are derived from the card id, not issued.
package cards

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/binary"
	"errors"
	"fmt"
	"regexp"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"avora/backend/internal/ledger"
	"avora/backend/internal/notify"
	"avora/backend/internal/wallets"
)

var (
	ErrInvalid  = errors.New("cards: invalid request")
	ErrNotFound = errors.New("cards: not found")
	ErrTooMany  = errors.New("cards: too many cards")
	ErrClosed   = errors.New("cards: card is terminated")
)

// MaxCards is how many live cards a customer can hold.
const MaxCards = 3

type Status string

const (
	Active     Status = "active"
	Frozen     Status = "frozen"
	Terminated Status = "terminated"
)

type Card struct {
	ID           string    `json:"id"`
	WalletID     int64     `json:"-"`
	Name         string    `json:"name"`
	Brand        string    `json:"brand"`
	Last4        string    `json:"last4"`
	Expiry       string    `json:"expiry"` // MM/YY
	Status       Status    `json:"status"`
	MonthlyLimit int64     `json:"monthly_limit"` // 0 means none
	SpentMonth   int64     `json:"spent_this_month"`
	CreatedAt    time.Time `json:"created_at"`
}

// Details are what's needed to pay online. Show them only after a PIN.
type Details struct {
	Number string `json:"number"`
	Expiry string `json:"expiry"`
	CVV    string `json:"cvv"`
	Name   string `json:"name_on_card"`
}

type Payment struct {
	ID            string    `json:"id"`
	CardID        string    `json:"card_id"`
	Merchant      string    `json:"merchant"`
	Amount        int64     `json:"amount"`
	Status        string    `json:"status"` // approved or declined
	DeclineReason string    `json:"decline_reason,omitempty"`
	CreatedAt     time.Time `json:"created_at"`
}

type Service struct {
	db     *pgxpool.Pool
	sys    wallets.System
	secret []byte // sandbox card numbers
	Now    func() time.Time
}

func NewService(db *pgxpool.Pool, sys wallets.System, secret []byte) *Service {
	return &Service{db: db, sys: sys, secret: secret, Now: time.Now}
}

var lagos = time.FixedZone("WAT", 60*60)

func (s *Service) monthStart() time.Time {
	n := s.Now().In(lagos)
	return time.Date(n.Year(), n.Month(), 1, 0, 0, 0, 0, lagos)
}

// sandboxNumber is a Luhn-valid 16-digit number on a test Verve range.
func (s *Service) sandboxNumber(id string) (string, string) {
	mac := hmac.New(sha256.New, s.secret)
	mac.Write([]byte(id))
	sum := mac.Sum(nil)
	digits := "506199"
	n := binary.BigEndian.Uint64(sum[:8])
	digits += fmt.Sprintf("%09d", n%1_000_000_000)
	digits += luhn(digits)
	cvv := fmt.Sprintf("%03d", binary.BigEndian.Uint16(sum[8:10])%1000)
	return digits, cvv
}

func luhn(partial string) string {
	sum := 0
	for i := len(partial) - 1; i >= 0; i-- {
		d := int(partial[i] - '0')
		if (len(partial)-i)%2 == 1 {
			d *= 2
			if d > 9 {
				d -= 9
			}
		}
		sum += d
	}
	return fmt.Sprint((10 - sum%10) % 10)
}

var nameRe = regexp.MustCompile(`^[\pL\pN ' -]{1,24}$`)

// Create issues a new virtual card.
func (s *Service) Create(ctx context.Context, walletID int64, name string) (Card, error) {
	name = strings.Join(strings.Fields(name), " ")
	if name == "" {
		name = "Online card"
	}
	if !nameRe.MatchString(name) {
		return Card{}, fmt.Errorf("%w: a card name is up to 24 letters or numbers", ErrInvalid)
	}
	tx, err := s.db.Begin(ctx)
	if err != nil {
		return Card{}, err
	}
	defer tx.Rollback(ctx)
	// One card at a time per wallet, so the count below holds.
	if _, err := tx.Exec(ctx, `select 1 from wallets where account_id = $1 for update`, walletID); err != nil {
		return Card{}, err
	}
	var live int
	if err := tx.QueryRow(ctx, `select count(*) from cards where wallet_account_id = $1 and status <> 'terminated'`,
		walletID).Scan(&live); err != nil {
		return Card{}, err
	}
	if live >= MaxCards {
		return Card{}, ErrTooMany
	}
	var id string
	if err := tx.QueryRow(ctx, `select gen_random_uuid()::text`).Scan(&id); err != nil {
		return Card{}, err
	}
	number, _ := s.sandboxNumber(id)
	expiry := s.Now().In(lagos).AddDate(3, 0, 0).Format("01/06")
	if _, err := tx.Exec(ctx, `
		insert into cards (id, wallet_account_id, name, last4, expiry) values ($1, $2, $3, $4, $5)`,
		id, walletID, name, number[12:], expiry); err != nil {
		return Card{}, err
	}
	if err := tx.Commit(ctx); err != nil {
		return Card{}, err
	}
	return s.Get(ctx, walletID, id)
}

const columns = `c.id, c.wallet_account_id, c.name, c.brand, c.last4, c.expiry, c.status, c.monthly_limit, c.created_at,
	coalesce((select sum(p.amount) from card_payments p
		where p.card_id = c.id and p.status = 'approved' and p.created_at >= $2), 0)`

func scan(row pgx.Row) (Card, error) {
	var c Card
	err := row.Scan(&c.ID, &c.WalletID, &c.Name, &c.Brand, &c.Last4, &c.Expiry, &c.Status, &c.MonthlyLimit,
		&c.CreatedAt, &c.SpentMonth)
	if errors.Is(err, pgx.ErrNoRows) {
		return Card{}, ErrNotFound
	}
	return c, err
}

var uuidRe = regexp.MustCompile(`^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$`)

// Get returns one of the wallet's cards; another wallet's card is not found.
func (s *Service) Get(ctx context.Context, walletID int64, id string) (Card, error) {
	if !uuidRe.MatchString(id) {
		return Card{}, ErrNotFound
	}
	return scan(s.db.QueryRow(ctx, `select `+columns+` from cards c where c.id = $1 and c.wallet_account_id = $3`,
		id, s.monthStart(), walletID))
}

// List returns the wallet's live cards, oldest first.
func (s *Service) List(ctx context.Context, walletID int64) ([]Card, error) {
	rows, err := s.db.Query(ctx, `select `+columns+` from cards c
		where c.wallet_account_id = $1 and c.status <> 'terminated' order by c.created_at`, walletID, s.monthStart())
	if err != nil {
		return nil, err
	}
	out := []Card{}
	for rows.Next() {
		c, err := scan(rows)
		if err != nil {
			rows.Close()
			return nil, err
		}
		out = append(out, c)
	}
	return out, rows.Err()
}

func (s *Service) update(ctx context.Context, walletID int64, id, set string, arg any) (Card, error) {
	c, err := s.Get(ctx, walletID, id)
	if err != nil {
		return Card{}, err
	}
	if c.Status == Terminated {
		return Card{}, ErrClosed
	}
	if _, err := s.db.Exec(ctx, `update cards set `+set+` where id = $1`, id, arg); err != nil {
		return Card{}, err
	}
	return s.Get(ctx, walletID, id)
}

// SetFrozen freezes a card so every payment is declined, or unfreezes it.
func (s *Service) SetFrozen(ctx context.Context, walletID int64, id string, frozen bool) (Card, error) {
	st := Active
	if frozen {
		st = Frozen
	}
	return s.update(ctx, walletID, id, "status = $2", st)
}

// SetLimit caps what the card can spend each month; 0 removes the cap.
func (s *Service) SetLimit(ctx context.Context, walletID int64, id string, limit int64) (Card, error) {
	if limit < 0 {
		return Card{}, fmt.Errorf("%w: limit cannot be negative", ErrInvalid)
	}
	return s.update(ctx, walletID, id, "monthly_limit = $2", limit)
}

// Terminate closes a card for good.
func (s *Service) Terminate(ctx context.Context, walletID int64, id string) error {
	_, err := s.update(ctx, walletID, id, "status = $2", Terminated)
	return err
}

// Details returns the number, expiry and CVV for paying online.
func (s *Service) Details(ctx context.Context, walletID int64, id string, holder string) (Details, error) {
	c, err := s.Get(ctx, walletID, id)
	if err != nil {
		return Details{}, err
	}
	if c.Status == Terminated {
		return Details{}, ErrClosed
	}
	number, cvv := s.sandboxNumber(c.ID)
	return Details{Number: number, Expiry: c.Expiry, CVV: cvv, Name: strings.ToUpper(holder)}, nil
}

// Charge authorises a payment from the card scheme. The same key always
// gets the same answer and moves money at most once.
func (s *Service) Charge(ctx context.Context, cardID, key, merchant string, amount int64) (Payment, error) {
	merchant = strings.TrimSpace(merchant)
	if key == "" || merchant == "" || amount <= 0 {
		return Payment{}, fmt.Errorf("%w: key, merchant and a positive amount are required", ErrInvalid)
	}
	if !uuidRe.MatchString(cardID) {
		return Payment{}, ErrNotFound
	}
	tx, err := s.db.Begin(ctx)
	if err != nil {
		return Payment{}, err
	}
	defer tx.Rollback(ctx)

	var c Card
	err = tx.QueryRow(ctx, `select wallet_account_id, status, monthly_limit, name from cards where id = $1 for update`,
		cardID).Scan(&c.WalletID, &c.Status, &c.MonthlyLimit, &c.Name)
	if errors.Is(err, pgx.ErrNoRows) {
		return Payment{}, ErrNotFound
	}
	if err != nil {
		return Payment{}, err
	}
	if p, err := s.payment(ctx, tx, `card_id = $1 and idempotency_key = $2`, cardID, key); err == nil {
		return p, nil
	} else if !errors.Is(err, ErrNotFound) {
		return Payment{}, err
	}

	reason := ""
	switch c.Status {
	case Frozen:
		reason = "card frozen"
	case Terminated:
		reason = "card terminated"
	}
	if reason == "" && c.MonthlyLimit > 0 {
		var spent int64
		if err := tx.QueryRow(ctx, `select coalesce(sum(amount), 0) from card_payments
			where card_id = $1 and status = 'approved' and created_at >= $2`, cardID, s.monthStart()).Scan(&spent); err != nil {
			return Payment{}, err
		}
		if spent+amount > c.MonthlyLimit {
			reason = "over monthly limit"
		}
	}

	var id string
	if err := tx.QueryRow(ctx, `select gen_random_uuid()::text`).Scan(&id); err != nil {
		return Payment{}, err
	}
	if reason == "" {
		_, err := ledger.Post(ctx, tx, ledger.Journal{
			IdempotencyKey: "card:" + id,
			Kind:           "card_payment",
			Description:    fmt.Sprintf("Card payment · %s", merchant),
			Ref:            id,
			Lines:          []ledger.Line{ledger.Debit(c.WalletID, amount), ledger.Credit(s.sys.Settlement, amount)},
		})
		if errors.Is(err, ledger.ErrInsufficientFunds) {
			// The failed journal leaves the transaction unusable; start again for the decline.
			tx.Rollback(ctx)
			return s.decline(ctx, cardID, key, merchant, amount, "insufficient funds", c.WalletID)
		}
		if err != nil {
			return Payment{}, err
		}
	}
	status := "approved"
	if reason != "" {
		status = "declined"
	}
	if _, err := tx.Exec(ctx, `
		insert into card_payments (id, card_id, idempotency_key, merchant, amount, status, decline_reason)
		values ($1, $2, $3, $4, $5, $6, $7)`, id, cardID, key, merchant, amount, status, reason); err != nil {
		return Payment{}, err
	}
	if err := s.tell(ctx, tx, c.WalletID, merchant, amount, reason, id); err != nil {
		return Payment{}, err
	}
	if err := tx.Commit(ctx); err != nil {
		return Payment{}, err
	}
	return s.payment(ctx, s.db, `id = $1`, id)
}

func (s *Service) decline(ctx context.Context, cardID, key, merchant string, amount int64, reason string, wallet int64) (Payment, error) {
	tx, err := s.db.Begin(ctx)
	if err != nil {
		return Payment{}, err
	}
	defer tx.Rollback(ctx)
	var id string
	err = tx.QueryRow(ctx, `
		insert into card_payments (card_id, idempotency_key, merchant, amount, status, decline_reason)
		values ($1, $2, $3, $4, 'declined', $5)
		on conflict (card_id, idempotency_key) do nothing
		returning id`, cardID, key, merchant, amount, reason).Scan(&id)
	if errors.Is(err, pgx.ErrNoRows) {
		return s.payment(ctx, s.db, `card_id = $1 and idempotency_key = $2`, cardID, key)
	}
	if err != nil {
		return Payment{}, err
	}
	if err := s.tell(ctx, tx, wallet, merchant, amount, reason, id); err != nil {
		return Payment{}, err
	}
	if err := tx.Commit(ctx); err != nil {
		return Payment{}, err
	}
	return s.payment(ctx, s.db, `id = $1`, id)
}

func (s *Service) tell(ctx context.Context, db ledger.DB, wallet int64, merchant string, amount int64, reason, id string) error {
	if reason == "" {
		return notify.Add(ctx, db, wallet, "card", fmt.Sprintf("%s paid with your card", notify.Naira(amount)),
			"At "+merchant+".", id)
	}
	why := map[string]string{
		"card frozen":        "Your card is frozen. Unfreeze it in Cards if this was you.",
		"card terminated":    "That card is closed.",
		"over monthly limit": "It would take the card over its monthly limit. You can raise the limit in Cards.",
		"insufficient funds": "Your balance was too low. Add money and try again.",
	}[reason]
	return notify.Add(ctx, db, wallet, "card", fmt.Sprintf("Card payment of %s declined", notify.Naira(amount)),
		fmt.Sprintf("At %s. %s", merchant, why), id)
}

func (s *Service) payment(ctx context.Context, db ledger.DB, where string, args ...any) (Payment, error) {
	var p Payment
	err := db.QueryRow(ctx, `select id, card_id, merchant, amount, status, decline_reason, created_at
		from card_payments where `+where, args...).Scan(&p.ID, &p.CardID, &p.Merchant, &p.Amount, &p.Status,
		&p.DeclineReason, &p.CreatedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return Payment{}, ErrNotFound
	}
	return p, err
}

// Payments lists a card's recent payments, newest first.
func (s *Service) Payments(ctx context.Context, walletID int64, cardID string) ([]Payment, error) {
	if _, err := s.Get(ctx, walletID, cardID); err != nil {
		return nil, err
	}
	rows, err := s.db.Query(ctx, `select id, card_id, merchant, amount, status, decline_reason, created_at
		from card_payments where card_id = $1 order by created_at desc limit 50`, cardID)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, func(r pgx.CollectableRow) (Payment, error) {
		var p Payment
		err := r.Scan(&p.ID, &p.CardID, &p.Merchant, &p.Amount, &p.Status, &p.DeclineReason, &p.CreatedAt)
		return p, err
	})
}

// Owner returns the wallet a card belongs to.
func (s *Service) Owner(ctx context.Context, cardID string) (int64, error) {
	if !uuidRe.MatchString(cardID) {
		return 0, ErrNotFound
	}
	var w int64
	err := s.db.QueryRow(ctx, `select wallet_account_id from cards where id = $1`, cardID).Scan(&w)
	if errors.Is(err, pgx.ErrNoRows) {
		return 0, ErrNotFound
	}
	return w, err
}
