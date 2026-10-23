// Package p2p moves money between Avora wallets by tag (@ada) or phone
// number. Both wallets are in our own ledger, so a transfer is one journal:
// free, instant, and it can't fail half way.
package p2p

import (
	"context"
	"errors"
	"fmt"
	"regexp"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"

	"avora/backend/internal/auth"
	"avora/backend/internal/ledger"
	"avora/backend/internal/notify"
)

var (
	ErrInvalid             = errors.New("p2p: invalid request")
	ErrNotFound            = errors.New("p2p: no Avora customer found")
	ErrSelf                = errors.New("p2p: can't send to yourself")
	ErrTagTaken            = errors.New("p2p: tag taken")
	ErrIdempotencyConflict = errors.New("p2p: idempotency key reused for a different transfer")
)

var tagRe = regexp.MustCompile(`^[a-z][a-z0-9_]{2,19}$`)

// Tags people might mistake for Avora itself.
var reserved = map[string]bool{"avora": true, "admin": true, "support": true, "help": true, "official": true,
	"security": true, "tajbank": true, "cbn": true, "agent": true, "staff": true}

type Profile struct {
	Name          string `json:"name"`
	Tag           string `json:"tag"`
	Phone         string `json:"phone"`
	AccountNumber string `json:"account_number"`
}

// Person is what a payer sees before sending: enough to be sure, no more.
type Person struct {
	Tag      string `json:"tag"`
	Name     string `json:"name"`
	Phone    string `json:"phone"` // masked, e.g. 0803 *** 4567
	walletID int64
	userID   int64
}

type Transfer struct {
	ID        string    `json:"id"`
	Direction string    `json:"direction"` // "out" or "in", from the viewer's side
	Amount    int64     `json:"amount"`
	Note      string    `json:"note"`
	Other     Person    `json:"other"`
	CreatedAt time.Time `json:"created_at"`
}

type Service struct {
	db *pgxpool.Pool
}

func NewService(db *pgxpool.Pool) *Service { return &Service{db: db} }

func (s *Service) Profile(ctx context.Context, userID int64) (Profile, error) {
	var p Profile
	var tag *string
	err := s.db.QueryRow(ctx, `
		select u.name, u.tag, u.phone, w.nuban from users u
		join wallets w on w.account_id = u.wallet_account_id where u.id = $1`, userID).
		Scan(&p.Name, &tag, &p.Phone, &p.AccountNumber)
	if tag != nil {
		p.Tag = *tag
	}
	return p, err
}

// UpdateProfile sets the display name and the tag. Empty fields are left
// as they are.
func (s *Service) UpdateProfile(ctx context.Context, userID int64, name, tag string) (Profile, error) {
	name = strings.Join(strings.Fields(name), " ")
	tag = strings.ToLower(strings.TrimPrefix(strings.TrimSpace(tag), "@"))
	if name != "" && (utf8.RuneCountInString(name) < 2 || utf8.RuneCountInString(name) > 40) {
		return Profile{}, fmt.Errorf("%w: name must be 2 to 40 characters", ErrInvalid)
	}
	if tag != "" && !tagRe.MatchString(tag) {
		return Profile{}, fmt.Errorf("%w: a tag is 3 to 20 letters, numbers or _, starting with a letter", ErrInvalid)
	}
	if reserved[tag] {
		return Profile{}, ErrTagTaken
	}
	_, err := s.db.Exec(ctx, `
		update users set name = coalesce(nullif($2, ''), name), tag = coalesce(nullif($3, ''), tag)
		where id = $1`, userID, name, tag)
	var pgErr *pgconn.PgError
	if errors.As(err, &pgErr) && pgErr.Code == "23505" {
		return Profile{}, ErrTagTaken
	}
	if err != nil {
		return Profile{}, err
	}
	return s.Profile(ctx, userID)
}

// Find looks a customer up by @tag or phone number.
func (s *Service) Find(ctx context.Context, viewerID int64, q string) (Person, error) {
	q = strings.TrimSpace(q)
	var where string
	var arg string
	if strings.HasPrefix(q, "@") || (q != "" && !strings.ContainsAny(q[:1], "+0123456789")) {
		where, arg = "u.tag = $1", strings.ToLower(strings.TrimPrefix(q, "@"))
	} else {
		phone, err := auth.NormalizePhone(q)
		if err != nil {
			return Person{}, fmt.Errorf("%w: enter an @tag or a phone number", ErrInvalid)
		}
		where, arg = "u.phone = $1", phone
	}
	var p Person
	var tag *string
	err := s.db.QueryRow(ctx, `select u.id, u.wallet_account_id, u.tag, u.name, u.phone from users u where `+where, arg).
		Scan(&p.userID, &p.walletID, &tag, &p.Name, &p.Phone)
	if errors.Is(err, pgx.ErrNoRows) {
		return Person{}, ErrNotFound
	}
	if err != nil {
		return Person{}, err
	}
	if p.userID == viewerID {
		return Person{}, ErrSelf
	}
	if tag != nil {
		p.Tag = *tag
	}
	p.Phone = mask(p.Phone)
	if p.Name == "" {
		p.Name = "Avora customer"
	}
	return p, nil
}

// mask turns +2348031234567 into 0803 *** 4567.
func mask(phone string) string {
	if len(phone) != 14 {
		return ""
	}
	return "0" + phone[4:7] + " *** " + phone[10:]
}

type SendRequest struct {
	IdempotencyKey string
	FromUserID     int64
	FromWallet     int64
	To             string // @tag or phone
	Amount         int64
	Note           string
}

func (s *Service) Send(ctx context.Context, req SendRequest) (Transfer, error) {
	if req.IdempotencyKey == "" {
		return Transfer{}, fmt.Errorf("%w: Idempotency-Key header is required", ErrInvalid)
	}
	if req.Amount <= 0 || req.Amount > 10_000_000_00 {
		return Transfer{}, fmt.Errorf("%w: amount must be between ₦0.01 and ₦10,000,000", ErrInvalid)
	}
	req.Note = strings.TrimSpace(req.Note)
	if utf8.RuneCountInString(req.Note) > 60 {
		return Transfer{}, fmt.Errorf("%w: note must be 60 characters or fewer", ErrInvalid)
	}
	// A retry with the same key gets the first result.
	if t, err := s.byKey(ctx, req.FromWallet, req.IdempotencyKey); err == nil {
		if t.Amount != req.Amount {
			return Transfer{}, ErrIdempotencyConflict
		}
		return t, nil
	} else if !errors.Is(err, pgx.ErrNoRows) {
		return Transfer{}, err
	}

	to, err := s.Find(ctx, req.FromUserID, req.To)
	if err != nil {
		return Transfer{}, err
	}
	var from Person
	if err := s.db.QueryRow(ctx, `select coalesce(tag, ''), name from users where id = $1`, req.FromUserID).
		Scan(&from.Tag, &from.Name); err != nil {
		return Transfer{}, err
	}

	tx, err := s.db.Begin(ctx)
	if err != nil {
		return Transfer{}, err
	}
	defer tx.Rollback(ctx)
	var id string
	var at time.Time
	err = tx.QueryRow(ctx, `
		insert into p2p_transfers (idempotency_key, from_wallet, to_wallet, amount, note)
		values ($1, $2, $3, $4, $5) returning id, created_at`,
		req.IdempotencyKey, req.FromWallet, to.walletID, req.Amount, req.Note).Scan(&id, &at)
	var pgErr *pgconn.PgError
	if errors.As(err, &pgErr) && pgErr.Code == "23505" {
		// The same request arrived twice at once; the other one won.
		tx.Rollback(ctx)
		return s.byKey(ctx, req.FromWallet, req.IdempotencyKey)
	}
	if err != nil {
		return Transfer{}, err
	}
	if _, err := ledger.Post(ctx, tx, ledger.Journal{
		IdempotencyKey: "p2p:" + id,
		Kind:           "p2p",
		Description:    "Avora transfer",
		Ref:            id,
		Lines:          []ledger.Line{ledger.Debit(req.FromWallet, req.Amount), ledger.Credit(to.walletID, req.Amount)},
	}); err != nil {
		return Transfer{}, err
	}
	body := "From " + who(from)
	if req.Note != "" {
		body += ": " + req.Note
	}
	if err := notify.Add(ctx, tx, to.walletID, "money_in", notify.Naira(req.Amount)+" received", body, id); err != nil {
		return Transfer{}, err
	}
	if err := tx.Commit(ctx); err != nil {
		return Transfer{}, err
	}
	return Transfer{ID: id, Direction: "out", Amount: req.Amount, Note: req.Note, Other: to, CreatedAt: at}, nil
}

func who(p Person) string {
	switch {
	case p.Name != "" && p.Tag != "":
		return p.Name + " (@" + p.Tag + ")"
	case p.Tag != "":
		return "@" + p.Tag
	case p.Name != "":
		return p.Name
	}
	return "an Avora customer"
}

const selectTransfer = `
	select t.id, t.from_wallet, t.amount, t.note, t.created_at,
		coalesce(o.tag, ''), o.name, o.phone
	from p2p_transfers t
	join users o on o.wallet_account_id = case when t.from_wallet = $1 then t.to_wallet else t.from_wallet end`

func scan(row pgx.Row, viewerWallet int64) (Transfer, error) {
	var t Transfer
	var from int64
	if err := row.Scan(&t.ID, &from, &t.Amount, &t.Note, &t.CreatedAt, &t.Other.Tag, &t.Other.Name, &t.Other.Phone); err != nil {
		return Transfer{}, err
	}
	t.Direction = "in"
	if from == viewerWallet {
		t.Direction = "out"
	}
	t.Other.Phone = mask(t.Other.Phone)
	if t.Other.Name == "" {
		t.Other.Name = "Avora customer"
	}
	return t, nil
}

func (s *Service) byKey(ctx context.Context, wallet int64, key string) (Transfer, error) {
	return scan(s.db.QueryRow(ctx, selectTransfer+` where t.from_wallet = $1 and t.idempotency_key = $2`, wallet, key), wallet)
}

// Get returns a transfer the viewer sent or received.
func (s *Service) Get(ctx context.Context, viewerWallet int64, id string) (Transfer, error) {
	t, err := scan(s.db.QueryRow(ctx, selectTransfer+` where t.id::text = $2 and $1 in (t.from_wallet, t.to_wallet)`,
		viewerWallet, id), viewerWallet)
	if errors.Is(err, pgx.ErrNoRows) {
		return Transfer{}, ErrNotFound
	}
	return t, err
}

// Describe names the other side of each p2p statement line, keyed by
// transfer id: "To Bola (@bola)" or "From Ada (@ada)".
func (s *Service) Describe(ctx context.Context, viewerWallet int64, ids []string) (map[string]string, error) {
	out := map[string]string{}
	if len(ids) == 0 {
		return out, nil
	}
	rows, err := s.db.Query(ctx, selectTransfer+` where t.id::text = any($2)`, viewerWallet, ids)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		t, err := scan(rows, viewerWallet)
		if err != nil {
			return nil, err
		}
		p := t.Other
		if p.Name == "Avora customer" {
			p.Name = ""
		}
		prefix := "To "
		if t.Direction == "in" {
			prefix = "From "
		}
		out[t.ID] = prefix + who(p)
	}
	return out, rows.Err()
}

// SentSince is what the wallet sent to other Avora users since t, for the
// daily limit.
func (s *Service) SentSince(ctx context.Context, wallet int64, t time.Time) (int64, error) {
	var total int64
	err := s.db.QueryRow(ctx, `select coalesce(sum(amount), 0) from p2p_transfers where from_wallet = $1 and created_at >= $2`,
		wallet, t).Scan(&total)
	return total, err
}
