package savings

import (
	"context"
	"errors"
	"fmt"
	"slices"

	"github.com/jackc/pgx/v5"

	"avora/backend/internal/ledger"
)

// RoundUpSteps are the amounts a payment can be rounded up to: ₦10, ₦100
// or ₦1,000.
var RoundUpSteps = []int64{10_00, 100_00, 1_000_00}

type RoundUpSetting struct {
	PotID string `json:"pot_id"` // "" when off
	Step  int64  `json:"step"`
}

func (s *Service) RoundUpSetting(ctx context.Context, walletID int64) (RoundUpSetting, error) {
	var r RoundUpSetting
	err := s.db.QueryRow(ctx, `select pot_id::text, step from savings_roundups where wallet_account_id = $1`,
		walletID).Scan(&r.PotID, &r.Step)
	if errors.Is(err, pgx.ErrNoRows) {
		return RoundUpSetting{Step: 100_00}, nil
	}
	return r, err
}

// SetRoundUp turns round-ups on into a goal pot, or off when potID is "".
func (s *Service) SetRoundUp(ctx context.Context, walletID int64, potID string, step int64) (RoundUpSetting, error) {
	if potID == "" {
		_, err := s.db.Exec(ctx, `delete from savings_roundups where wallet_account_id = $1`, walletID)
		return RoundUpSetting{Step: 100_00}, err
	}
	if !slices.Contains(RoundUpSteps, step) {
		return RoundUpSetting{}, fmt.Errorf("%w: round up to ₦10, ₦100 or ₦1,000", ErrInvalid)
	}
	p, err := s.Get(ctx, walletID, potID)
	if err != nil {
		return RoundUpSetting{}, err
	}
	if p.Status != "open" || p.Kind != Goal {
		return RoundUpSetting{}, fmt.Errorf("%w: round-ups go into an open goal pot", ErrInvalid)
	}
	_, err = s.db.Exec(ctx, `
		insert into savings_roundups (wallet_account_id, pot_id, step) values ($1, $2, $3)
		on conflict (wallet_account_id) do update set pot_id = $2, step = $3`, walletID, potID, step)
	return RoundUpSetting{PotID: potID, Step: step}, err
}

// RoundUp saves the change from a payment of amount, identified by ref,
// into the round-up pot. It saves nothing when round-ups are off, the
// amount is already round, the pot has closed or the wallet is short.
func (s *Service) RoundUp(ctx context.Context, walletID int64, ref string, amount int64) (int64, error) {
	r, err := s.RoundUpSetting(ctx, walletID)
	if err != nil || r.PotID == "" || amount <= 0 || amount%r.Step == 0 {
		return 0, err
	}
	extra := r.Step - amount%r.Step
	p, err := s.Get(ctx, walletID, r.PotID)
	if err != nil {
		return 0, err
	}
	if p.Status != "open" {
		return 0, nil
	}
	err = s.post(ctx, ledger.Journal{
		IdempotencyKey: "roundup:" + ref,
		Kind:           "savings_deposit",
		Description:    "Round-up to " + p.Name,
		Ref:            p.ID,
		Lines:          []ledger.Line{ledger.Debit(walletID, extra), ledger.Credit(p.AccountID, extra)},
	})
	if errors.Is(err, ledger.ErrInsufficientFunds) {
		return 0, nil
	}
	return extra, err
}
