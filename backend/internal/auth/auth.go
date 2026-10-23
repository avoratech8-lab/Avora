// Package auth signs users up and in with a phone OTP plus a 6-digit PIN,
// binds each session to one device, and checks the PIN for every transfer.
package auth

import (
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"math/big"
	"regexp"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"golang.org/x/crypto/bcrypt"

	"avora/backend/internal/wallets"
)

var (
	ErrInvalidPhone    = errors.New("auth: enter a valid Nigerian phone number")
	ErrInvalidCode     = errors.New("auth: that code is wrong or has expired")
	ErrTooManyRequests = errors.New("auth: too many codes requested; wait a few minutes")
	ErrWeakPIN         = errors.New("auth: PIN must be 6 digits and not repeated or in sequence")
	ErrWrongPIN        = errors.New("auth: wrong PIN")
	ErrLocked          = errors.New("auth: too many wrong PINs; try again later")
	ErrUnauthorized    = errors.New("auth: not signed in")
	ErrInvalidDevice   = errors.New("auth: device id is required")
)

// SMS delivers one-time codes. Production uses an SMS/WhatsApp provider.
type SMS interface {
	Send(ctx context.Context, phone, message string) error
}

type Config struct {
	Secret          []byte // HMAC key for OTP hashes; keep it out of the database
	OTPTTL          time.Duration
	OTPMaxAttempts  int
	OTPSendLimit    int // codes per phone per OTPSendWindow
	OTPSendWindow   time.Duration
	PINMaxAttempts  int
	PINLockout      time.Duration
	SessionTTL      time.Duration
	BcryptCost      int
	NewDeviceWindow time.Duration
	NewDeviceLimit  int64 // kobo a new device may send during NewDeviceWindow
}

func DefaultConfig(secret []byte) Config {
	return Config{
		Secret:          secret,
		OTPTTL:          5 * time.Minute,
		OTPMaxAttempts:  5,
		OTPSendLimit:    3,
		OTPSendWindow:   10 * time.Minute,
		PINMaxAttempts:  5,
		PINLockout:      30 * time.Minute,
		SessionTTL:      30 * 24 * time.Hour,
		BcryptCost:      12,
		NewDeviceWindow: 24 * time.Hour,
		NewDeviceLimit:  20_000_00,
	}
}

type Service struct {
	db       *pgxpool.Pool
	sms      SMS
	cfg      Config
	newNUBAN func(ctx context.Context, userRef string) (string, error)
	now      func() time.Time
}

func NewService(db *pgxpool.Pool, sms SMS, cfg Config, newNUBAN func(context.Context, string) (string, error)) *Service {
	return &Service{db: db, sms: sms, cfg: cfg, newNUBAN: newNUBAN, now: time.Now}
}

var (
	digitsRe = regexp.MustCompile(`^\d+$`)
	uuidRe   = regexp.MustCompile(`^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$`)
)

// NormalizePhone accepts 0803..., 234803... or +234803... and returns +234803....
func NormalizePhone(s string) (string, error) {
	s = strings.NewReplacer(" ", "", "-", "", "(", "", ")", "").Replace(s)
	s = strings.TrimPrefix(s, "+")
	switch {
	case strings.HasPrefix(s, "234") && len(s) == 13:
		s = s[3:]
	case strings.HasPrefix(s, "0") && len(s) == 11:
		s = s[1:]
	}
	if len(s) != 10 || !digitsRe.MatchString(s) || !strings.ContainsAny(s[:1], "789") {
		return "", ErrInvalidPhone
	}
	return "+234" + s, nil
}

// ValidPIN rejects PINs that are easy to guess.
func ValidPIN(pin string) bool {
	if len(pin) != 6 || !digitsRe.MatchString(pin) {
		return false
	}
	same, up, down := true, true, true
	for i := 1; i < len(pin); i++ {
		d := int(pin[i]) - int(pin[i-1])
		same = same && d == 0
		up = up && d == 1
		down = down && d == -1
	}
	return !same && !up && !down
}

// StartOTP texts a code to the phone and returns the challenge id.
func (s *Service) StartOTP(ctx context.Context, rawPhone string) (string, error) {
	phone, err := NormalizePhone(rawPhone)
	if err != nil {
		return "", err
	}
	now := s.now()
	var recent int
	if err := s.db.QueryRow(ctx, `select count(*) from otp_challenges where phone = $1 and created_at > $2`,
		phone, now.Add(-s.cfg.OTPSendWindow)).Scan(&recent); err != nil {
		return "", err
	}
	if recent >= s.cfg.OTPSendLimit {
		return "", ErrTooManyRequests
	}

	n, err := rand.Int(rand.Reader, big.NewInt(1_000_000))
	if err != nil {
		return "", err
	}
	code := fmt.Sprintf("%06d", n.Int64())

	var id string
	if err := s.db.QueryRow(ctx, `
		insert into otp_challenges (phone, code_hash, expires_at, created_at)
		values ($1, $2, $3, $4) returning id`,
		phone, s.hashCode(phone, code), now.Add(s.cfg.OTPTTL), now).Scan(&id); err != nil {
		return "", err
	}
	msg := fmt.Sprintf("Your Avora code is %s. It expires in %d minutes. Never share it, not even with Avora staff.",
		code, int(s.cfg.OTPTTL.Minutes()))
	if err := s.sms.Send(ctx, phone, msg); err != nil {
		return "", fmt.Errorf("auth: send code: %w", err)
	}
	return id, nil
}

func (s *Service) hashCode(phone, code string) string {
	mac := hmac.New(sha256.New, s.cfg.Secret)
	mac.Write([]byte(phone + ":" + code))
	return hex.EncodeToString(mac.Sum(nil))
}

type VerifyRequest struct {
	ChallengeID string
	Code        string
	DeviceID    string
	PIN         string // sets the PIN for a new user, checks it for an existing one
}

type Session struct {
	Token     string `json:"token"`
	UserID    int64  `json:"user_id"`
	WalletID  int64  `json:"wallet_id"`
	NewUser   bool   `json:"new_user"`
	NewDevice bool   `json:"new_device"`
}

// Verify checks the code and PIN, creates the user and wallet on first
// sign-in, binds the device and returns a session token.
func (s *Service) Verify(ctx context.Context, req VerifyRequest) (Session, error) {
	if req.DeviceID == "" || len(req.DeviceID) > 200 {
		return Session{}, ErrInvalidDevice
	}
	phone, err := s.consumeOTP(ctx, req.ChallengeID, req.Code)
	if err != nil {
		return Session{}, err
	}

	var userID, walletID int64
	err = s.db.QueryRow(ctx, `select id, wallet_account_id from users where phone = $1`, phone).Scan(&userID, &walletID)
	newUser := errors.Is(err, pgx.ErrNoRows)
	switch {
	case newUser:
		userID, walletID, err = s.createUser(ctx, phone, req.PIN)
	case err == nil:
		err = s.CheckPIN(ctx, userID, req.PIN)
	}
	if err != nil {
		return Session{}, err
	}

	newDevice, err := s.bindDevice(ctx, userID, req.DeviceID)
	if err != nil {
		return Session{}, err
	}
	token, err := s.createSession(ctx, userID, req.DeviceID)
	if err != nil {
		return Session{}, err
	}
	return Session{Token: token, UserID: userID, WalletID: walletID, NewUser: newUser, NewDevice: newDevice && !newUser}, nil
}

func (s *Service) consumeOTP(ctx context.Context, challengeID, code string) (string, error) {
	tx, err := s.db.Begin(ctx)
	if err != nil {
		return "", err
	}
	defer tx.Rollback(ctx)

	if !uuidRe.MatchString(challengeID) {
		return "", ErrInvalidCode
	}
	var phone, hash string
	var attempts int
	var expires time.Time
	var consumed *time.Time
	err = tx.QueryRow(ctx, `
		select phone, code_hash, attempts, expires_at, consumed_at
		from otp_challenges where id = $1 for update`, challengeID).
		Scan(&phone, &hash, &attempts, &expires, &consumed)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", ErrInvalidCode
	}
	if err != nil {
		return "", err
	}
	if consumed != nil || !s.now().Before(expires) || attempts >= s.cfg.OTPMaxAttempts {
		return "", ErrInvalidCode
	}
	if !hmac.Equal([]byte(hash), []byte(s.hashCode(phone, code))) {
		if _, err := tx.Exec(ctx, `update otp_challenges set attempts = attempts + 1 where id = $1`, challengeID); err != nil {
			return "", err
		}
		if err := tx.Commit(ctx); err != nil {
			return "", err
		}
		return "", ErrInvalidCode
	}
	if _, err := tx.Exec(ctx, `update otp_challenges set consumed_at = $2 where id = $1`, challengeID, s.now()); err != nil {
		return "", err
	}
	return phone, tx.Commit(ctx)
}

func (s *Service) createUser(ctx context.Context, phone, pin string) (int64, int64, error) {
	if !ValidPIN(pin) {
		return 0, 0, ErrWeakPIN
	}
	hash, err := bcrypt.GenerateFromPassword([]byte(pin), s.cfg.BcryptCost)
	if err != nil {
		return 0, 0, err
	}
	ref, err := randomRef()
	if err != nil {
		return 0, 0, err
	}
	nuban, err := s.newNUBAN(ctx, ref)
	if err != nil {
		return 0, 0, err
	}

	tx, err := s.db.Begin(ctx)
	if err != nil {
		return 0, 0, err
	}
	defer tx.Rollback(ctx)
	w, err := wallets.CreateTx(ctx, tx, ref, nuban)
	if err != nil {
		return 0, 0, err
	}
	var userID int64
	if err := tx.QueryRow(ctx, `
		insert into users (phone, pin_hash, wallet_account_id) values ($1, $2, $3) returning id`,
		phone, string(hash), w.AccountID).Scan(&userID); err != nil {
		return 0, 0, err
	}
	return userID, w.AccountID, tx.Commit(ctx)
}

func randomRef() (string, error) {
	b := make([]byte, 12)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return "u_" + hex.EncodeToString(b), nil
}

// CheckPIN verifies the user's PIN. Too many wrong tries lock the PIN.
func (s *Service) CheckPIN(ctx context.Context, userID int64, pin string) error {
	var hash string
	var locked *time.Time
	if err := s.db.QueryRow(ctx, `select pin_hash, locked_until from users where id = $1`, userID).
		Scan(&hash, &locked); err != nil {
		return err
	}
	now := s.now()
	if locked != nil && now.Before(*locked) {
		return ErrLocked
	}
	if bcrypt.CompareHashAndPassword([]byte(hash), []byte(pin)) != nil {
		_, err := s.db.Exec(ctx, `
			update users set
				failed_pin_attempts = case when failed_pin_attempts + 1 >= $2 then 0 else failed_pin_attempts + 1 end,
				locked_until = case when failed_pin_attempts + 1 >= $2 then $3::timestamptz else locked_until end
			where id = $1`, userID, s.cfg.PINMaxAttempts, now.Add(s.cfg.PINLockout))
		if err != nil {
			return err
		}
		return ErrWrongPIN
	}
	_, err := s.db.Exec(ctx, `update users set failed_pin_attempts = 0, locked_until = null where id = $1`, userID)
	return err
}

func (s *Service) bindDevice(ctx context.Context, userID int64, deviceID string) (bool, error) {
	tag, err := s.db.Exec(ctx, `
		insert into devices (user_id, device_id, first_device, bound_at)
		values ($1, $2, not exists (select 1 from devices where user_id = $1), $3)
		on conflict (user_id, device_id) do nothing`, userID, deviceID, s.now())
	if err != nil {
		return false, err
	}
	return tag.RowsAffected() == 1, nil
}

func (s *Service) createSession(ctx context.Context, userID int64, deviceID string) (string, error) {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	token := base64.RawURLEncoding.EncodeToString(b)
	_, err := s.db.Exec(ctx, `
		insert into sessions (token_hash, user_id, device_id, expires_at, created_at)
		values ($1, $2, $3, $4, $5)`, tokenHash(token), userID, deviceID, s.now().Add(s.cfg.SessionTTL), s.now())
	return token, err
}

func tokenHash(token string) string {
	sum := sha256.Sum256([]byte(token))
	return hex.EncodeToString(sum[:])
}

// Principal is the signed-in user behind a request.
type Principal struct {
	UserID        int64
	WalletID      int64
	DeviceID      string
	FirstDevice   bool
	DeviceBoundAt time.Time
}

// NewDeviceWindowEnds reports when this device's transfer cap lifts; the
// zero time means there is no cap.
func (p Principal) NewDeviceWindowEnds(cfg Config) time.Time {
	if p.FirstDevice {
		return time.Time{}
	}
	return p.DeviceBoundAt.Add(cfg.NewDeviceWindow)
}

// Authenticate resolves a bearer token sent from deviceID.
func (s *Service) Authenticate(ctx context.Context, token, deviceID string) (Principal, error) {
	if token == "" || deviceID == "" {
		return Principal{}, ErrUnauthorized
	}
	var p Principal
	err := s.db.QueryRow(ctx, `
		select s.user_id, u.wallet_account_id, s.device_id, d.first_device, d.bound_at
		from sessions s
		join users u on u.id = s.user_id
		join devices d on d.user_id = s.user_id and d.device_id = s.device_id
		where s.token_hash = $1 and s.device_id = $2 and s.expires_at > $3`,
		tokenHash(token), deviceID, s.now()).
		Scan(&p.UserID, &p.WalletID, &p.DeviceID, &p.FirstDevice, &p.DeviceBoundAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return Principal{}, ErrUnauthorized
	}
	return p, err
}

func (s *Service) Logout(ctx context.Context, token string) error {
	_, err := s.db.Exec(ctx, `delete from sessions where token_hash = $1`, tokenHash(token))
	return err
}

func (s *Service) Config() Config { return s.cfg }
