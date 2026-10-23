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
	"avora/backend/internal/ledger"
	"avora/backend/internal/migrate"
	"avora/backend/internal/rails"
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
	secret := os.Getenv("WEBHOOK_SECRET")
	if secret == "" {
		return errors.New("WEBHOOK_SECRET is required")
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
	srv := &api.Server{
		DB:            pool,
		Rail:          rail,
		System:        sys,
		Transfers:     svc,
		NewNUBAN:      sandboxNUBAN,
		WebhookSecret: secret,
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
