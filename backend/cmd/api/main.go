// Command api runs the Avora backend with the sandbox bank rail.
package main

import (
	"context"
	"crypto/rand"
	"errors"
	"fmt"
	"log/slog"
	"math/big"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"avora/backend/internal/api"
	"avora/backend/internal/auth"
	"avora/backend/internal/bills"
	"avora/backend/internal/kyc"
	"avora/backend/internal/ledger"
	"avora/backend/internal/migrate"
	"avora/backend/internal/p2p"
	"avora/backend/internal/rails"
	"avora/backend/internal/referrals"
	"avora/backend/internal/savings"
	"avora/backend/internal/support"
	"avora/backend/internal/transfers"
	"avora/backend/internal/wallets"
)

func main() {
	log := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	if err := run(log); err != nil {
		log.Error("exit", "err", err)
		os.Exit(1)
	}
}

func run(log *slog.Logger) error {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	dbURL := os.Getenv("DATABASE_URL")
	if dbURL == "" {
		return errors.New("DATABASE_URL is required")
	}
	secret, authSecret, opsKey := os.Getenv("WEBHOOK_SECRET"), os.Getenv("AUTH_SECRET"), os.Getenv("OPS_KEY")
	if secret == "" || len(authSecret) < 32 || len(opsKey) < 32 {
		return errors.New("WEBHOOK_SECRET, AUTH_SECRET (32+ chars) and OPS_KEY (32+ chars) are required")
	}
	addr := ":" + envOr("PORT", "8080")

	pool, err := pgxpool.New(ctx, dbURL)
	if err != nil {
		return err
	}
	defer pool.Close()
	if err := migrate.Up(ctx, pool); err != nil {
		return err
	}
	sys, err := wallets.LoadSystem(ctx, pool)
	if err != nil {
		return err
	}

	rail := rails.NewSandbox()
	svc := transfers.NewService(pool, rail, sys, transfers.DefaultConfig())
	authSvc := auth.NewService(pool, logSMS{log}, auth.DefaultConfig([]byte(authSecret)), sandboxNUBAN)
	savingsSvc, err := savings.NewService(ctx, pool, savings.DefaultRates())
	if err != nil {
		return err
	}
	refSvc, err := referrals.NewService(ctx, pool, referrals.DefaultConfig())
	if err != nil {
		return err
	}
	kycSvc := kyc.NewService(pool, kyc.Sandbox{})
	kycSvc.OnVerified = refSvc.Verified
	srv := &api.Server{
		DB:            pool,
		Rail:          rail,
		System:        sys,
		Transfers:     svc,
		Bills:         bills.NewService(pool, bills.Sandbox{}, sys),
		Savings:       savingsSvc,
		KYC:           kycSvc,
		Referrals:     refSvc,
		Support:       support.NewService(pool),
		P2P:           p2p.NewService(pool),
		Auth:          authSvc,
		WebhookSecret: secret,
		OpsKey:        opsKey,
		Log:           log,
	}

	go every(ctx, 30*time.Second, func() {
		if n, err := svc.RequeryDue(ctx, 100); err != nil {
			log.Error("requery", "err", err)
		} else if n > 0 {
			log.Info("requeried transfers", "count", n)
		}
	})
	go every(ctx, time.Hour, func() {
		if err := ledger.Check(ctx, pool); err != nil {
			log.Error("LEDGER CHECK FAILED", "err", err)
		}
	})

	httpSrv := &http.Server{Addr: addr, Handler: srv.Handler(), ReadHeaderTimeout: 10 * time.Second}
	go func() {
		<-ctx.Done()
		shutdown, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		httpSrv.Shutdown(shutdown)
	}()
	log.Info("listening", "addr", addr, "rail", "sandbox")
	if err := httpSrv.ListenAndServe(); !errors.Is(err, http.ErrServerClosed) {
		return err
	}
	return nil
}

func every(ctx context.Context, d time.Duration, f func()) {
	t := time.NewTicker(d)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			f()
		}
	}
}

// logSMS writes codes to the log instead of texting them. Sandbox only:
// production must use a real SMS/WhatsApp provider and never log codes.
type logSMS struct{ log *slog.Logger }

func (l logSMS) Send(_ context.Context, phone, msg string) error {
	l.log.Warn("SANDBOX SMS", "to", phone, "message", msg)
	return nil
}

// sandboxNUBAN stands in for the partner bank's account-number API.
func sandboxNUBAN(context.Context, string) (string, error) {
	n, err := rand.Int(rand.Reader, big.NewInt(1_000_000_000))
	if err != nil {
		return "", err
	}
	return fmt.Sprintf("9%09d", n.Int64()), nil
}

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
