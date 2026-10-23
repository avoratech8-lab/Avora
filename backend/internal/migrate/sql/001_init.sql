-- Ledger: every naira movement is a balanced journal of signed entries
-- (debit positive, credit negative). Balances are a cache of the entries,
-- kept on each account's normal side, and checked by ledger.Check.

create table accounts (
    id             bigserial primary key,
    code           text unique not null,
    kind           text not null check (kind in ('asset', 'liability', 'income', 'expense')),
    allow_negative boolean not null default false,
    balance        bigint not null default 0,
    created_at     timestamptz not null default now()
);

create table journals (
    id              bigserial primary key,
    idempotency_key text unique not null,
    kind            text not null,
    description     text not null,
    ref             text not null default '',
    created_at      timestamptz not null default now()
);

create table entries (
    id         bigserial primary key,
    journal_id bigint not null references journals (id),
    account_id bigint not null references accounts (id),
    amount     bigint not null check (amount <> 0),
    created_at timestamptz not null default now()
);

create index entries_account_idx on entries (account_id, id);
create index entries_journal_idx on entries (journal_id);

-- A journal must sum to zero by the time its transaction commits.
create function journal_must_balance() returns trigger
language plpgsql as $$
declare
    total bigint;
begin
    select coalesce(sum(amount), 0) into total from entries where journal_id = new.journal_id;
    if total <> 0 then
        raise exception 'journal % does not balance (sum %)', new.journal_id, total;
    end if;
    return null;
end $$;

create constraint trigger entries_balanced
    after insert on entries
    deferrable initially deferred
    for each row execute function journal_must_balance();

-- History is never edited: corrections are new journals.
create function forbid_change() returns trigger
language plpgsql as $$
begin
    raise exception '% is append-only', tg_table_name;
end $$;

create trigger entries_append_only before update or delete on entries
    for each row execute function forbid_change();
create trigger journals_append_only before update or delete on journals
    for each row execute function forbid_change();

insert into accounts (code, kind, allow_negative) values
    ('system:in_flight',   'liability', false),
    ('system:settlement',  'asset',     true),
    ('system:fee_revenue', 'income',    false),
    ('system:emtl_payable','liability', false);

create table wallets (
    account_id bigint primary key references accounts (id),
    user_ref   text unique not null,
    nuban      text unique not null,
    created_at timestamptz not null default now()
);

create table transfers (
    id                uuid primary key default gen_random_uuid(),
    idempotency_key   text unique not null,
    wallet_account_id bigint not null references wallets (account_id),
    bank_code         text not null,
    account_number    text not null,
    account_name      text not null,
    narration         text not null default '',
    amount            bigint not null check (amount > 0),
    fee               bigint not null check (fee >= 0),
    status            text not null check (status in ('held', 'sent', 'delivered', 'refunded', 'needs_review')),
    session_id        text,
    failure_reason    text,
    requery_count     int not null default 0,
    next_requery_at   timestamptz,
    created_at        timestamptz not null default now(),
    updated_at        timestamptz not null default now()
);

create index transfers_requery_idx on transfers (next_requery_at) where status in ('held', 'sent');
create index transfers_wallet_idx on transfers (wallet_account_id, created_at);

create table inbound_credits (
    session_id        text primary key,
    wallet_account_id bigint not null references wallets (account_id),
    amount            bigint not null check (amount > 0),
    levy              bigint not null default 0,
    sender_name       text not null default '',
    sender_bank       text not null default '',
    created_at        timestamptz not null default now()
);
