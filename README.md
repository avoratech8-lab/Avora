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
- **Bills.** Airtime, data, electricity, TV, internet (Spectranet, Smile), exam PINs (WAEC, NECO, JAMB) and betting wallet top-ups (Bet9ja, SportyBet, BetKing, 1xBet, NairaBet, MSport) through `GET /v1/bills/billers`, `POST /v1/bills/validate` and `POST /v1/bills/payments` (PIN and `Idempotency-Key` required). The money is held, then settled, or refunded in full if the biller declines. Bills count toward the new-phone limit. Airtime earns 2% and data 3% cashback (at most ₦500 a payment), paid from `system:cashback` once the biller confirms; the rates are placeholders to set within the aggregator's commission. Betting is on by default; set `BETTING=off` to hide it.
- **Savings.** Non-interest (mudarabah) pots, each its own ledger account: `GET/POST /v1/savings`, `POST /v1/savings/{id}/deposit` and `/withdraw`. Profit is shared after each month at the rate the partner bank declares: `POST /v1/ops/savings/profit` with `{"period": "2026-10", "goal_rate_bps": 800, "locked_rate_bps": 1200}` (each month once). Expected rates (8% goals; 10 to 16% locked) are placeholders until the bank publishes its profit-sharing ratios.
- **KYC tiers and limits.** Phone-only accounts are Tier 1 (₦50,000 a day, ₦300,000 balance). A verified BVN or NIN gives Tier 2 (₦200,000 a day, ₦500,000 balance), and both give Tier 3 (₦5,000,000 a day, no balance cap). Transfers and bills since midnight Lagos time count toward the daily limit. `GET/POST /v1/me/kyc`; only the last 4 digits of an ID are kept. The tier amounts follow the published CBN tiers and must be confirmed with the partner bank. Sandbox: any 11-digit number is accepted except ones ending in 0.
- **Avora tags and free instant transfers.** Each customer can claim a tag like `@ada` (3 to 20 letters, numbers or `_`, starting with a letter; names like `@avora` and `@support` are reserved). Sending to another Avora customer by tag or phone number is one ledger journal between two wallets: free, instant, and it can't get stuck at another bank. The PIN and an `Idempotency-Key` are required, the payment counts toward the daily limit, and the person paid gets a notification. Phone numbers are masked in lookups.
- **Spending insights and budgets.** `GET /v1/me/insights?month=2026-10` totals a month (Lagos time) from the ledger: money in, spending by category net of refunds, money saved, cashback, daily spending and last month's total. Budgets per category or for all spending (`GET /v1/me/budgets`, `PUT /v1/me/budgets/{category}` with `{"amount"}`, 0 removes) send a notification at 80% and at 100%, once each a month.
- **Virtual cards (sandbox).** Up to 3 cards per customer that spend straight from the wallet: create, freeze, monthly limit, details behind the PIN, close, and a payment list. `Charge` approves or declines (frozen, over limit, short of money) and notifies the customer either way. Card numbers are never stored; until a card issuer is signed they are derived from the card id on a test Verve range. `POST /v1/sandbox/cards/{id}/charge` stands in for the card scheme; set `SANDBOX=off` in production.
- **Round-ups.** Save the change from every transfer, bill, Avora payment and card payment into a goal pot, rounding to the next ₦10, ₦100 or ₦1,000 (`GET/PUT /v1/me/roundup`). Skipped when the wallet is short.
- **Scheduled payments.** Pay a bank account, an Avora tag or phone, a bill or a goal pot once, daily, weekly or monthly (`GET/POST /v1/schedules`, `POST /v1/schedules/{id}/pause` with `{"paused"}`, `DELETE /v1/schedules/{id}`). The payee is checked when it's set up, with the PIN, so each run goes ahead without asking. Monthly runs keep the day, or use the last day of a shorter month. Every minute the server claims what's due (`for update skip locked`, so several servers can run it), pays it under the same daily limit as a payment made by hand, and tells the customer how it went. Resuming a paused schedule skips the runs it missed. `POST /v1/sandbox/schedules/{id}/run` runs one now.
- **Split bills.** Ask 1 to 10 Avora customers by tag or phone to chip in for a bill (`POST /v1/splits` with `{"title", "total", "people": [{"to", "amount"}]}`). Each gets a notification and pays (`POST /v1/splits/{id}/pay` with `{"pin"}`, a free Avora transfer to whoever asked) or declines (`POST /v1/splits/{id}/decline`), once. The asker is told either way. `GET /v1/splits` and `GET /v1/splits/{id}` show who has paid.
- **Security settings.** Change PIN (`POST /v1/me/pin`, which signs out other phones), check the PIN to unlock the app (`POST /v1/me/pin/verify`), and list or remove phones (`GET /v1/me/devices`, `DELETE /v1/me/devices/{id}`). The app sends `X-Device-Name` at sign-in so phones have names.
- **Notifications.** Money received, transfers delivered, refunded or under review, bill refunds, new phone sign-ins, PIN changes and tier upgrades: `GET /v1/me/notifications` and `POST /v1/me/notifications/read`.
- **Referrals.** Each customer gets an invite code (`GET /v1/me/referrals`). A friend can add it within 30 days of joining (`POST /v1/me/referrals`). When that friend first reaches Tier 2, the inviter is paid ₦500 from `system:referral_rewards`, once per friend. The amount is a placeholder until marketing sets a budget.
- **Help centre and support chat.** `GET /v1/help/articles` serves the help articles. `GET/POST /v1/support/messages` is the chat: a bot answers from the articles and hands over to a person when asked or when it has no answer. Agents reply with `POST /v1/ops/support/{user_id}/reply` (ops key), which also notifies the customer.
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
- A real BVN/NIN check through the partner bank (NIBSS and NIMC) in place of the KYC sandbox, and enforcing the tier's maximum balance on inbound credits.
- Push notifications (the in-app inbox works; FCM/APNs delivery is not wired up).
- A real bill aggregator in place of the bills sandbox, and requery for bill payments left pending.
- Savings profit on average daily balance (month-end balance for now), once the partner bank confirms its method.
- A support desk for agents (they reply through the ops API for now), and the other features shown as "coming soon" (cards, statements, personal details).
- A release build of the app (signing key, icon, Play Store listing).

## The app

The Flutter app covers:

- **Sign-up and sign-in:** phone number, code boxes, and a PIN on a number pad.
- **Home:** balance card (hideable), account number to copy or share, quick actions, "Send again" for saved recipients, and recent activity.
- **Send to Avora:** type an @tag or phone number, see who it is, and send for free. It arrives instantly with a receipt on both sides. A card on Home asks you to claim your own tag.
- **Send money:** searchable bank list, automatic name check, a big amount pad, a review screen showing the fee, and PIN approval.
- **Cashback:** 2% back on airtime and 3% on data, shown before you pay and on the receipt.
- **More bills:** internet, WAEC/NECO/JAMB PINs (the PIN is on the receipt to copy), and betting top-ups by user ID with an 18+ note.
- **Airtime, data, electricity and TV:** all networks, the main DisCos (the meter name is checked and a token issued), and DStv, GOtv and StarTimes packages.
- **Receipts:** live status for every payment and receipts you can share. They show the session ID for transfers and the token for electricity.
- **Savings (interest-free):** Goal pots you can add to or take from at any time, and Locked plans (1, 3, 6 or 12 months) that earn a higher expected profit share. Breaking a plan early returns the money but gives back its profit share.
- **Spending insights:** what you spent this month against last month, day-by-day bars, where it went by category, and monthly budgets (overall or per category) with alerts at 80% and 100%.
- **Cards:** a free virtual card for paying online, with freeze, monthly limit, number and CVV behind the PIN, payments, and a test payment button in the sandbox.
- **Round-ups:** turn on from Savings and pick the pot and step.
- **Scheduled payments:** rent, school fees, a monthly data plan or a weekly save, set once from Me or Home → More. Shows what will go out this month, each schedule's next date and how the last run went, with pause, resume and delete.
- **Split bills:** ask friends on Avora for their share, split evenly or by hand, watch who has paid, and pay or decline a request in one tap. Demo users get a request from @tolu to try it.
- **Activity:** money in and out totals, search and filters, grouped by day.
- **Security:** fingerprint or face unlock, an app lock (immediately, after 1 or after 5 minutes away) with PIN fallback, fingerprint or face approval for payments, change PIN, and phones signed in. With biometrics on, the PIN is kept in the phone's Keystore/Keychain and only released after a fingerprint or face check, so the server still checks the PIN on every payment.
- **Limits:** your KYC tier and what it allows, and BVN or NIN verification to move up.
- **Notifications:** a bell with an unread count and an inbox that opens the matching receipt.
- **Receive and request by QR:** Add money shows a QR code with your account. Request money adds an amount and a note, and shares a message that people on other banks can follow too.
- **Scan to pay:** scan an Avora QR code (or any QR holding an account number) from Home and the bank, account, name, amount and note are filled in for you.
- **Invite friends:** your code, how many friends joined and verified, what you've earned, and a place to add the code you were invited with.
- **Help centre and chat:** searchable answers by topic and a chat where the assistant answers straight away and hands over to an agent.
- **Me:** account details, tier, security and help.

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
| POST | `/v1/me/pin` | `{"old_pin", "new_pin"}`; signs out other phones |
| POST | `/v1/me/pin/verify` | `{"pin"}`; unlocks the app |
| GET | `/v1/me/devices` | Phones that have signed in |
| DELETE | `/v1/me/devices/{id}` | Sign a phone out and remove it |
| GET | `/v1/me/kyc` | Tier, limits and which IDs are verified |
| POST | `/v1/me/kyc` | `{"type": "bvn" or "nin", "number"}` |
| GET | `/v1/me/notifications` | Latest notifications and the unread count |
| POST | `/v1/me/notifications/read` | Mark all as read |
| GET | `/v1/me/profile` | My name, @tag, phone and account number |
| PATCH | `/v1/me/profile` | `{"name", "tag"}`: set my name or claim a tag |
| GET | `/v1/p2p/find?q=` | Find an Avora customer by @tag or phone |
| POST | `/v1/p2p` | `{"to", "amount", "note", "pin"}` + `Idempotency-Key`: free instant transfer |
| GET | `/v1/p2p/{id}` | One Avora transfer |
| GET | `/v1/me/insights?month=` | A month's money in and out by category |
| GET | `/v1/me/budgets` | My monthly budgets |
| PUT | `/v1/me/budgets/{category}` | `{"amount"}`: set a budget (0 removes) |
| GET/POST | `/v1/cards` | My cards / `{"name"}`: new card |
| POST | `/v1/cards/{id}/freeze` | `{"frozen"}` |
| PUT | `/v1/cards/{id}/limit` | `{"amount"}`: monthly limit (0 removes) |
| POST | `/v1/cards/{id}/details` | `{"pin"}`: number, expiry, CVV |
| POST | `/v1/cards/{id}/terminate` | `{"pin"}`: close the card |
| GET | `/v1/cards/{id}/payments` | Recent card payments |
| GET/PUT | `/v1/me/roundup` | `{"pot_id", "step"}`; empty pot turns it off |
| GET/POST | `/v1/schedules` | My scheduled payments / `{"kind", "name", "amount", "frequency", "starts_at", "target", "pin"}` |
| POST | `/v1/schedules/{id}/pause` | `{"paused"}` |
| DELETE | `/v1/schedules/{id}` | Stop a scheduled payment |
| GET/POST | `/v1/splits` | Splits I asked or was asked in / `{"title", "total", "people"}` |
| GET | `/v1/splits/{id}` | Who owes what |
| POST | `/v1/splits/{id}/pay` | `{"pin"}`: pay my share |
| POST | `/v1/splits/{id}/decline` | Decline my share |
| GET | `/v1/me/referrals` | My invite code and rewards |
| POST | `/v1/me/referrals` | `{"code"}`: the code I was invited with |
| GET | `/v1/help/articles` | Help centre articles |
| GET | `/v1/support/messages` | My support chat |
| POST | `/v1/support/messages` | `{"body"}`; returns the chat with the assistant's answer |
| POST | `/v1/ops/support/{user_id}/reply` | Agent reply; requires `X-Ops-Key` |
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
