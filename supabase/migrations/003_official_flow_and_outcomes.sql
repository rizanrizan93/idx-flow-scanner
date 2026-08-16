-- IDX Flow Scanner v0.1.5
-- Free official IDX foreign-flow cache + walk-forward outcome memory.

create table if not exists public.flow_official_stock_flows (
    ticker text not null,
    trade_date date not null,
    foreign_buy numeric not null default 0,
    foreign_sell numeric not null default 0,
    foreign_net numeric not null default 0,
    traded_value numeric not null default 0,
    volume numeric not null default 0,
    frequency numeric not null default 0,
    bid numeric,
    offer numeric,
    bid_volume numeric,
    offer_volume numeric,
    listed_shares numeric,
    tradable_shares numeric,
    source text not null default 'IDX_OFFICIAL_STOCK_SUMMARY',
    ingested_at timestamptz not null default now(),
    primary key (ticker, trade_date, source)
);
create index if not exists flow_official_stock_flows_ticker_date_idx
    on public.flow_official_stock_flows (ticker, trade_date desc);

create table if not exists public.flow_signal_outcomes (
    run_id uuid not null references public.flow_scan_runs(id) on delete cascade,
    ticker text not null,
    as_of_date date not null,
    phase text not null,
    evidence_tier text not null,
    final_score numeric not null,
    entry_close numeric,
    return_5d numeric,
    return_20d numeric,
    return_60d numeric,
    mfe_20d numeric,
    mae_20d numeric,
    evaluated_through date,
    evaluation_status text not null default 'PENDING' check (evaluation_status in ('PENDING','PARTIAL','COMPLETE')),
    evaluated_at timestamptz,
    primary key (run_id, ticker)
);
create index if not exists flow_signal_outcomes_ticker_date_idx
    on public.flow_signal_outcomes (ticker, as_of_date desc);

alter table public.flow_scan_runs add column if not exists official_flow_days integer not null default 0;
alter table public.flow_scan_runs add column if not exists official_flow_tickers integer not null default 0;

alter table public.flow_official_stock_flows enable row level security;
alter table public.flow_signal_outcomes enable row level security;

revoke all on table public.flow_official_stock_flows from anon, authenticated;
revoke all on table public.flow_signal_outcomes from anon, authenticated;
grant select, insert, update, delete on table public.flow_official_stock_flows to service_role;
grant select, insert, update, delete on table public.flow_signal_outcomes to service_role;

comment on table public.flow_official_stock_flows is 'Official IDX per-stock ForeignBuy/ForeignSell and daily market summary. This is official foreign-flow evidence, not broker-direct identity evidence.';
comment on table public.flow_signal_outcomes is 'Walk-forward outcome memory for OOS calibration of Flow Scanner scores and phases.';
