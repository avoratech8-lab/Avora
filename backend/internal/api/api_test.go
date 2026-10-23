package api_test

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"regexp"
	"strings"
	"sync"
	"testing"

	"golang.org/x/crypto/bcrypt"

	"avora/backend/internal/api"
	"avora/backend/internal/auth"
	"avora/backend/internal/bills"
	"avora/backend/internal/kyc"
	"avora/backend/internal/rails"
	"avora/backend/internal/savings"
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
	sav, err := savings.NewService(ctx, pool, savings.DefaultRates())
	if err != nil {
		t.Fatal(err)
	}
	s := &api.Server{
		Savings: sav,
		KYC:     kyc.NewService(pool, kyc.Sandbox{}),
		DB:      pool, Rail: rail, System: sys,
		Transfers: transfers.NewService(pool, rail, sys, tcfg),
		Bills:     bills.NewService(pool, bills.Sandbox{}, sys),
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

	// Within the daily limit but more than the balance.
	body["amount"] = 40_000_00
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
	// The original phone has no new-phone cap (only the daily tier limit).
	body["amount"] = 30_000_00
	if code, e := first.call("POST", "/v1/transfers", body, map[string]string{"Idempotency-Key": "c"}); code != http.StatusOK {
		t.Errorf("old phone transfer: %d %v", code, e)
	}
}

func TestBills(t *testing.T) {
	srv, sms := newServer(t)
	ada := &client{t: t, srv: srv, sms: sms, device: "ada-phone"}
	ada.signIn("08031234567", "482915")
	credit(t, srv, "S1", "9000000001", 9_000_00)

	code, list := ada.call("GET", "/v1/bills/billers", nil, nil)
	if code != http.StatusOK || len(list["billers"].([]any)) < 10 {
		t.Fatalf("billers: %d %v", code, list)
	}
	code, v := ada.call("POST", "/v1/bills/validate", map[string]string{"biller_id": "ikedc", "customer": "45123456781"}, nil)
	if code != http.StatusOK || v["customer_name"] == "" {
		t.Fatalf("validate: %d %v", code, v)
	}
	if code, _ := ada.call("POST", "/v1/bills/validate", map[string]string{"biller_id": "ikedc", "customer": "45123456788"}, nil); code != http.StatusNotFound {
		t.Errorf("unknown meter: %d", code)
	}

	body := map[string]any{"biller_id": "mtn-data", "plan_code": "mtn-2gb-7d", "customer": "08031234567", "pin": "000001"}
	if code, _ := ada.call("POST", "/v1/bills/payments", body, map[string]string{"Idempotency-Key": "b1"}); code != http.StatusUnauthorized {
		t.Errorf("wrong PIN: %d", code)
	}
	body["pin"] = "482915"
	code, pay := ada.call("POST", "/v1/bills/payments", body, map[string]string{"Idempotency-Key": "b1"})
	if code != http.StatusOK || pay["status"] != "success" || pay["amount"] != float64(1_500_00) {
		t.Fatalf("pay: %d %v", code, pay)
	}
	if code, again := ada.call("GET", "/v1/bills/payments/"+pay["id"].(string), nil, nil); code != http.StatusOK || again["id"] != pay["id"] {
		t.Errorf("get: %d %v", code, again)
	}
	_, w := ada.call("GET", "/v1/me/wallet", nil, nil)
	if w["balance"] != float64(7_500_00) {
		t.Errorf("balance = %v", w["balance"])
	}

	bola := &client{t: t, srv: srv, sms: sms, device: "bola-phone"}
	bola.signIn("08099999999", "570264")
	if code, _ := bola.call("GET", "/v1/bills/payments/"+pay["id"].(string), nil, nil); code != http.StatusNotFound {
		t.Errorf("other user's payment: %d", code)
	}
}

func TestNewDeviceLimitCountsBills(t *testing.T) {
	srv, sms := newServer(t)
	first := &client{t: t, srv: srv, sms: sms, device: "old-phone"}
	first.signIn("08031234567", "482915")
	credit(t, srv, "S1", "9000000001", 100_000_00)

	newPhone := &client{t: t, srv: srv, sms: sms, device: "new-phone"}
	newPhone.signIn("08031234567", "482915")
	tv := map[string]any{"biller_id": "dstv", "plan_code": "dstv-compact", "customer": "1234567891", "pin": "482915"}
	if code, e := newPhone.call("POST", "/v1/bills/payments", tv, map[string]string{"Idempotency-Key": "tv"}); code != http.StatusOK {
		t.Fatalf("tv: %d %v", code, e)
	}
	body := map[string]any{"bank_code": "058", "account_number": "0123456781", "amount": 2_000_00, "pin": "482915"}
	if code, e := newPhone.call("POST", "/v1/transfers", body, map[string]string{"Idempotency-Key": "t"}); code != http.StatusForbidden {
		t.Errorf("transfer over limit after bills: %d %v", code, e)
	}
	// The plan's price counts, whatever amount the client sends.
	tv["plan_code"], tv["amount"] = "dstv-premium", 1
	if code, e := newPhone.call("POST", "/v1/bills/payments", tv, map[string]string{"Idempotency-Key": "tv2"}); code != http.StatusForbidden {
		t.Errorf("premium over limit: %d %v", code, e)
	}
}

func TestSavings(t *testing.T) {
	srv, sms := newServer(t)
	ada := &client{t: t, srv: srv, sms: sms, device: "ada-phone"}
	ada.signIn("08031234567", "482915")
	credit(t, srv, "S1", "9000000001", 9_000_00)

	code, list := ada.call("GET", "/v1/savings", nil, nil)
	if code != http.StatusOK || len(list["pots"].([]any)) != 0 || list["rates"] == nil {
		t.Fatalf("list: %d %v", code, list)
	}
	code, pot := ada.call("POST", "/v1/savings", map[string]any{"kind": "goal", "name": "Laptop", "target": 500_000_00, "amount": 2_000_00},
		map[string]string{"Idempotency-Key": "p1"})
	if code != http.StatusOK || pot["balance"] != float64(2_000_00) {
		t.Fatalf("create: %d %v", code, pot)
	}
	id := pot["id"].(string)
	if code, pot = ada.call("POST", "/v1/savings/"+id+"/deposit", map[string]any{"amount": 1_000_00}, map[string]string{"Idempotency-Key": "d1"}); code != http.StatusOK || pot["balance"] != float64(3_000_00) {
		t.Fatalf("deposit: %d %v", code, pot)
	}
	if code, pot = ada.call("POST", "/v1/savings/"+id+"/withdraw", map[string]any{"amount": 500_00}, map[string]string{"Idempotency-Key": "w1"}); code != http.StatusOK || pot["balance"] != float64(2_500_00) {
		t.Fatalf("withdraw: %d %v", code, pot)
	}

	code, locked := ada.call("POST", "/v1/savings", map[string]any{"kind": "locked", "name": "Rent", "lock_days": 30, "amount": 5_000_00},
		map[string]string{"Idempotency-Key": "p2"})
	if code != http.StatusOK || locked["expected_rate_bps"] != float64(1000) {
		t.Fatalf("locked: %d %v", code, locked)
	}
	if code, e := ada.call("POST", "/v1/savings/"+locked["id"].(string)+"/withdraw", map[string]any{}, map[string]string{"Idempotency-Key": "w2"}); code != http.StatusConflict || e["error"].(map[string]any)["code"] != "savings_locked" {
		t.Errorf("early withdraw: %d %v", code, e)
	}

	ops := &client{t: t, srv: srv}
	body := map[string]any{"period": "2026-10", "goal_rate_bps": 800, "locked_rate_bps": 1000}
	if code, _ := ops.call("POST", "/v1/ops/savings/profit", body, nil); code != http.StatusUnauthorized {
		t.Errorf("profit without key: %d", code)
	}
	if code, run := ops.call("POST", "/v1/ops/savings/profit", body, map[string]string{"X-Ops-Key": opsKey}); code != http.StatusOK || run["pots"] != float64(2) {
		t.Errorf("profit: %d %v", code, run)
	}

	bola := &client{t: t, srv: srv, sms: sms, device: "bola-phone"}
	bola.signIn("08099999999", "570264")
	if code, _ := bola.call("POST", "/v1/savings/"+id+"/withdraw", map[string]any{"amount": 1}, map[string]string{"Idempotency-Key": "x"}); code != http.StatusNotFound {
		t.Errorf("other user's pot: %d", code)
	}
}

func TestKYCRaisesTheDailyLimit(t *testing.T) {
	srv, sms := newServer(t)
	ada := &client{t: t, srv: srv, sms: sms, device: "ada-phone"}
	ada.signIn("08031234567", "482915")
	credit(t, srv, "S1", "9000000001", 500_000_00)

	code, st := ada.call("GET", "/v1/me/kyc", nil, nil)
	if code != http.StatusOK || st["tier"] != float64(1) {
		t.Fatalf("kyc: %d %v", code, st)
	}
	body := map[string]any{"bank_code": "058", "account_number": "0123456781", "amount": 50_000_00, "pin": "482915"}
	if code, e := ada.call("POST", "/v1/transfers", body, map[string]string{"Idempotency-Key": "a"}); code != http.StatusOK {
		t.Fatalf("up to the limit: %d %v", code, e)
	}
	body["amount"] = 100
	if code, e := ada.call("POST", "/v1/transfers", body, map[string]string{"Idempotency-Key": "b"}); code != http.StatusForbidden ||
		e["error"].(map[string]any)["code"] != "daily_limit" {
		t.Fatalf("over tier 1: %d %v", code, e)
	}

	if code, e := ada.call("POST", "/v1/me/kyc", map[string]string{"type": "bvn", "number": "123"}, nil); code != http.StatusBadRequest ||
		e["error"].(map[string]any)["message"] != "BVN must be 11 digits." {
		t.Errorf("short bvn: %d %v", code, e)
	}
	if code, _ := ada.call("POST", "/v1/me/kyc", map[string]string{"type": "bvn", "number": "22212345670"}, nil); code != http.StatusUnprocessableEntity {
		t.Errorf("mismatched bvn: %d", code)
	}
	code, st = ada.call("POST", "/v1/me/kyc", map[string]string{"type": "bvn", "number": "22212345678"}, nil)
	if code != http.StatusOK || st["tier"] != float64(2) || st["bvn_verified"] != true {
		t.Fatalf("bvn: %d %v", code, st)
	}
	if code, e := ada.call("POST", "/v1/transfers", body, map[string]string{"Idempotency-Key": "b"}); code != http.StatusOK {
		t.Errorf("after tier 2: %d %v", code, e)
	}
	if _, st = ada.call("POST", "/v1/me/kyc", map[string]string{"type": "nin", "number": "12345678901"}, nil); st["tier"] != float64(3) {
		t.Errorf("nin: %v", st)
	}

	_, n := ada.call("GET", "/v1/me/notifications", nil, nil)
	titles := []string{}
	for _, x := range n["notifications"].([]any) {
		titles = append(titles, x.(map[string]any)["title"].(string))
	}
	want := []string{"You're now on Tier 3", "Transfer delivered", "You're now on Tier 2", "Transfer delivered", "₦499,950.00 received"}
	if strings.Join(titles, "|") != strings.Join(want, "|") || n["unread"] != float64(5) {
		t.Errorf("notifications = %v (unread %v)", titles, n["unread"])
	}
	if code, _ := ada.call("POST", "/v1/me/notifications/read", nil, nil); code != http.StatusNoContent {
		t.Errorf("read: %d", code)
	}
	if _, n = ada.call("GET", "/v1/me/notifications", nil, nil); n["unread"] != float64(0) {
		t.Errorf("unread after read = %v", n["unread"])
	}
}

func TestChangePINAndDevices(t *testing.T) {
	srv, sms := newServer(t)
	old := &client{t: t, srv: srv, sms: sms, device: "old-phone"}
	old.signIn("08031234567", "482915")
	thief := &client{t: t, srv: srv, sms: sms, device: "other-phone"}
	thief.signIn("08031234567", "482915")

	code, ds := old.call("GET", "/v1/me/devices", nil, nil)
	list := ds["devices"].([]any)
	if code != http.StatusOK || len(list) != 2 || list[0].(map[string]any)["this_phone"] != true {
		t.Fatalf("devices: %d %v", code, ds)
	}
	if code, _ := old.call("POST", "/v1/me/pin/verify", map[string]string{"pin": "482915"}, nil); code != http.StatusNoContent {
		t.Errorf("verify pin: %d", code)
	}
	if code, _ := old.call("POST", "/v1/me/pin", map[string]string{"old_pin": "000001", "new_pin": "582047"}, nil); code != http.StatusUnauthorized {
		t.Errorf("wrong old pin: %d", code)
	}
	if code, _ := old.call("POST", "/v1/me/pin", map[string]string{"old_pin": "482915", "new_pin": "123456"}, nil); code != http.StatusBadRequest {
		t.Errorf("weak new pin: %d", code)
	}
	if code, _ := old.call("POST", "/v1/me/pin", map[string]string{"old_pin": "482915", "new_pin": "582047"}, nil); code != http.StatusNoContent {
		t.Fatalf("change pin: %d", code)
	}
	// Changing the PIN signs out every other phone.
	if code, _ := thief.call("GET", "/v1/me/wallet", nil, nil); code != http.StatusUnauthorized {
		t.Errorf("other phone after PIN change: %d", code)
	}
	if code, _ := old.call("GET", "/v1/me/wallet", nil, nil); code != http.StatusOK {
		t.Errorf("this phone after PIN change: %d", code)
	}

	thief.signIn("08031234567", "582047")
	_, ds = old.call("GET", "/v1/me/devices", nil, nil)
	list = ds["devices"].([]any)
	thisID := list[0].(map[string]any)["id"].(float64)
	otherID := list[1].(map[string]any)["id"].(float64)
	if code, _ := old.call("DELETE", fmt.Sprintf("/v1/me/devices/%d", int(thisID)), nil, nil); code != http.StatusConflict {
		t.Errorf("remove this phone: %d", code)
	}
	if code, _ := old.call("DELETE", fmt.Sprintf("/v1/me/devices/%d", int(otherID)), nil, nil); code != http.StatusNoContent {
		t.Fatalf("remove other phone: %d", code)
	}
	if code, _ := thief.call("GET", "/v1/me/wallet", nil, nil); code != http.StatusUnauthorized {
		t.Errorf("removed phone: %d", code)
	}
	// Someone else can't remove Ada's phones.
	bola := &client{t: t, srv: srv, sms: sms, device: "bola-phone"}
	bola.signIn("08099999999", "570264")
	if code, _ := bola.call("DELETE", fmt.Sprintf("/v1/me/devices/%d", int(thisID)), nil, nil); code != http.StatusNotFound {
		t.Errorf("other user's device: %d", code)
	}
	_, n := old.call("GET", "/v1/me/notifications", nil, nil)
	if len(n["notifications"].([]any)) < 2 {
		t.Errorf("expected new-phone and PIN notifications: %v", n)
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
