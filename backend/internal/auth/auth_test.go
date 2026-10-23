package auth

import (
	"context"
	"errors"
	"regexp"
	"sync"
	"testing"
	"time"

	"golang.org/x/crypto/bcrypt"

	"avora/backend/internal/testdb"
)

type fakeSMS struct {
	mu   sync.Mutex
	last map[string]string
}

var codeRe = regexp.MustCompile(`\d{6}`)

func (f *fakeSMS) Send(_ context.Context, phone, msg string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.last[phone] = codeRe.FindString(msg)
	return nil
}

type env struct {
	ctx   context.Context
	svc   *Service
	sms   *fakeSMS
	clock time.Time
}

func setup(t *testing.T) *env {
	t.Helper()
	pool := testdb.New(t)
	cfg := DefaultConfig([]byte("test-secret-test-secret-test-secret"))
	cfg.BcryptCost = bcrypt.MinCost
	e := &env{ctx: context.Background(), sms: &fakeSMS{last: map[string]string{}},
		clock: time.Date(2026, 10, 23, 9, 0, 0, 0, time.UTC)}
	n := 0
	e.svc = NewService(pool, e.sms, cfg, func(context.Context, string) (string, error) {
		n++
		return []string{"9000000001", "9000000002", "9000000003"}[n-1], nil
	})
	e.svc.now = func() time.Time { return e.clock }
	return e
}

func (e *env) signIn(t *testing.T, phone, device, pin string) (Session, error) {
	t.Helper()
	id, err := e.svc.StartOTP(e.ctx, phone)
	if err != nil {
		t.Fatal(err)
	}
	norm, _ := NormalizePhone(phone)
	return e.svc.Verify(e.ctx, VerifyRequest{ChallengeID: id, Code: e.sms.last[norm], DeviceID: device, PIN: pin})
}

func TestNormalizePhone(t *testing.T) {
	for in, want := range map[string]string{
		"08031234567":       "+2348031234567",
		"+234 803 123 4567": "+2348031234567",
		"2347031234567":     "+2347031234567",
		"09031234567":       "+2349031234567",
	} {
		if got, err := NormalizePhone(in); err != nil || got != want {
			t.Errorf("NormalizePhone(%q) = %q, %v; want %q", in, got, err, want)
		}
	}
	for _, bad := range []string{"", "0803123456", "05031234567", "+1 415 555 0100", "0803123456x"} {
		if _, err := NormalizePhone(bad); err == nil {
			t.Errorf("NormalizePhone(%q) accepted", bad)
		}
	}
}

func TestValidPIN(t *testing.T) {
	for pin, want := range map[string]bool{
		"482915": true, "000000": false, "111111": false, "123456": false,
		"654321": false, "12345": false, "12a456": false, "1234567": false,
	} {
		if got := ValidPIN(pin); got != want {
			t.Errorf("ValidPIN(%q) = %v", pin, got)
		}
	}
}

func TestSignUpThenSignInOnSameDevice(t *testing.T) {
	e := setup(t)
	s, err := e.signIn(t, "08031234567", "phone-a", "482915")
	if err != nil {
		t.Fatal(err)
	}
	if !s.NewUser || s.NewDevice || s.Token == "" || s.WalletID == 0 {
		t.Fatalf("first session = %+v", s)
	}
	p, err := e.svc.Authenticate(e.ctx, s.Token, "phone-a")
	if err != nil || p.WalletID != s.WalletID || !p.FirstDevice {
		t.Fatalf("authenticate = %+v %v", p, err)
	}

	again, err := e.signIn(t, "+2348031234567", "phone-a", "482915")
	if err != nil || again.NewUser || again.NewDevice || again.WalletID != s.WalletID {
		t.Fatalf("second sign-in = %+v %v", again, err)
	}
}

func TestTokenOnlyWorksFromItsDevice(t *testing.T) {
	e := setup(t)
	s, _ := e.signIn(t, "08031234567", "phone-a", "482915")
	if _, err := e.svc.Authenticate(e.ctx, s.Token, "phone-b"); !errors.Is(err, ErrUnauthorized) {
		t.Errorf("other device err = %v", err)
	}
	if _, err := e.svc.Authenticate(e.ctx, "made-up", "phone-a"); !errors.Is(err, ErrUnauthorized) {
		t.Errorf("bad token err = %v", err)
	}
	e.svc.Logout(e.ctx, s.Token)
	if _, err := e.svc.Authenticate(e.ctx, s.Token, "phone-a"); !errors.Is(err, ErrUnauthorized) {
		t.Errorf("after logout err = %v", err)
	}
}

func TestSessionExpires(t *testing.T) {
	e := setup(t)
	s, _ := e.signIn(t, "08031234567", "phone-a", "482915")
	e.clock = e.clock.Add(31 * 24 * time.Hour)
	if _, err := e.svc.Authenticate(e.ctx, s.Token, "phone-a"); !errors.Is(err, ErrUnauthorized) {
		t.Errorf("expired session err = %v", err)
	}
}

func TestNewDeviceIsMarked(t *testing.T) {
	e := setup(t)
	e.signIn(t, "08031234567", "phone-a", "482915")
	e.clock = e.clock.Add(time.Hour)
	s, err := e.signIn(t, "08031234567", "phone-b", "482915")
	if err != nil || !s.NewDevice {
		t.Fatalf("new device session = %+v %v", s, err)
	}
	p, _ := e.svc.Authenticate(e.ctx, s.Token, "phone-b")
	ends := p.NewDeviceWindowEnds(e.svc.Config())
	if p.FirstDevice || !ends.Equal(e.clock.Add(24*time.Hour)) {
		t.Errorf("principal = %+v, window ends %v", p, ends)
	}
}

func TestWeakPINRejectedAtSignUp(t *testing.T) {
	e := setup(t)
	if _, err := e.signIn(t, "08031234567", "phone-a", "123456"); !errors.Is(err, ErrWeakPIN) {
		t.Errorf("err = %v", err)
	}
}

func TestWrongCodeAttemptsAreLimited(t *testing.T) {
	e := setup(t)
	id, _ := e.svc.StartOTP(e.ctx, "08031234567")
	right := e.sms.last["+2348031234567"]
	wrong := "000000"
	if wrong == right {
		wrong = "111111"
	}
	for range 5 {
		if _, err := e.svc.Verify(e.ctx, VerifyRequest{ChallengeID: id, Code: wrong, DeviceID: "d", PIN: "482915"}); !errors.Is(err, ErrInvalidCode) {
			t.Fatalf("wrong code err = %v", err)
		}
	}
	// Even the right code is refused once attempts run out.
	if _, err := e.svc.Verify(e.ctx, VerifyRequest{ChallengeID: id, Code: right, DeviceID: "d", PIN: "482915"}); !errors.Is(err, ErrInvalidCode) {
		t.Errorf("right code after lockout err = %v", err)
	}
}

func TestCodeExpiresAndIsSingleUse(t *testing.T) {
	e := setup(t)
	id, _ := e.svc.StartOTP(e.ctx, "08031234567")
	code := e.sms.last["+2348031234567"]
	e.clock = e.clock.Add(6 * time.Minute)
	if _, err := e.svc.Verify(e.ctx, VerifyRequest{ChallengeID: id, Code: code, DeviceID: "d", PIN: "482915"}); !errors.Is(err, ErrInvalidCode) {
		t.Errorf("expired code err = %v", err)
	}

	id, _ = e.svc.StartOTP(e.ctx, "08031234567")
	code = e.sms.last["+2348031234567"]
	if _, err := e.svc.Verify(e.ctx, VerifyRequest{ChallengeID: id, Code: code, DeviceID: "d", PIN: "482915"}); err != nil {
		t.Fatal(err)
	}
	if _, err := e.svc.Verify(e.ctx, VerifyRequest{ChallengeID: id, Code: code, DeviceID: "d", PIN: "482915"}); !errors.Is(err, ErrInvalidCode) {
		t.Errorf("reused code err = %v", err)
	}
}

func TestOTPSendsAreRateLimited(t *testing.T) {
	e := setup(t)
	for range 3 {
		if _, err := e.svc.StartOTP(e.ctx, "08031234567"); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := e.svc.StartOTP(e.ctx, "08031234567"); !errors.Is(err, ErrTooManyRequests) {
		t.Errorf("4th code err = %v", err)
	}
	e.clock = e.clock.Add(11 * time.Minute)
	if _, err := e.svc.StartOTP(e.ctx, "08031234567"); err != nil {
		t.Errorf("after window err = %v", err)
	}
}

func TestPINLockout(t *testing.T) {
	e := setup(t)
	s, _ := e.signIn(t, "08031234567", "phone-a", "482915")
	for i := range 4 {
		if err := e.svc.CheckPIN(e.ctx, s.UserID, "999999"); !errors.Is(err, ErrWrongPIN) {
			t.Fatalf("attempt %d err = %v", i+1, err)
		}
	}
	// A right PIN resets the count.
	if err := e.svc.CheckPIN(e.ctx, s.UserID, "482915"); err != nil {
		t.Fatal(err)
	}
	for range 5 {
		e.svc.CheckPIN(e.ctx, s.UserID, "999999")
	}
	if err := e.svc.CheckPIN(e.ctx, s.UserID, "482915"); !errors.Is(err, ErrLocked) {
		t.Errorf("locked err = %v", err)
	}
	e.clock = e.clock.Add(31 * time.Minute)
	if err := e.svc.CheckPIN(e.ctx, s.UserID, "482915"); err != nil {
		t.Errorf("after lockout err = %v", err)
	}
}

func TestWrongPINOnSignInFromNewDevice(t *testing.T) {
	e := setup(t)
	e.signIn(t, "08031234567", "phone-a", "482915")
	if _, err := e.signIn(t, "08031234567", "phone-b", "999999"); !errors.Is(err, ErrWrongPIN) {
		t.Errorf("err = %v", err)
	}
}
