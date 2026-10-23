package api_test

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"regexp"
	"sync"
	"testing"

	"golang.org/x/crypto/bcrypt"

	"avora/backend/internal/api"
	"avora/backend/internal/auth"
	"avora/backend/internal/rails"
	"avora/backend/internal/testdb"
	"avora/backend/internal/transfers"
	"avora/backend/internal/wallets"
)

const (
	secret = "test-secret"
	opsKey = "ops-key-ops-key-ops-key-ops-key-1"
)

type fakeSMS struct {
	mu   sync.Mutex
	last string
}

func (f *fakeSMS) Send(_ context.Context, _, msg string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.last = regexp.MustCompile(`\d{6}`).FindString(msg)
	return nil
}

type client struct {
	t      *testing.T
	srv    *httptest.Server
	sms    *fakeSMS
	token  string
	device string
}

func newServer(t *testing.T) (*httptest.Server, *fakeSMS) {
	t.Helper()
	ctx := context.Background()
	pool := testdb.New(t)
	sys, err := wallets.LoadSystem(ctx, pool)
	if err != nil {
		t.Fatal(err)
	}
	rail := rails.NewSandbox()
	tcfg := transfers.DefaultConfig()
	tcfg.FreeTransfersPerMonth = 0
	acfg := auth.DefaultConfig([]byte("auth-secret-auth-secret-auth-secret"))
	acfg.BcryptCost = bcrypt.MinCost
	sms := &fakeSMS{}
	nubans := []string{"9000000001", "9000000002"}
	s := &api.Server{
		DB: pool, Rail: rail, System: sys,
		Transfers: transfers.NewService(pool, rail, sys, tcfg),
		Auth: auth.NewService(pool, sms, acfg, func(context.Context, string) (string, error) {
			n := nubans[0]
			nubans = nubans[1:]
			return n, nil
		}),
		WebhookSecret: secret,
		OpsKey:        opsKey,
		Log:           slog.New(slog.NewTextHandler(io.Discard, nil)),
	}
	srv := httptest.NewServer(s.Handler())
	t.Cleanup(srv.Close)
	return srv, sms
}

func (c *client) call(method, path string, body any, headers map[string]string) (int, map[string]any) {
	c.t.Helper()
	var buf bytes.Buffer
	if body != nil {
		json.NewEncoder(&buf).Encode(body)
	}
	req, _ := http.NewRequest(method, c.srv.URL+path, &buf)
	if c.device != "" {
		req.Header.Set("X-Device-ID", c.device)
	}
	if c.token != "" {
		req.Header.Set("Authorization", "Bearer "+c.token)
	}
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		c.t.Fatal(err)
	}
	defer resp.Body.Close()
	var out map[string]any
	json.NewDecoder(resp.Body).Decode(&out)
	return resp.StatusCode, out
}

func (c *client) signIn(phone, pin string) map[string]any {
	c.t.Helper()
	code, ch := c.call("POST", "/v1/auth/otp", map[string]string{"phone": phone}, nil)
	if code != http.StatusOK {
		c.t.Fatalf("otp: %d %v", code, ch)
	}
	code, s := c.call("POST", "/v1/auth/verify", map[string]string{
		"challenge_id": ch["challenge_id"].(string), "code": c.sms.last, "pin": pin}, nil)
	if code != http.StatusOK {
		c.t.Fatalf("verify: %d %v", code, s)
	}
	c.token = s["token"].(string)
	return s
}

func credit(t *testing.T, srv *httptest.Server, session, nuban string, amount int64) {
	t.Helper()
	body, _ := json.Marshal(map[string]any{"session_id": session, "account_number": nuban, "amount": amount, "sender_name": "TUNDE"})
	req, _ := http.NewRequest("POST", srv.URL+"/v1/webhooks/inbound-credit", bytes.NewReader(body))
	req.Header.Set("X-Signature", api.Sign(secret, body))
	resp, err := http.DefaultClient.Do(req)
	if err != nil || resp.StatusCode != http.StatusOK {
		t.Fatalf("credit: %v %v", resp.StatusCode, err)
	}
	resp.Body.Close()
}

func TestSignUpFundAndTransfer(t *testing.T) {
	srv, sms := newServer(t)
	ada := &client{t: t, srv: srv, sms: sms, device: "ada-phone"}

	if code, _ := ada.call("GET", "/v1/me/wallet", nil, nil); code != http.StatusUnauthorized {
		t.Errorf("wallet before sign-in: %d", code)
	}
	ada.signIn("08031234567", "482915")

	code, w := ada.call("GET", "/v1/me/wallet", nil, nil)
	if code != http.StatusOK || w["account_number"] != "9000000001" {
		t.Fatalf("wallet: %d %v", code, w)
	}

	// An unsigned webhook is rejected; a signed one credits the wallet.
	if code, _ := (&client{t: t, srv: srv}).call("POST", "/v1/webhooks/inbound-credit",
		map[string]any{"session_id": "S0", "account_number": "9000000001", "amount": 1}, nil); code != http.StatusUnauthorized {
		t.Errorf("unsigned webhook: %d", code)
	}
	credit(t, srv, "S1", "9000000001", 20_000_00)

	code, ne := ada.call("POST", "/v1/name-enquiry", map[string]string{"bank_code": "058", "account_number": "0123456781"}, nil)
	if code != http.StatusOK || ne["account_name"] == "" {
		t.Fatalf("name enquiry: %d %v", code, ne)
	}

	code, q := ada.call("GET", "/v1/transfers/quote?amount=500000", nil, nil)
	if code != http.StatusOK || q["fee"] != float64(10_00) || q["total"] != float64(5_010_00) {
		t.Fatalf("quote: %d %v", code, q)
	}

	body := map[string]any{"bank_code": "058", "account_number": "0123456781", "amount": 5_000_00, "pin": "000001"}
	if code, e := ada.call("POST", "/v1/transfers", body, map[string]string{"Idempotency-Key": "t1"}); code != http.StatusUnauthorized {
		t.Errorf("wrong PIN: %d %v", code, e)
	}
	body["pin"] = "482915"
	code, tr := ada.call("POST", "/v1/transfers", body, map[string]string{"Idempotency-Key": "t1"})
	if code != http.StatusOK || tr["status"] != "delivered" {
		t.Fatalf("transfer: %d %v", code, tr)
	}
	transferID := tr["id"].(string)

	// Sandbox declines account numbers ending in 0: money comes back.
	body["account_number"] = "0123456780"
	code, tr = ada.call("POST", "/v1/transfers", body, map[string]string{"Idempotency-Key": "t2"})
	if code != http.StatusOK || tr["status"] != "refunded" {
		t.Fatalf("declined transfer: %d %v", code, tr)
	}

	_, w = ada.call("GET", "/v1/me/wallet", nil, nil)
	if want := float64(20_000_00 - 50_00 - 5_000_00 - 10_00); w["balance"] != want {
		t.Errorf("balance = %v, want %v", w["balance"], want)
	}
	if code, st := ada.call("GET", "/v1/me/statement", nil, nil); code != http.StatusOK || len(st["lines"].([]any)) != 4 {
		t.Errorf("statement: %d %v", code, st)
	}

	body["amount"] = 1_000_000_00
	if code, _ := ada.call("POST", "/v1/transfers", body, map[string]string{"Idempotency-Key": "t3"}); code != http.StatusUnprocessableEntity {
		t.Errorf("overspend: %d", code)
	}

	// Another user can't see Ada's transfer, and Ada's token fails on another phone.
	bola := &client{t: t, srv: srv, sms: sms, device: "bola-phone"}
	bola.signIn("08099999999", "570264")
	if code, _ := bola.call("GET", "/v1/transfers/"+transferID, nil, nil); code != http.StatusNotFound {
		t.Errorf("other user's transfer: %d", code)
	}
	stolen := &client{t: t, srv: srv, token: ada.token, device: "thief-phone"}
	if code, _ := stolen.call("GET", "/v1/me/wallet", nil, nil); code != http.StatusUnauthorized {
		t.Errorf("token on another device: %d", code)
	}
}

func TestNewDeviceLimit(t *testing.T) {
	srv, sms := newServer(t)
	first := &client{t: t, srv: srv, sms: sms, device: "old-phone"}
	first.signIn("08031234567", "482915")
	credit(t, srv, "S1", "9000000001", 100_000_00)

	newPhone := &client{t: t, srv: srv, sms: sms, device: "new-phone"}
	s := newPhone.signIn("08031234567", "482915")
	if s["new_device"] != true {
		t.Fatalf("session = %v", s)
	}
	body := map[string]any{"bank_code": "058", "account_number": "0123456781", "amount": 15_000_00, "pin": "482915"}
	if code, tr := newPhone.call("POST", "/v1/transfers", body, map[string]string{"Idempotency-Key": "a"}); code != http.StatusOK {
		t.Fatalf("first transfer: %d %v", code, tr)
	}
	body["amount"] = 6_000_00
	if code, e := newPhone.call("POST", "/v1/transfers", body, map[string]string{"Idempotency-Key": "b"}); code != http.StatusForbidden {
		t.Errorf("over new-device limit: %d %v", code, e)
	}
	// The original phone is not limited.
	body["amount"] = 50_000_00
	if code, e := first.call("POST", "/v1/transfers", body, map[string]string{"Idempotency-Key": "c"}); code != http.StatusOK {
		t.Errorf("old phone transfer: %d %v", code, e)
	}
}

func TestOpsRoutesNeedKey(t *testing.T) {
	srv, _ := newServer(t)
	c := &client{t: t, srv: srv}
	path := "/v1/ops/transfers/00000000-0000-0000-0000-000000000000/resolve"
	if code, _ := c.call("POST", path, map[string]string{"outcome": "refunded"}, nil); code != http.StatusUnauthorized {
		t.Errorf("no key: %d", code)
	}
	if code, _ := c.call("POST", path, map[string]string{"outcome": "refunded"}, map[string]string{"X-Ops-Key": opsKey}); code != http.StatusNotFound {
		t.Errorf("with key: %d", code)
	}
}
