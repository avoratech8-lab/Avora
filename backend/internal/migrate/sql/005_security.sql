-- KYC tiers. Tier 1 is phone only; a verified BVN or NIN gives tier 2;
-- both give tier 3. Only the last four digits are kept.
alter table users add column kyc_tier int not null default 1 check (kyc_tier between 1 and 3);
alter table users add column bvn_last4 text not null default '';
alter table users add column nin_last4 text not null default '';

-- A friendly name for each phone, shown on the Devices screen.
alter table devices add column name text not null default '';

-- The in-app inbox.
create table notifications (
    id                bigserial primary key,
    wallet_account_id bigint not null references accounts (id),
    kind              text not null,
    title             text not null,
    body              text not null default '',
    ref               text not null default '',
    created_at        timestamptz not null default now(),
    read_at           timestamptz
);

create index notifications_wallet on notifications (wallet_account_id, id desc);
