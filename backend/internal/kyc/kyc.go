// Package kyc runs the CBN's tiered KYC: phone-only accounts start at tier
// 1; a verified BVN or NIN gives tier 2; both give tier 3. Each tier caps
// how much can leave the wallet in a day and how much it may hold.
//
// The limits below follow the commonly published CBN tiers and must be
// confirmed with the partner bank before launch.
package kyc

import (
	"context"
	"errors"
	"fmt"
	"regexp"
	"strings"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"avora/backend/internal/notify"
)

var (
	ErrInvalid  = errors.New("kyc: invalid request")
	ErrMismatch = errors.New("kyc: details don't match")
)

type Limits struct {
	Tier       int    `json:"tier"`
	DailySend  int64  `json:"daily_send"`  // kobo
	MaxBalance int64  `json:"max_balance"` // kobo; 0 means no cap
	Needs      string `json:"needs"`
}

var Tiers = []Limits{
	{Tier: 1, DailySend: 50_000_00, MaxBalance: 300_000_00, Needs: "Phone number"},
	{Tier: 2, DailySend: 200_000_00, MaxBalance: 500_000_00, Needs: "BVN or NIN"},
	{Tier: 3, DailySend: 5_000_000_00, MaxBalance: 0, Needs: "BVN and NIN"},
}

func LimitsFor(tier int) Limits {
	for _, t := range Tiers {
		if t.Tier == tier {
			return t
		}
	}
	return Tiers[0]
}

// Verifier checks an ID number against the national records, via the
// partner bank (BVN through NIBSS, NIN through NIMC).
type Verifier interface {
	Verify(ctx context.Context, kind, number, phone string) error
}

// Sandbox accepts any 11-digit number except ones ending in 0.
type Sandbox struct{}

func (Sandbox) Verify(_ context.Context, _, number, _ string) error {
	if strings.HasSuffix(number, "0") {
		return ErrMismatch
	}
	return nil
}

type Status struct {
	Tier        int      `json:"tier"`
	BVNVerified bool     `json:"bvn_verified"`
	NINVerified bool     `json:"nin_verified"`
	Limits      Limits   `json:"limits"`
	Tiers       []Limits `json:"tiers"`
}

type Service struct {
	db *pgxpool.Pool
	v  Verifier

	// OnVerified, if set, runs in the same transaction when a customer
	// first reaches tier 2; referral rewards hang off it.
	OnVerified func(ctx context.Context, tx pgx.Tx, userID int64) error
}

func NewService(db *pgxpool.Pool, v Verifier) *Service { return &Service{db: db, v: v} }

func (s *Service) Status(ctx context.Context, userID int64) (Status, error) {
	var st Status
	var bvn, nin string
	if err := s.db.QueryRow(ctx, `select kyc_tier, bvn_last4, nin_last4 from users where id = $1`, userID).
		Scan(&st.Tier, &bvn, &nin); err != nil {
		return Status{}, err
	}
	st.BVNVerified, st.NINVerified = bvn != "", nin != ""
	st.Limits = LimitsFor(st.Tier)
	st.Tiers = Tiers
	return st, nil
}

var idRe = regexp.MustCompile(`^\d{11}$`)

// Verify checks a BVN or NIN and raises the tier. Only the last four
// digits are stored.
func (s *Service) Verify(ctx context.Context, userID, walletID int64, kind, number string) (Status, error) {
	if kind != "bvn" && kind != "nin" {
		return Status{}, fmt.Errorf("%w: type must be bvn or nin", ErrInvalid)
	}
	if !idRe.MatchString(number) {
		return Status{}, fmt.Errorf("%w: %s must be 11 digits", ErrInvalid, strings.ToUpper(kind))
	}
	var phone string
	var before int
	if err := s.db.QueryRow(ctx, `select phone, kyc_tier from users where id = $1`, userID).Scan(&phone, &before); err != nil {
		return Status{}, err
	}
	if err := s.v.Verify(ctx, kind, number, phone); err != nil {
		return Status{}, err
	}

	tx, err := s.db.Begin(ctx)
	if err != nil {
		return Status{}, err
	}
	defer tx.Rollback(ctx)
	col := kind + "_last4" // kind is checked above, so this is one of two fixed names
	if _, err := tx.Exec(ctx, `update users set `+col+` = $2 where id = $1`, userID, number[7:]); err != nil {
		return Status{}, err
	}
	var after int
	err = tx.QueryRow(ctx, `
		update users set kyc_tier = 1 + (bvn_last4 <> '')::int + (nin_last4 <> '')::int
		where id = $1 returning kyc_tier`, userID).Scan(&after)
	if err != nil {
		return Status{}, err
	}
	if before < 2 && after >= 2 && s.OnVerified != nil {
		if err := s.OnVerified(ctx, tx, userID); err != nil {
			return Status{}, err
		}
	}
	if after > before {
		l := LimitsFor(after)
		if err := notify.Add(ctx, tx, walletID, "account", fmt.Sprintf("You're now on Tier %d", after),
			fmt.Sprintf("You can now send up to %s a day.", notify.Naira(l.DailySend)), ""); err != nil {
			return Status{}, err
		}
	}
	if err := tx.Commit(ctx); err != nil {
		return Status{}, err
	}
	return s.Status(ctx, userID)
}
