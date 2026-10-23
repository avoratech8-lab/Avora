// Package referrals gives every customer a code to invite friends. The
// inviter is paid once the friend verifies a BVN or NIN, so rewards go to
// real, identified customers rather than throwaway sign-ups.
package referrals

import (
	"context"
	"crypto/rand"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"avora/backend/internal/ledger"
	"avora/backend/internal/notify"
)

var (
	ErrInvalid     = errors.New("referrals: invalid request")
	ErrUnknownCode = errors.New("referrals: unknown code")
	ErrAlreadyUsed = errors.New("referrals: already joined with a code")
	ErrTooLate     = errors.New("referrals: too late to add a code")
	ErrOwnCode     = errors.New("referrals: own code")
)

type Config struct {
	Reward int64         // kobo paid to the inviter
	Window time.Duration // how long after sign-up a code can be added
}

// DefaultConfig is a placeholder until marketing sets the budget.
func DefaultConfig() Config { return Config{Reward: 500_00, Window: 30 * 24 * time.Hour} }

type Summary struct {
	Code       string `json:"code"`
	Reward     int64  `json:"reward"`
	Invited    int    `json:"invited"`
	Rewarded   int    `json:"rewarded"`
	Earned     int64  `json:"earned"`
	JoinedWith string `json:"joined_with"` // the code this customer joined with, if any
	CanAddCode bool   `json:"can_add_code"`
}

type Service struct {
	db      *pgxpool.Pool
	cfg     Config
	account int64 // system:referral_rewards
	now     func() time.Time
}

func NewService(ctx context.Context, db *pgxpool.Pool, cfg Config) (*Service, error) {
	var acct int64
	if err := db.QueryRow(ctx, `select id from accounts where code = 'system:referral_rewards'`).Scan(&acct); err != nil {
		return nil, fmt.Errorf("referrals: rewards account missing; run migrations: %w", err)
	}
	return &Service{db: db, cfg: cfg, account: acct, now: time.Now}, nil
}

// Code alphabet without 0/O and 1/I, so codes read out loud survive.
const alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"

func newCode() (string, error) {
	b := make([]byte, 6)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	for i := range b {
		b[i] = alphabet[int(b[i])%len(alphabet)]
	}
	return "AV" + string(b), nil
}

// code returns the customer's code, making one the first time.
func (s *Service) code(ctx context.Context, userID int64) (string, error) {
	for range 5 {
		var code *string
		if err := s.db.QueryRow(ctx, `select referral_code from users where id = $1`, userID).Scan(&code); err != nil {
			return "", err
		}
		if code != nil {
			return *code, nil
		}
		c, err := newCode()
		if err != nil {
			return "", err
		}
		// A clash with another customer's code just means another try.
		if _, err := s.db.Exec(ctx, `
			update users set referral_code = $2 where id = $1 and referral_code is null
			and not exists (select 1 from users where referral_code = $2)`, userID, c); err != nil {
			return "", err
		}
	}
	return "", errors.New("referrals: could not make a code")
}

func (s *Service) Summary(ctx context.Context, userID int64) (Summary, error) {
	code, err := s.code(ctx, userID)
	if err != nil {
		return Summary{}, err
	}
	sum := Summary{Code: code, Reward: s.cfg.Reward}
	if err := s.db.QueryRow(ctx, `
		select count(*), count(rewarded_at), coalesce(sum(reward), 0)
		from referrals where referrer_user_id = $1`, userID).Scan(&sum.Invited, &sum.Rewarded, &sum.Earned); err != nil {
		return Summary{}, err
	}
	var joinedAt time.Time
	var with *string
	if err := s.db.QueryRow(ctx, `
		select u.created_at, r.referral_code from users u
		left join referrals x on x.referee_user_id = u.id
		left join users r on r.id = x.referrer_user_id
		where u.id = $1`, userID).Scan(&joinedAt, &with); err != nil {
		return Summary{}, err
	}
	if with != nil {
		sum.JoinedWith = *with
	}
	sum.CanAddCode = with == nil && s.now().Sub(joinedAt) < s.cfg.Window
	return sum, nil
}

// Join records that userID was invited with code. If they have already
// verified their identity, the inviter is paid straight away.
func (s *Service) Join(ctx context.Context, userID int64, code string) (Summary, error) {
	code = strings.ToUpper(strings.TrimSpace(code))
	if code == "" {
		return Summary{}, fmt.Errorf("%w: enter a code", ErrInvalid)
	}
	tx, err := s.db.Begin(ctx)
	if err != nil {
		return Summary{}, err
	}
	defer tx.Rollback(ctx)

	var referrer int64
	err = tx.QueryRow(ctx, `select id from users where referral_code = $1`, code).Scan(&referrer)
	if errors.Is(err, pgx.ErrNoRows) {
		return Summary{}, ErrUnknownCode
	}
	if err != nil {
		return Summary{}, err
	}
	if referrer == userID {
		return Summary{}, ErrOwnCode
	}
	var joinedAt time.Time
	var tier int
	if err := tx.QueryRow(ctx, `select created_at, kyc_tier from users where id = $1 for update`, userID).
		Scan(&joinedAt, &tier); err != nil {
		return Summary{}, err
	}
	if s.now().Sub(joinedAt) >= s.cfg.Window {
		return Summary{}, ErrTooLate
	}
	tag, err := tx.Exec(ctx, `
		insert into referrals (referee_user_id, referrer_user_id) values ($1, $2)
		on conflict do nothing`, userID, referrer)
	if err != nil {
		return Summary{}, err
	}
	if tag.RowsAffected() == 0 {
		return Summary{}, ErrAlreadyUsed
	}
	if tier >= 2 {
		if err := s.Verified(ctx, tx, userID); err != nil {
			return Summary{}, err
		}
	}
	if err := tx.Commit(ctx); err != nil {
		return Summary{}, err
	}
	return s.Summary(ctx, userID)
}

// Verified pays the inviter, once, when an invited customer verifies their
// identity. It runs inside the caller's transaction.
func (s *Service) Verified(ctx context.Context, tx pgx.Tx, refereeID int64) error {
	var referrerWallet int64
	err := tx.QueryRow(ctx, `
		update referrals x set rewarded_at = $2, reward = $3
		from users r
		where x.referee_user_id = $1 and x.rewarded_at is null and r.id = x.referrer_user_id
		returning r.wallet_account_id`, refereeID, s.now(), s.cfg.Reward).Scan(&referrerWallet)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil // not invited, or already paid
	}
	if err != nil {
		return err
	}
	if s.cfg.Reward <= 0 {
		return nil
	}
	if _, err := ledger.Post(ctx, tx, ledger.Journal{
		IdempotencyKey: fmt.Sprintf("referral:%d", refereeID),
		Kind:           "referral_reward",
		Description:    "Referral reward",
		Lines:          []ledger.Line{ledger.Debit(s.account, s.cfg.Reward), ledger.Credit(referrerWallet, s.cfg.Reward)},
	}); err != nil {
		return err
	}
	return notify.Add(ctx, tx, referrerWallet, "money_in", notify.Naira(s.cfg.Reward)+" referral reward",
		"A friend you invited just verified their account. Thanks for spreading the word!", "")
}
