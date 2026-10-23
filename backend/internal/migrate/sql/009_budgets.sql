-- Monthly budgets, per spending category or "all", and the alerts already
-- sent so each one goes out once a month.
create table budgets (
    wallet_account_id bigint not null references wallets (account_id),
    category          text not null,
    amount            bigint not null check (amount > 0),
    updated_at        timestamptz not null default now(),
    primary key (wallet_account_id, category)
);

create table budget_alerts (
    wallet_account_id bigint not null references wallets (account_id),
    category          text not null,
    month             text not null, -- 2026-10
    level             int not null check (level in (80, 100)),
    primary key (wallet_account_id, category, month, level)
);
