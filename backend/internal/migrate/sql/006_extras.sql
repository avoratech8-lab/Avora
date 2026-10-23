-- Referrals: each customer gets a code to share. When someone who joined
-- with it verifies a BVN or NIN (tier 2), the inviter earns a reward, paid
-- from the marketing budget.
insert into accounts (code, kind, allow_negative) values ('system:referral_rewards', 'expense', false);

alter table users add column referral_code text unique;

create table referrals (
    referee_user_id  bigint primary key references users (id),
    referrer_user_id bigint not null references users (id),
    reward           bigint not null default 0,
    created_at       timestamptz not null default now(),
    rewarded_at      timestamptz,
    check (referee_user_id <> referrer_user_id)
);

create index referrals_referrer on referrals (referrer_user_id);

-- Support chat. "bot" answers come from the help centre articles.
create table support_messages (
    id         bigserial primary key,
    user_id    bigint not null references users (id),
    sender     text not null check (sender in ('customer', 'bot', 'agent')),
    body       text not null,
    created_at timestamptz not null default now()
);

create index support_messages_user on support_messages (user_id, id);
