package bills

import (
	"context"
	"crypto/rand"
	"errors"
	"fmt"
	"math/big"
	"strings"
)

var ErrCustomerNotFound = errors.New("bills: customer not found")

type ProviderStatus string

const (
	ProviderSuccess ProviderStatus = "success"
	ProviderFailed  ProviderStatus = "failed"
	ProviderPending ProviderStatus = "pending"
)

type ProviderRequest struct {
	Reference string // our payment id; the provider must treat it as idempotent
	Biller    Biller
	PlanCode  string
	Customer  string
	Amount    int64
}

type PayResult struct {
	Status    ProviderStatus
	Token     string // electricity token or exam PIN
	Reference string // provider's reference
	Reason    string
}

// Provider is a bill aggregator (e.g. the partner bank's bills service).
type Provider interface {
	Catalog() []Biller
	Validate(ctx context.Context, b Biller, customer string) (string, error)
	Pay(ctx context.Context, req ProviderRequest) (PayResult, error)
}

// Sandbox follows fixed rules so the app can be tried end to end:
// a meter or smartcard ending in 8 is not found, and any customer number
// ending in 0 is declined.
type Sandbox struct{}

func (Sandbox) Catalog() []Biller { return SandboxCatalog() }

func (Sandbox) Validate(_ context.Context, b Biller, customer string) (string, error) {
	if b.needsLookup() && strings.HasSuffix(customer, "8") {
		return "", ErrCustomerNotFound
	}
	if !b.needsLookup() {
		return "", nil
	}
	return "SANDBOX CUSTOMER " + customer[len(customer)-4:], nil
}

func (Sandbox) Pay(_ context.Context, req ProviderRequest) (PayResult, error) {
	ref := "SBXBILL" + strings.ToUpper(strings.ReplaceAll(req.Reference, "-", "")[:12])
	if strings.HasSuffix(req.Customer, "0") {
		return PayResult{Status: ProviderFailed, Reference: ref, Reason: "biller declined"}, nil
	}
	res := PayResult{Status: ProviderSuccess, Reference: ref}
	switch req.Biller.Category {
	case Electricity:
		res.Token = digits(20)
	case Education:
		res.Token = digits(12)
	}
	return res, nil
}

// digits returns n random digits in groups of four.
func digits(n int) string {
	var b strings.Builder
	for i := range n {
		if i > 0 && i%4 == 0 {
			b.WriteByte('-')
		}
		d, _ := rand.Int(rand.Reader, big.NewInt(10))
		fmt.Fprint(&b, d)
	}
	return b.String()
}
