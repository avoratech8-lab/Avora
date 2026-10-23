create table users (
    id                  bigserial primary key,
    phone               text unique not null, -- +234XXXXXXXXXX
    pin_hash            text not null,
    failed_pin_attempts int not null default 0,
    locked_until        timestamptz,
    wallet_account_id   bigint unique not null references wallets (account_id),
    created_at          timestamptz not null default now()
);

create table otp_challenges (
    id          uuid primary key default gen_random_uuid(),
    phone       text not null,
    code_hash   text not null,
    attempts    int not null default 0,
    expires_at  timestamptz not null,
    consumed_at timestamptz,
    created_at  timestamptz not null default now()
);

create index otp_challenges_phone_idx on otp_challenges (phone, created_at);

-- A device is bound to one user after OTP and PIN. Transfers from a device
-- bound in the last 24 hours are capped unless it was the user's first.
create table devices (
    id           bigserial primary key,
    user_id      bigint not null references users (id),
    device_id    text not null,
    first_device boolean not null,
    bound_at     timestamptz not null default now(),
    unique (user_id, device_id)
);

create table sessions (
    token_hash text primary key, -- sha256 of the bearer token; the token itself is never stored
    user_id    bigint not null references users (id),
    device_id  text not null,
    expires_at timestamptz not null,
    created_at timestamptz not null default now()
);

create index sessions_user_idx on sessions (user_id);
