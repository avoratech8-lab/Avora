-- Virtual cards that spend straight from the wallet, and round-ups that
-- save the change from each payment into a goal pot.
--
-- Card numbers and CVVs are never stored here: in production the card
-- issuer holds them and shows them through its own secure view. The sandbox
-- derives them from the card id.
create table cards (
    id                uuid primary key default gen_random_uuid(),
    wallet_account_id bigint not null references wallets (account_id),
    name              text not null,
    brand             text not null default 'Verve',
    last4             text not null,
    expiry            text not null, -- MM/YY
    status            text not null default 'active' check (status in ('active', 'frozen', 'terminated')),
    monthly_limit     bigint not null default 0 check (monthly_limit >= 0), -- 0 means no card limit
    created_at        timestamptz not null default now()
);

create index cards_wallet on cards (wallet_account_id, created_at);

create table card_payments (
    id              uuid primary key default gen_random_uuid(),
    card_id         uuid not null references cards (id),
    idempotency_key text not null,
    merchant        text not null,
    amount          bigint not null check (amount > 0),
    status          text not null check (status in ('approved', 'declined')),
    decline_reason  text not null default '',
    created_at      timestamptz not null default now(),
    unique (card_id, idempotency_key)
);

create index card_payments_card on card_payments (card_id, created_at desc);

create table savings_roundups (
    wallet_account_id bigint primary key references wallets (account_id),
    pot_id            uuid not null references savings_pots (id),
    step              bigint not null check (step in (1000, 10000, 100000)) -- ₦10, ₦100 or ₦1,000
);
