-- Airtime, data, electricity and TV payments. Money is held in
-- system:in_flight while the biller is asked, then settles out of the
-- pooled settlement account, or goes back to the wallet in full.
create table bill_payments (
    id                uuid primary key default gen_random_uuid(),
    idempotency_key   text unique not null,
    wallet_account_id bigint not null references accounts (id),
    biller_id         text not null,
    biller_name       text not null,
    category          text not null check (category in ('airtime', 'data', 'electricity', 'tv')),
    plan_code         text not null default '',
    plan_name         text not null default '',
    customer          text not null,
    customer_name     text not null default '',
    amount            bigint not null check (amount > 0),
    status            text not null check (status in ('pending', 'success', 'refunded')),
    token             text not null default '',
    reference         text not null default '',
    failure_reason    text not null default '',
    created_at        timestamptz not null default now(),
    updated_at        timestamptz not null default now()
);

create index bill_payments_wallet on bill_payments (wallet_account_id, created_at desc);
create index bill_payments_pending on bill_payments (created_at) where status = 'pending';
