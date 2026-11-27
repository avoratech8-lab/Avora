package auth

import (
	"context"
	"time"

	"avora/backend/internal/notify"
)

// FreezeStatus says whether money can leave the account.
type FreezeStatus struct {
	Frozen   bool       `json:"frozen"`
	FrozenAt *time.Time `json:"frozen_at"`
}

// Frozen reports whether the customer has frozen their account.
func (s *Service) Frozen(ctx context.Context, userID int64) (FreezeStatus, error) {
	var at *time.Time
	if err := s.db.QueryRow(ctx, `select frozen_at from users where id = $1`, userID).Scan(&at); err != nil {
		return FreezeStatus{}, err
	}
	return FreezeStatus{Frozen: at != nil, FrozenAt: at}, nil
}

// Freeze stops all money leaving the account, at once and with no PIN, for a
// customer who thinks someone else has their phone, PIN or card details. It
// signs out every other phone. Money can still come in.
func (s *Service) Freeze(ctx context.Context, p Principal) (FreezeStatus, error) {
	tx, err := s.db.Begin(ctx)
	if err != nil {
		return FreezeStatus{}, err
	}
	defer tx.Rollback(ctx)
	var prev *time.Time
	if err := tx.QueryRow(ctx, `select frozen_at from users where id = $1 for update`, p.UserID).Scan(&prev); err != nil {
		return FreezeStatus{}, err
	}
	was := prev != nil
	at := s.now()
	if was {
		at = *prev
	} else if _, err := tx.Exec(ctx, `update users set frozen_at = $2 where id = $1`, p.UserID, at); err != nil {
		return FreezeStatus{}, err
	}
	if _, err := tx.Exec(ctx, `delete from sessions where user_id = $1 and device_id <> $2`, p.UserID, p.DeviceID); err != nil {
		return FreezeStatus{}, err
	}
	if !was {
		if err := notify.Add(ctx, tx, p.WalletID, "security", "Account frozen",
			"No money can leave your account, and your other phones were signed out. Money can still come in. "+
				"Unfreeze it with your PIN under Me → Security when you're ready.", ""); err != nil {
			return FreezeStatus{}, err
		}
	}
	return FreezeStatus{Frozen: true, FrozenAt: &at}, tx.Commit(ctx)
}

// Unfreeze lets money leave the account again. It needs the PIN, so a thief
// holding an unlocked phone can't undo a freeze.
func (s *Service) Unfreeze(ctx context.Context, p Principal, pin string) (FreezeStatus, error) {
	if err := s.CheckPIN(ctx, p.UserID, pin); err != nil {
		return FreezeStatus{}, err
	}
	tx, err := s.db.Begin(ctx)
	if err != nil {
		return FreezeStatus{}, err
	}
	defer tx.Rollback(ctx)
	tag, err := tx.Exec(ctx, `update users set frozen_at = null where id = $1 and frozen_at is not null`, p.UserID)
	if err != nil {
		return FreezeStatus{}, err
	}
	if tag.RowsAffected() > 0 {
		if err := notify.Add(ctx, tx, p.WalletID, "security", "Account unfrozen",
			"Money can leave your account again. If you didn't do this, freeze it now and chat with us.", ""); err != nil {
			return FreezeStatus{}, err
		}
	}
	return FreezeStatus{}, tx.Commit(ctx)
}
