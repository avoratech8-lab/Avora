# Avora

A Nigerian money app built on one promise: your money never gets lost. Transfers that don't go through are refunded automatically, and every fee is shown before you pay.

This repository holds the backend (`backend/`, Go) and the Android app (`app/`, Flutter).

## What works today

- **Ledger.** Double-entry and append-only, with amounts in kobo. Every journal must balance, and the database enforces this too. Each journal is written at most once per idempotency key. Wallets can't go below zero, even when many requests arrive at the same moment.
- **Wallets.** Each user gets a wallet with a 10-digit account number.
- **Inbound credits.** The partner bank sends a webhook signed with HMAC-SHA256. Each NIP session is credited once, and the ₦50 EMTL levy is taken on credits of ₦10,000 or more.
- **Transfers to any bank.**
  - Name enquiry runs first, and the money is held in the ledger before anything is sent.
  - A transfer is sent once and never resent. If the bank doesn't answer, it is requeried on a backoff (1, 2, 5, 10, 30 then 60 minutes).
  - A decline is refunded in full, including the fee.
  - A transfer with no answer after 6 hours goes to `needs_review` for the ops team.
- **Bills.** Airtime, data, electricity and TV through `GET /v1/bills/billers`, `POST /v1/bills/validate` and `POST /v1/bills/payments` (PIN and `Idempotency-Key` required). The money is held, then settled, or refunded in full if the biller declines. Bills count toward the new-phone limit.
- **Fees.** 5 free transfers a month, then ₦10 each. These are placeholders until pricing is decided.
- **Sandbox bank rail** for local development:

  | Account number ends in | Result |
  | --- | --- |
  | 0 | Declined |
  | 9 | Pending until the first requery |
  | 8 | Account not found |
  | anything else | Succeeds |

- **Sign-up and login.**
  - Sign-up uses a phone OTP and a 6-digit PIN. Codes expire after 5 minutes and allow 5 tries, with at most 3 codes per 10 minutes.
  - Easy PINs such as 123456 or 000000 are rejected. Five wrong PINs lock the account for 30 minutes.
- **Device binding.**
  - A session works only from the phone it was created on.
  - A newly added phone can send up to ₦20,000 in its first 24 hours.
  - Every transfer needs the PIN.
  - Customers can only see their own wallet and transfers.
  - Ops routes need an ops key.
- **Reconciliation.** `ledger.Check` runs every hour. It checks that all entries sum to zero and that every balance matches its entries.

## Not done yet (needed before real money)

- A real SMS/WhatsApp provider for OTPs. In the sandbox, codes are written to the server log.
- A real partner bank rail (TAJBank or a BaaS provider) in place of the sandbox.
- KYC tiers and transaction limits.
- A real bill aggregator in place of the bills sandbox, and requery for bill payments left pending.
- Savings, support cases and the other features shown as "coming soon".
- A release build of the app (signing key, icon, Play Store listing).

## The app

The Flutter app covers:

- **Sign-up and sign-in:** phone number, code boxes, and a PIN on a number pad.
- **Home:** balance card (hideable), account number to copy or share, quick actions, "Send again" for saved recipients, and recent activity.
- **Send money:** searchable bank list, automatic name check, a big amount pad, a review screen showing the fee, and PIN approval.
- **Airtime, data, electricity and TV:** all networks, the main DisCos (the meter name is checked and a token issued), and DStv, GOtv and StarTimes packages.
- **Receipts:** live status for every payment and receipts you can share. They show the session ID for transfers and the token for electricity.
- **Activity:** money in and out totals, search and filters, grouped by day.
- **Me:** account details and shortcuts for features that are coming next.

Bills sandbox rules: a meter or smartcard ending in 8 is not found, and any phone, meter or smartcard ending in 0 fails and is refunded. Data and TV prices are samples.

It runs in two modes:

- **Demo mode** (the default). No server needed and no real money. The sign-in code is `000000`, you start with ₦50,000 of demo money, and account numbers follow the sandbox table above.
- **Connected.** Build with `--dart-define=AVORA_API_URL=https://your-server` to talk to the backend.

Every pull request builds a demo APK. Open the **app** check on the pull request, then **Summary**, and download `avora-demo-apk` to install it on an Android phone.

```sh
cd app
flutter test
flutter run                                              # demo mode
flutter run --dart-define=AVORA_API_URL=http://10.0.2.2:8080   # Android emulator to a local backend
```

## Run the backend

Requires Go 1.24 and Docker.

```sh
docker compose up -d db
export DATABASE_URL="postgres://avora:avora@localhost:5432/avora?sslmode=disable"
export WEBHOOK_SECRET=dev-secret
export AUTH_SECRET=$(openssl rand -hex 32)
export OPS_KEY=$(openssl rand -hex 32)
cd backend && go run ./cmd/api
```

Run the tests. They need a Postgres database, and each test gets its own schema:

```sh
export AVORA_TEST_DATABASE_URL="postgres://avora:avora@localhost:5432/avora?sslmode=disable"
cd backend && go test -race ./...
```

## API

All amounts are integer kobo (₦1 = 100).

Signed-in routes need `Authorization: Bearer <token>` and the `X-Device-ID` the session was created with.

| Method | Path | Purpose |
| --- | --- | --- |
| POST | `/v1/auth/otp` | `{"phone"}` texts a code and returns `challenge_id` |
| POST | `/v1/auth/verify` | `{"challenge_id", "code", "pin"}` plus `X-Device-ID`; signs up or in and returns a token |
| POST | `/v1/auth/logout` | End this session |
| GET | `/v1/me/wallet` | My wallet and balance |
| GET | `/v1/me/statement` | My movements, newest first |
| POST | `/v1/name-enquiry` | `{"bank_code", "account_number"}` returns the account name |
| POST | `/v1/transfers` | `{"bank_code", "account_number", "amount", "narration", "pin"}`; requires an `Idempotency-Key` header |
| GET | `/v1/transfers/{id}` | One of my transfers |
| POST | `/v1/webhooks/inbound-credit` | Partner bank credit; requires `X-Signature` |
| POST | `/v1/ops/transfers/{id}/resolve` | Close a `needs_review` transfer; requires `X-Ops-Key` |

## Layout

```
backend/
  cmd/api            server entry point
  internal/auth      OTP, PIN, devices and sessions
  internal/ledger    double-entry ledger and reconciliation check
  internal/wallets   wallets and system accounts
  internal/transfers transfer lifecycle, requery, refunds
  internal/inbound   inbound credits and EMTL
  internal/rails     bank rail interface and sandbox
  internal/api       HTTP handlers
  internal/migrate   embedded SQL migrations
```
