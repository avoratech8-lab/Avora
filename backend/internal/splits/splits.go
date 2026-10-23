// Package splits asks friends on Avora for their share of a bill. Each
// person gets a request they can pay (an Avora transfer to whoever asked)
// or decline; the person who asked sees who has paid.
package splits

import (
	"context"
	"errors"
	"fmt"
	"regexp"
	"slices"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"avora/backend/internal/notify"
)

var (
	ErrInvalid  = errors.New("splits: invalid request")
	ErrNotFound = errors.New("splits: not found")
	ErrSettled  = errors.New("splits: already paid or declined")
)

// MaxPeople is how many people one split can ask.
const MaxPeople = 10

type Share struct {
	UserID   int64  `json:"-"`
	WalletID int64  `json:"-"`
	Name     string `json:"name"`
	Tag      string `json:"tag"`
	Amount   int64  `json:"amount"`
	Status   string `json:"status"` // pending, paid or declined
	You      bool   `json:"you"`
}

type Split struct {
	ID        string    `json:"id"`
	Title     string    `json:"title"`
	Total     int64     `json:"total"`
	Creator   string    `json:"creator"` // name (@tag)
	CreatorID int64     `json:"-"`
	Mine      bool      `json:"mine"` // the viewer asked
	Shares    []Share   `json:"shares"`
	Collected int64     `json:"collected"`
	CreatedAt time.Time `json:"created_at"`
	payTo     string
}

// PayTo is the @tag or phone number to pay the creator at.
func (sp Split) PayTo() string { return sp.payTo }

// Request is one person to ask and how much.
type Request struct {
	UserID   int64
	WalletID int64
	Amount   int64
}

type Service struct {
	db *pgxpool.Pool
}

func NewService(db *pgxpool.Pool) *Service { return &Service{db: db} }

func who(name, tag string) string {
	if tag != "" {
		return fmt.Sprintf("%s (@%s)", name, tag)
	}
	return name
}

// Create asks each person for their share and notifies them. total is the
// whole bill, including the creator's own part.
func (s *Service) Create(ctx context.Context, creator int64, title string, total int64, asks []Request) (Split, error) {
	title = strings.Join(strings.Fields(title), " ")
	if n := len([]rune(title)); n == 0 || n > 40 {
		return Split{}, fmt.Errorf("%w: what's it for? (up to 40 characters)", ErrInvalid)
	}
	if len(asks) == 0 || len(asks) > MaxPeople {
		return Split{}, fmt.Errorf("%w: ask 1 to %d people", ErrInvalid, MaxPeople)
	}
	var sum int64
	seen := map[int64]bool{}
	for _, a := range asks {
		if a.Amount <= 0 {
			return Split{}, fmt.Errorf("%w: every share must be more than ₦0", ErrInvalid)
		}
		if seen[a.UserID] || a.UserID == creator {
			return Split{}, fmt.Errorf("%w: each person can be asked once", ErrInvalid)
		}
		seen[a.UserID] = true
		sum += a.Amount
	}
	if total <= 0 || sum > total {
		return Split{}, fmt.Errorf("%w: the shares add up to more than the bill", ErrInvalid)
	}

	tx, err := s.db.Begin(ctx)
	if err != nil {
		return Split{}, err
	}
	defer tx.Rollback(ctx)
	var id, name, tag string
	if err := tx.QueryRow(ctx, `select name, coalesce(tag, '') from users where id = $1`, creator).
		Scan(&name, &tag); err != nil {
		return Split{}, err
	}
	if err := tx.QueryRow(ctx, `insert into splits (creator_user_id, title, total) values ($1, $2, $3) returning id`,
		creator, title, total).Scan(&id); err != nil {
		return Split{}, err
	}
	for _, a := range asks {
		if _, err := tx.Exec(ctx, `insert into split_shares (split_id, user_id, amount) values ($1, $2, $3)`,
			id, a.UserID, a.Amount); err != nil {
			return Split{}, err
		}
		if err := notify.Add(ctx, tx, a.WalletID, "split", fmt.Sprintf("%s asked you for %s", who(name, tag),
			notify.Naira(a.Amount)), fmt.Sprintf("For %s. Open it to pay or decline.", title), id); err != nil {
			return Split{}, err
		}
	}
	if err := tx.Commit(ctx); err != nil {
		return Split{}, err
	}
	return s.Get(ctx, creator, id)
}

var uuidRe = regexp.MustCompile(`^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$`)

// Get returns a split the viewer asked for or was asked in.
func (s *Service) Get(ctx context.Context, viewer int64, id string) (Split, error) {
	if !uuidRe.MatchString(id) {
		return Split{}, ErrNotFound
	}
	var sp Split
	var name, tag, phone string
	err := s.db.QueryRow(ctx, `
		select s.id, s.title, s.total, s.creator_user_id, u.name, coalesce(u.tag, ''), u.phone, s.created_at
		from splits s join users u on u.id = s.creator_user_id where s.id = $1`, id).
		Scan(&sp.ID, &sp.Title, &sp.Total, &sp.CreatorID, &name, &tag, &phone, &sp.CreatedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return Split{}, ErrNotFound
	}
	if err != nil {
		return Split{}, err
	}
	sp.Creator = who(name, tag)
	sp.payTo = phone
	if tag != "" {
		sp.payTo = "@" + tag
	}
	sp.Mine = sp.CreatorID == viewer
	rows, err := s.db.Query(ctx, `
		select x.user_id, u.wallet_account_id, u.name, coalesce(u.tag, ''), x.amount, x.status
		from split_shares x join users u on u.id = x.user_id where x.split_id = $1 order by x.amount desc, u.name`, id)
	if err != nil {
		return Split{}, err
	}
	sp.Shares, err = pgx.CollectRows(rows, func(r pgx.CollectableRow) (Share, error) {
		var x Share
		err := r.Scan(&x.UserID, &x.WalletID, &x.Name, &x.Tag, &x.Amount, &x.Status)
		x.You = x.UserID == viewer
		return x, err
	})
	if err != nil {
		return Split{}, err
	}
	asked := false
	for _, x := range sp.Shares {
		asked = asked || x.You
		if x.Status == "paid" {
			sp.Collected += x.Amount
		}
	}
	if !sp.Mine && !asked {
		return Split{}, ErrNotFound
	}
	return sp, nil
}

// List returns splits the viewer made or was asked in, newest first.
func (s *Service) List(ctx context.Context, viewer int64) ([]Split, error) {
	rows, err := s.db.Query(ctx, `
		select id from splits where creator_user_id = $1
		union
		select split_id from split_shares where user_id = $1`, viewer)
	if err != nil {
		return nil, err
	}
	ids, err := pgx.CollectRows(rows, pgx.RowTo[string])
	if err != nil {
		return nil, err
	}
	out := []Split{}
	for _, id := range ids {
		sp, err := s.Get(ctx, viewer, id)
		if err != nil {
			return nil, err
		}
		out = append(out, sp)
	}
	slices.SortFunc(out, func(a, b Split) int { return b.CreatedAt.Compare(a.CreatedAt) })
	return out, nil
}

// MyShare returns what the viewer owes in a split, while it's still
// pending.
func (s *Service) MyShare(ctx context.Context, viewer int64, id string) (Split, Share, error) {
	sp, err := s.Get(ctx, viewer, id)
	if err != nil {
		return Split{}, Share{}, err
	}
	for _, x := range sp.Shares {
		if x.You {
			if x.Status != "pending" {
				return Split{}, Share{}, ErrSettled
			}
			return sp, x, nil
		}
	}
	return Split{}, Share{}, ErrNotFound
}

// Paid marks the viewer's share paid by an Avora transfer, and tells the
// creator.
func (s *Service) Paid(ctx context.Context, viewer int64, id, p2pID string) (Split, error) {
	return s.settle(ctx, viewer, id, "paid", p2pID)
}

// Decline marks the viewer's share declined, and tells the creator.
func (s *Service) Decline(ctx context.Context, viewer int64, id string) (Split, error) {
	return s.settle(ctx, viewer, id, "declined", "")
}

func (s *Service) settle(ctx context.Context, viewer int64, id, status, p2pID string) (Split, error) {
	sp, me, err := s.MyShare(ctx, viewer, id)
	if err != nil {
		return Split{}, err
	}
	tx, err := s.db.Begin(ctx)
	if err != nil {
		return Split{}, err
	}
	defer tx.Rollback(ctx)
	tag, err := tx.Exec(ctx, `update split_shares set status = $3, p2p_id = nullif($4, '')::uuid, updated_at = now()
		where split_id = $1 and user_id = $2 and status = 'pending'`, id, viewer, status, p2pID)
	if err != nil {
		return Split{}, err
	}
	if tag.RowsAffected() == 0 {
		return Split{}, ErrSettled
	}
	var creatorWallet int64
	if err := tx.QueryRow(ctx, `select wallet_account_id from users where id = $1`, sp.CreatorID).
		Scan(&creatorWallet); err != nil {
		return Split{}, err
	}
	title := fmt.Sprintf("%s paid their share", who(me.Name, me.Tag))
	if status == "declined" {
		title = fmt.Sprintf("%s declined their share", who(me.Name, me.Tag))
	}
	if err := notify.Add(ctx, tx, creatorWallet, "split", title,
		fmt.Sprintf("%s for %s.", notify.Naira(me.Amount), sp.Title), id); err != nil {
		return Split{}, err
	}
	if err := tx.Commit(ctx); err != nil {
		return Split{}, err
	}
	return s.Get(ctx, viewer, id)
}
