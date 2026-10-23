# Avora

A Nigerian money app built on one promise: your money never gets lost. Transfers that don't go through are refunded automatically, and every fee is shown before you pay.

This repository holds the first version of the backend. The mobile app (Flutter) comes next.

## What works today

- **Ledger.** Double-entry and append-only, with amounts in kobo. Every journal must balance, and the database enforces this too. Each journal is written at most once per idempotency key. Wallets can't go below zero, even when many requests arrive at the same moment.
- **Wallets.** Each user gets a wallet with a 10-digit account number.
- **Inbound credits.** The partner bank sends a webhook signed with HMAC-SHA256. Each NIP session is credited once, and the ₦50 EMTL levy is taken on credits of ₦10,000 or more.
- **Transfers to any bank.**
  - Name enquiry runs first, and the money is held in the ledger before anything is sent.
  - A transfer is sent once and never resent. If the bank doesn't answer, it is requeried on a backoff (1, 2, 5, 10, 30 then 60 minutes).
  - A decline is refunded in full, including the fee.
  - A transfer with no answer after 6 hours goes to `needs_review` for the ops team.
- **Fees.** 5 free transfers a month, then ₦10 each. These are placeholders until pricing is decided.
- **Sandbox bank rail** for local development:

  | Account number ends in | Result |
  | --- | --- |
  | 0 | Declined |
  | 9 | Pending until the first requery |
  | 8 | Account not found |
  | anything else | Succeeds |

- **Reconciliation.** `ledger.Check` runs every hour. It checks that all entries sum to zero and that every balance matches its entries.

## Not done yet (needed before real money)

- User authentication, PIN and device binding. Today every route is open, so don't expose this server to the internet.
- A real partner bank rail (TAJBank or a BaaS provider) in place of the sandbox.
- KYC tiers and transaction limits.
- Bills, savings and support cases.
- The mobile app.

## Run it

Requires Go 1.24 and Docker.

```sh
docker compose up -d db
export DATABASE_URL="postgres://avora:avora@localhost:5432/avora?sslmode=disable"
export WEBHOOK_SECRET=dev-secret
cd backend && go run ./cmd/api
```

Run the tests. They need a Postgres database, and each test gets its own schema:

```sh
export AVORA_TEST_DATABASE_URL="postgres://avora:avora@localhost:5432/avora?sslmode=disable"
cd backend && go test -race ./...
```

## API

All amounts are integer kobo (₦1 = 100).

| Method | Path | Purpose |
| --- | --- | --- |
| POST | `/v1/wallets` | Open a wallet: `{"user_ref": "..."}` |
| GET | `/v1/wallets/{id}` | Wallet with balance |
| GET | `/v1/wallets/{id}/statement` | Movements, newest first |
| POST | `/v1/name-enquiry` | `{"bank_code", "account_number"}` returns the account name |
| POST | `/v1/transfers` | Send money; requires an `Idempotency-Key` header |
| GET | `/v1/transfers/{id}` | Transfer status |
| POST | `/v1/webhooks/inbound-credit` | Partner bank credit; `X-Signature` is required |
| POST | `/v1/ops/transfers/{id}/resolve` | Close a `needs_review` transfer |

## Layout

```
backend/
  cmd/api            server entry point
  internal/ledger    double-entry ledger and reconciliation check
  internal/wallets   wallets and system accounts
  internal/transfers transfer lifecycle, requery, refunds
  internal/inbound   inbound credits and EMTL
  internal/rails     bank rail interface and sandbox
  internal/api       HTTP handlers
  internal/migrate   embedded SQL migrations
```
