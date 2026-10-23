-- Scheduled payments: a transfer, Avora transfer, bill or savings deposit
-- that runs once or repeats. The customer approves it with their PIN when
-- setting it up; each run has its own idempotency key.
create table schedules (
    id                uuid primary key default gen_random_uuid(),
    user_id           bigint not null references users (id),
    wallet_account_id bigint not null references wallets (account_id),
    kind              text not null check (kind in ('transfer', 'avora', 'bill', 'savings')),
    name              text not null,
    amount            bigint not null check (amount > 0),
    frequency         text not null check (frequency in ('once', 'daily', 'weekly', 'monthly')),
    starts_at         timestamptz not null,
    next_run          timestamptz not null,
    runs              int not null default 0,
    status            text not null default 'active' check (status in ('active', 'paused', 'done', 'cancelled')),
    target            jsonb not null, -- bank_code/account_number/account_name, to, biller_id/plan_code/customer, pot_id
    last_run_at       timestamptz,
    last_ok           boolean,
    last_message      text not null default '',
    created_at        timestamptz not null default now()
);

create index schedules_due on schedules (next_run) where status = 'active';
create index schedules_user on schedules (user_id, created_at);

-- Split bills: someone paid, and asks others on Avora for their share.
create table splits (
    id              uuid primary key default gen_random_uuid(),
    creator_user_id bigint not null references users (id),
    title           text not null,
    total           bigint not null check (total > 0),
    created_at      timestamptz not null default now()
);

create table split_shares (
    split_id   uuid not null references splits (id),
    user_id    bigint not null references users (id),
    amount     bigint not null check (amount > 0),
    status     text not null default 'pending' check (status in ('pending', 'paid', 'declined')),
    p2p_id     uuid,
    updated_at timestamptz not null default now(),
    primary key (split_id, user_id)
);

create index split_shares_user on split_shares (user_id, status);
