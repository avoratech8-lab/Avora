// Package rails is the boundary to the interbank payment rail (NIP via the
// partner bank). Swapping banks means writing a new Rail, nothing else.
package rails

import (
	"context"
	"errors"
	"fmt"
	"sync"
)

var ErrAccountNotFound = errors.New("rails: account not found")

type Status string

const (
	Pending  Status = "pending" // the bank has not given a final answer
	Success  Status = "success"
	Failed   Status = "failed"
	NotFound Status = "not_found" // the bank has no record of the reference
)

type Result struct {
	Status    Status
	SessionID string // NIP session id, shown on receipts
	Reason    string
}

type SendRequest struct {
	Reference     string // our transfer id; used again for status queries
	BankCode      string
	AccountNumber string
	AccountName   string
	Amount        int64 // kobo
	Narration     string
}

type Rail interface {
	NameEnquiry(ctx context.Context, bankCode, accountNumber string) (string, error)
	// Send returns an error only when the outcome is unknown (timeout,
	// dropped connection); the transfer is then requeried, never resent.
	Send(ctx context.Context, req SendRequest) (Result, error)
	Status(ctx context.Context, reference string) (Result, error)
}

// Sandbox is a fake rail for local development. Account numbers ending in
// 0 are declined, ending in 9 stay pending until their first status query,
// and ending in 8 do not exist. Everything else succeeds immediately.
type Sandbox struct {
	mu   sync.Mutex
	sent map[string]SendRequest
}

func NewSandbox() *Sandbox { return &Sandbox{sent: map[string]SendRequest{}} }

func (s *Sandbox) NameEnquiry(_ context.Context, bankCode, accountNumber string) (string, error) {
	if len(accountNumber) != 10 || accountNumber[9] == '8' {
		return "", ErrAccountNotFound
	}
	return "SANDBOX USER " + accountNumber[6:], nil
}

func (s *Sandbox) Send(_ context.Context, req SendRequest) (Result, error) {
	s.mu.Lock()
	s.sent[req.Reference] = req
	s.mu.Unlock()
	return s.outcome(req, false), nil
}

func (s *Sandbox) Status(_ context.Context, reference string) (Result, error) {
	s.mu.Lock()
	req, ok := s.sent[reference]
	s.mu.Unlock()
	if !ok {
		return Result{Status: NotFound}, nil
	}
	return s.outcome(req, true), nil
}

func (s *Sandbox) outcome(req SendRequest, requery bool) Result {
	session := fmt.Sprintf("SBX%s", req.Reference)
	switch req.AccountNumber[len(req.AccountNumber)-1] {
	case '0':
		return Result{Status: Failed, SessionID: session, Reason: "beneficiary bank declined"}
	case '9':
		if !requery {
			return Result{Status: Pending}
		}
	}
	return Result{Status: Success, SessionID: session}
}
