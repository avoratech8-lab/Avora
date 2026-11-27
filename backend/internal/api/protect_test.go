package api_test

import (
	"net/http"
	"testing"
	"time"
)

func TestFreezeStopsMoneyLeaving(t *testing.T) {
	srv, sms := newServer(t)
	ada := &client{t: t, srv: srv, sms: sms, device: "ada-phone"}
	ada.signIn("08031234567", "482915")
	credit(t, srv, "S1", "9000000001", 20_000_00)
	laptop := &client{t: t, srv: srv, sms: sms, device: "ada-tablet"}
	laptop.signIn("08031234567", "482915")

	_, c := ada.call("POST", "/v1/cards", map[string]any{"name": "Online"}, nil)
	card := c["id"].(string)

	if code, st := ada.call("POST", "/v1/me/freeze", nil, nil); code != http.StatusOK || st["frozen"] != true {
		t.Fatalf("freeze: %d %v", code, st)
	}
	if code, _ := laptop.call("GET", "/v1/me/wallet", nil, nil); code != http.StatusUnauthorized {
		t.Errorf("other phone after freeze: %d", code)
	}
	if _, st := ada.call("GET", "/v1/me/freeze", nil, nil); st["frozen"] != true || st["frozen_at"] == nil {
		t.Errorf("freeze status: %v", st)
	}

	send := func(key string) (int, map[string]any) {
		return ada.call("POST", "/v1/transfers", map[string]any{"bank_code": "058", "account_number": "0123456781",
			"amount": 1_000_00, "pin": "482915"}, map[string]string{"Idempotency-Key": key})
	}
	if code, e := send("t1"); code != http.StatusForbidden || e["error"].(map[string]any)["code"] != "account_frozen" {
		t.Errorf("transfer while frozen: %d %v", code, e)
	}
	if code, e := ada.call("POST", "/v1/p2p", map[string]any{"to": "08099999999", "amount": 100, "pin": "482915"},
		map[string]string{"Idempotency-Key": "p1"}); code != http.StatusForbidden || e["error"].(map[string]any)["code"] != "account_frozen" {
		t.Errorf("Avora payment while frozen: %d %v", code, e)
	}
	_, p := ada.call("POST", "/v1/sandbox/cards/"+card+"/charge", map[string]any{"merchant": "Jumia", "amount": 500_00},
		map[string]string{"Idempotency-Key": "c1"})
	if p["status"] != "declined" || p["decline_reason"] != "account frozen" {
		t.Errorf("card payment while frozen: %v", p)
	}
	// Money can still come in (₦20,000 less the ₦50 levy, then ₦1,000).
	credit(t, srv, "S2", "9000000001", 1_000_00)
	if _, w := ada.call("GET", "/v1/me/wallet", nil, nil); w["balance"] != float64(20_950_00) {
		t.Errorf("balance while frozen = %v", w["balance"])
	}

	if code, _ := ada.call("POST", "/v1/me/unfreeze", map[string]any{"pin": "000001"}, nil); code != http.StatusUnauthorized {
		t.Errorf("unfreeze with a wrong PIN: %d", code)
	}
	if code, st := ada.call("POST", "/v1/me/unfreeze", map[string]any{"pin": "482915"}, nil); code != http.StatusOK || st["frozen"] != false {
		t.Fatalf("unfreeze: %d %v", code, st)
	}
	if code, tr := send("t2"); code != http.StatusOK {
		t.Errorf("transfer after unfreeze: %d %v", code, tr)
	}
	_, ns := ada.call("GET", "/v1/me/notifications", nil, nil)
	titles := map[string]bool{}
	for _, n := range ns["notifications"].([]any) {
		titles[n.(map[string]any)["title"].(string)] = true
	}
	if !titles["Account frozen"] || !titles["Account unfrozen"] {
		t.Errorf("notifications: %v", titles)
	}
}

func TestStatementForAPeriod(t *testing.T) {
	srv, sms := newServer(t)
	ada := &client{t: t, srv: srv, sms: sms, device: "ada-phone"}
	ada.signIn("08031234567", "482915")
	credit(t, srv, "S1", "9000000001", 20_000_00)
	if code, tr := ada.call("POST", "/v1/transfers", map[string]any{"bank_code": "058", "account_number": "0123456781",
		"amount": 5_000_00, "pin": "482915"}, map[string]string{"Idempotency-Key": "t1"}); code != http.StatusOK {
		t.Fatalf("transfer: %d %v", code, tr)
	}

	today := time.Now().In(time.FixedZone("WAT", 3600)).Format("2006-01-02")
	code, st := ada.call("GET", "/v1/me/statement/period?from="+today+"&to="+today, nil, nil)
	if code != http.StatusOK {
		t.Fatalf("statement: %d %v", code, st)
	}
	_, w := ada.call("GET", "/v1/me/wallet", nil, nil)
	if st["opening_balance"] != float64(0) || st["money_in"] != float64(19_950_00) ||
		st["closing_balance"] != w["balance"] || st["account_number"] != "9000000001" {
		t.Errorf("statement: %v", st)
	}
	if lines := st["lines"].([]any); len(lines) < 2 || lines[0].(map[string]any)["kind"] != "inbound_credit" {
		t.Errorf("lines, oldest first: %v", lines)
	}

	// A period that ended before the account opened starts and ends at the same balance.
	code, old := ada.call("GET", "/v1/me/statement/period?from=2020-01-01&to=2020-01-31", nil, nil)
	if code != http.StatusOK || old["closing_balance"] != float64(0) || len(old["lines"].([]any)) != 0 {
		t.Errorf("old period: %d %v", code, old)
	}
	for _, q := range []string{"from=2026-10-31&to=2026-10-01", "from=2024-01-01&to=2026-01-01", "from=oct&to=nov"} {
		if code, _ := ada.call("GET", "/v1/me/statement/period?"+q, nil, nil); code != http.StatusBadRequest {
			t.Errorf("%s: %d", q, code)
		}
	}
}

func TestReportAProblem(t *testing.T) {
	srv, sms := newServer(t)
	ada := &client{t: t, srv: srv, sms: sms, device: "ada-phone"}
	ada.signIn("08031234567", "482915")
	credit(t, srv, "S1", "9000000001", 20_000_00)
	_, tr := ada.call("POST", "/v1/transfers", map[string]any{"bank_code": "058", "account_number": "0123456781",
		"amount": 5_000_00, "pin": "482915"}, map[string]string{"Idempotency-Key": "t1"})
	ref := tr["id"].(string)

	open := func(c *client, body map[string]any) (int, map[string]any) {
		return c.call("POST", "/v1/disputes", body, nil)
	}
	if code, _ := open(ada, map[string]any{"ref": ref, "reason": "other"}); code != http.StatusBadRequest {
		t.Errorf("other with no details: %d", code)
	}
	if code, _ := open(ada, map[string]any{"ref": ref, "reason": "because"}); code != http.StatusBadRequest {
		t.Errorf("unknown reason: %d", code)
	}
	code, d := open(ada, map[string]any{"ref": ref, "reason": "not_received", "details": "Mum says nothing came"})
	if code != http.StatusOK || d["status"] != "open" || d["kind"] != "transfer_hold" || d["amount"].(float64) >= 0 {
		t.Fatalf("open: %d %v", code, d)
	}
	id := d["id"].(string)
	if code, e := open(ada, map[string]any{"ref": ref, "reason": "wrong_amount"}); code != http.StatusConflict {
		t.Errorf("second open report: %d %v", code, e)
	}
	if code, _ := open(ada, map[string]any{"ref": "nope", "reason": "not_me"}); code != http.StatusNotFound {
		t.Errorf("unknown payment: %d", code)
	}

	bola := &client{t: t, srv: srv, sms: sms, device: "bola-phone"}
	bola.signIn("08099999999", "570264")
	if code, _ := open(bola, map[string]any{"ref": ref, "reason": "not_me"}); code != http.StatusNotFound {
		t.Errorf("someone else's payment: %d", code)
	}
	if code, _ := bola.call("GET", "/v1/disputes/"+id, nil, nil); code != http.StatusNotFound {
		t.Errorf("someone else's report: %d", code)
	}

	answer := map[string]any{"outcome": "resolved", "answer": "The bank confirmed it was delivered at 10:02."}
	if code, _ := ada.call("POST", "/v1/ops/disputes/"+id+"/close", answer, nil); code != http.StatusUnauthorized {
		t.Errorf("close without ops key: %d", code)
	}
	ops := map[string]string{"X-Ops-Key": opsKey}
	if code, d := ada.call("POST", "/v1/ops/disputes/"+id+"/close", answer, ops); code != http.StatusOK || d["status"] != "resolved" {
		t.Fatalf("close: %d %v", code, d)
	}
	if code, _ := ada.call("POST", "/v1/ops/disputes/"+id+"/close", answer, ops); code != http.StatusConflict {
		t.Errorf("close twice: %d", code)
	}
	_, list := ada.call("GET", "/v1/disputes", nil, nil)
	if ds := list["disputes"].([]any); len(ds) != 1 || ds[0].(map[string]any)["answer"] != answer["answer"] {
		t.Errorf("list: %v", list)
	}
	// Once answered, the payment can be reported again.
	if code, _ := open(ada, map[string]any{"ref": ref, "reason": "wrong_amount"}); code != http.StatusOK {
		t.Errorf("report again after an answer: %d", code)
	}
	_, ns := ada.call("GET", "/v1/me/notifications", nil, nil)
	if n := ns["notifications"].([]any)[1].(map[string]any); n["title"] != "Your report is resolved" || n["ref"] != id {
		t.Errorf("notification: %v", n)
	}
}
