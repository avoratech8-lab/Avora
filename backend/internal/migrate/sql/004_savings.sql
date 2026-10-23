-- Non-interest savings. Each pot is its own ledger account. Profit is a
-- share of what the partner bank earns on the pooled deposits (mudarabah):
-- declared after each period, never promised in advance.
insert into accounts (code, kind, allow_negative) values ('system:profit_share', 'expense', false);

create table savings_pots (
    id                uuid primary key default gen_random_uuid(),
    wallet_account_id bigint not null references accounts (id),
    account_id        bigint unique not null references accounts (id),
    kind              text not null check (kind in ('goal', 'locked')),
    name              text not null,
    target            bigint not null default 0 check (target >= 0),
    lock_days         int not null default 0,
    matures_at        timestamptz,
    profit_earned     bigint not null default 0,
    status            text not null default 'open' check (status in ('open', 'closed')),
    created_at        timestamptz not null default now(),
    closed_at         timestamptz
);

create index savings_pots_wallet on savings_pots (wallet_account_id, created_at);

-- One row per declared period, so a period's profit is shared only once.
create table savings_profit_runs (
    period          text primary key,
    goal_rate_bps   int not null,
    locked_rate_bps int not null,
    pots            int not null,
    total           bigint not null,
    created_at      timestamptz not null default now()
);
