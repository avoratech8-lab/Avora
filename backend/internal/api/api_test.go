package api_test

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"testing"

	"avora/backend/internal/api"
	"avora/backend/internal/rails"
	"avora/backend/internal/testdb"
	"avora/backend/internal/transfers"
	"avora/backend/internal/wallets"
)

const secret = "test-secret"

func newServer(t *testing.T) *httptest.Server {
	t.Helper()
	ctx := context.Background()
	pool := testdb.New(t)
	sys, err := wallets.LoadSystem(ctx, pool)
	if err != nil {
		t.Fatal(err)
	}
	rail := rails.NewSandbox()
	cfg := transfers.DefaultConfig()
	cfg.FreeTransfersPerMonth = 0
	s := &api.Server{
		DB: pool, Rail: rail, System: sys,
		Transfers:     transfers.NewService(pool, rail, sys, cfg),
		NewNUBAN:      func(context.Context, string) (string, error) { return "9000000001", nil },
		WebhookSecret: secret,
		Log:           slog.New(slog.NewTextHandler(io.Discard, nil)),
	}
	srv := httptest.NewServer(s.Handler())
	t.Cleanup(srv.Close)
	return srv
}

func call(t *testing.T, srv *httptest.Server, method, path string, body any, headers map[string]string) (int, map[string]any) {
	t.Helper()
	var buf bytes.Buffer
	if body != nil {
		json.NewEncoder(&buf).Encode(body)
	}
	req, _ := http.NewRequest(method, srv.URL+path, &buf)
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var out map[string]any
	json.NewDecoder(resp.Body).Decode(&out)
	return resp.StatusCode, out
}

func TestWalletFundAndTransferFlow(t *testing.T) {
	srv := newServer(t)

	code, w := call(t, srv, "POST", "/v1/wallets", map[string]string{"user_ref": "ada"}, nil)
	if code != http.StatusCreated {
		t.Fatalf("create wallet: %d %v", code, w)
	}
	id := int64(w["id"].(float64))

	// Unsigned webhook is rejected.
	credit, _ := json.Marshal(map[string]any{"session_id": "S1", "account_number": "9000000001", "amount": 20_000_00, "sender_name": "TUNDE"})
	if code, _ := call(t, srv, "POST", "/v1/webhooks/inbound-credit", json.RawMessage(credit), nil); code != http.StatusUnauthorized {
		t.Errorf("unsigned webhook: %d", code)
	}
	compact := bytes.TrimSpace(credit)
	req, _ := http.NewRequest("POST", srv.URL+"/v1/webhooks/inbound-credit", bytes.NewReader(compact))
	req.Header.Set("X-Signature", api.Sign(secret, compact))
	resp, err := http.DefaultClient.Do(req)
	if err != nil || resp.StatusCode != http.StatusOK {
		t.Fatalf("signed webhook: %v %v", resp.StatusCode, err)
	}
	resp.Body.Close()

	code, ne := call(t, srv, "POST", "/v1/name-enquiry", map[string]string{"bank_code": "058", "account_number": "0123456781"}, nil)
	if code != http.StatusOK || ne["account_name"] == "" {
		t.Fatalf("name enquiry: %d %v", code, ne)
	}

	body := map[string]any{"wallet_id": id, "bank_code": "058", "account_number": "0123456781", "amount": 5_000_00}
	code, tr := call(t, srv, "POST", "/v1/transfers", body, map[string]string{"Idempotency-Key": "t1"})
	if code != http.StatusOK || tr["status"] != "delivered" {
		t.Fatalf("transfer: %d %v", code, tr)
	}

	// Sandbox declines account numbers ending in 0: money comes back.
	body["account_number"] = "0123456780"
	code, tr = call(t, srv, "POST", "/v1/transfers", body, map[string]string{"Idempotency-Key": "t2"})
	if code != http.StatusOK || tr["status"] != "refunded" {
		t.Fatalf("declined transfer: %d %v", code, tr)
	}

	code, got := call(t, srv, "GET", "/v1/wallets/"+jsonNum(id), nil, nil)
	want := float64(20_000_00 - 50_00 - 5_000_00 - 10_00)
	if code != http.StatusOK || got["balance"] != want {
		t.Errorf("balance = %v, want %v", got["balance"], want)
	}

	code, st := call(t, srv, "GET", "/v1/wallets/"+jsonNum(id)+"/statement", nil, nil)
	if code != http.StatusOK || len(st["lines"].([]any)) != 4 {
		t.Errorf("statement: %d %v", code, st)
	}

	body["amount"] = 1_000_000_00
	code, e := call(t, srv, "POST", "/v1/transfers", body, map[string]string{"Idempotency-Key": "t3"})
	if code != http.StatusUnprocessableEntity {
		t.Errorf("overspend: %d %v", code, e)
	}

	code, _ = call(t, srv, "POST", "/v1/transfers", body, nil)
	if code != http.StatusBadRequest {
		t.Errorf("missing idempotency key: %d", code)
	}
}

func jsonNum(n int64) string {
	b, _ := json.Marshal(n)
	return string(b)
}
