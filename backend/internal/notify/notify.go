// Package notify keeps the in-app inbox: money in and out, security events
// and account changes. Writers call Add inside their own transaction so a
// notification exists exactly when the thing it describes does.
package notify

import (
	"context"
	"fmt"
	"strconv"
	"strings"
	"time"

	"avora/backend/internal/ledger"
)

type Notification struct {
	ID        int64      `json:"id"`
	Kind      string     `json:"kind"`
	Title     string     `json:"title"`
	Body      string     `json:"body"`
	Ref       string     `json:"ref"`
	CreatedAt time.Time  `json:"created_at"`
	ReadAt    *time.Time `json:"read_at"`
}

func Add(ctx context.Context, db ledger.DB, walletID int64, kind, title, body, ref string) error {
	_, err := db.Exec(ctx, `
		insert into notifications (wallet_account_id, kind, title, body, ref) values ($1, $2, $3, $4, $5)`,
		walletID, kind, title, body, ref)
	return err
}

// List returns the newest notifications and how many are unread.
func List(ctx context.Context, db ledger.DB, walletID int64, limit int) ([]Notification, int, error) {
	rows, err := db.Query(ctx, `
		select id, kind, title, body, ref, created_at, read_at from notifications
		where wallet_account_id = $1 order by id desc limit $2`, walletID, limit)
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()
	out := []Notification{}
	for rows.Next() {
		var n Notification
		if err := rows.Scan(&n.ID, &n.Kind, &n.Title, &n.Body, &n.Ref, &n.CreatedAt, &n.ReadAt); err != nil {
			return nil, 0, err
		}
		out = append(out, n)
	}
	if err := rows.Err(); err != nil {
		return nil, 0, err
	}
	var unread int
	err = db.QueryRow(ctx, `select count(*) from notifications where wallet_account_id = $1 and read_at is null`,
		walletID).Scan(&unread)
	return out, unread, err
}

// MarkAllRead marks every notification read.
func MarkAllRead(ctx context.Context, db ledger.DB, walletID int64, now time.Time) error {
	_, err := db.Exec(ctx, `update notifications set read_at = $2 where wallet_account_id = $1 and read_at is null`,
		walletID, now)
	return err
}

// Naira formats kobo as "₦1,234.50".
func Naira(kobo int64) string {
	neg := kobo < 0
	if neg {
		kobo = -kobo
	}
	whole := strconv.FormatInt(kobo/100, 10)
	var b strings.Builder
	for i, r := range whole {
		if i > 0 && (len(whole)-i)%3 == 0 {
			b.WriteByte(',')
		}
		b.WriteRune(r)
	}
	s := fmt.Sprintf("₦%s.%02d", b.String(), kobo%100)
	if neg {
		return "-" + s
	}
	return s
}
