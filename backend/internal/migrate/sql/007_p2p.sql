-- Avora tags (@ada) and a display name, so customers can find and pay
-- each other without account numbers.
alter table users add column tag text unique check (tag ~ '^[a-z][a-z0-9_]{2,19}$');
alter table users add column name text not null default '';

-- Transfers between Avora wallets: free, instant, and never leave the
-- ledger, so they can't get stuck at another bank.
create table p2p_transfers (
    id              uuid primary key default gen_random_uuid(),
    idempotency_key text not null,
    from_wallet     bigint not null references accounts (id),
    to_wallet       bigint not null references accounts (id),
    amount          bigint not null check (amount > 0),
    note            text not null default '',
    created_at      timestamptz not null default now(),
    unique (from_wallet, idempotency_key),
    check (from_wallet <> to_wallet)
);

create index p2p_from on p2p_transfers (from_wallet, created_at);
create index p2p_to on p2p_transfers (to_wallet, created_at);
