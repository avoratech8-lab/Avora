-- Emergency freeze: while set, no money can leave the account (transfers,
-- bills, Avora payments, card payments and scheduled payments are refused).
-- Money can still come in.
alter table users add column frozen_at timestamptz;

-- "Report a problem" on a payment. Each one points at a line on the
-- customer's own statement; ops answers it and the customer is notified.
create table disputes (
    id                uuid primary key default gen_random_uuid(),
    user_id           bigint not null references users (id),
    wallet_account_id bigint not null references wallets (account_id),
    ref               text not null,
    kind              text not null,
    description       text not null,
    amount            bigint not null,
    reason            text not null check (reason in ('not_received', 'wrong_amount', 'not_me', 'charged_twice', 'other')),
    details           text not null default '',
    status            text not null default 'open' check (status in ('open', 'resolved', 'rejected')),
    answer            text not null default '',
    created_at        timestamptz not null default now(),
    closed_at         timestamptz
);

create index disputes_user on disputes (user_id, created_at);
-- One open report per payment.
create unique index disputes_one_open on disputes (user_id, ref) where status = 'open';
