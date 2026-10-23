-- Cashback on airtime and data, paid from the marketing budget once the
-- biller confirms. Internet (Spectranet, Smile), exam PINs (WAEC, NECO,
-- JAMB) and betting wallet top-ups join the bill categories.
insert into accounts (code, kind, allow_negative) values ('system:cashback', 'expense', false);

alter table bill_payments add column cashback bigint not null default 0 check (cashback >= 0);

alter table bill_payments drop constraint bill_payments_category_check;
alter table bill_payments add constraint bill_payments_category_check
    check (category in ('airtime', 'data', 'electricity', 'tv', 'internet', 'education', 'betting'));
