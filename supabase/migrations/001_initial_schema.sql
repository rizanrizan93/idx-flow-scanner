-- IDX Flow Scanner v0.1.1
-- Private backend database contract. All exposed public tables have RLS enabled,
-- and anon/authenticated table privileges are revoked.

create extension if not exists pgcrypto;

create table if not exists public.flow_issuers (
    ticker text primary key check (ticker = upper(ticker) and length(ticker) between 2 and 8),
    issuer_name text,
    sector text,
    subsector text,
    active boolean not null default true,
    updated_at timestamptz not null default now()
);

create table if not exists public.flow_daily_prices (
    ticker text not null,
    trade_date date not null,
    open numeric,
    high numeric,
    low numeric,
    close numeric not null check (close > 0),
    volume numeric,
    traded_value numeric,
    foreign_net_value numeric,
    source text not null,
    source_timestamp timestamptz,
    ingested_at timestamptz not null default now(),
    primary key (ticker, trade_date, source)
);
create index if not exists flow_daily_prices_ticker_date_idx on public.flow_daily_prices (ticker, trade_date desc);

create table if not exists public.flow_broker_flows (
    ticker text not null,
    trade_date date not null,
    broker_code text not null,
    market_type text not null default 'REGULAR',
    buy_value numeric not null default 0 check (buy_value >= 0),
    sell_value numeric not null default 0 check (sell_value >= 0),
    buy_volume numeric not null default 0 check (buy_volume >= 0),
    sell_volume numeric not null default 0 check (sell_volume >= 0),
    buy_avg numeric,
    sell_avg numeric,
    source text not null,
    source_timestamp timestamptz,
    ingested_at timestamptz not null default now(),
    primary key (ticker, trade_date, broker_code, market_type, source)
);
create index if not exists flow_broker_flows_ticker_date_idx on public.flow_broker_flows (ticker, trade_date desc);
create index if not exists flow_broker_flows_broker_date_idx on public.flow_broker_flows (broker_code, trade_date desc);

create table if not exists public.flow_feature_snapshots (
    ticker text not null,
    as_of_date date not null,
    evidence_tier text not null check (evidence_tier in ('BROKER_DIRECT','PRICE_PROXY')),
    evidence_coverage_pct numeric not null check (evidence_coverage_pct between 0 and 100),
    accumulation_score numeric check (accumulation_score between 0 and 100),
    operator_dominance_score numeric check (operator_dominance_score between 0 and 100),
    cost_basis_score numeric check (cost_basis_score between 0 and 100),
    retail_exhaustion_score numeric check (retail_exhaustion_score between 0 and 100),
    supply_concentration_score numeric check (supply_concentration_score between 0 and 100),
    price_flow_divergence_score numeric check (price_flow_divergence_score between 0 and 100),
    smc_execution_score numeric check (smc_execution_score between 0 and 100),
    risk_liquidity_score numeric check (risk_liquidity_score between 0 and 100),
    distribution_risk numeric check (distribution_risk between 0 and 100),
    estimated_smart_money_cost numeric,
    premium_to_cost_pct numeric,
    diagnostics jsonb not null default '{}'::jsonb,
    created_at timestamptz not null default now(),
    primary key (ticker, as_of_date)
);

create table if not exists public.flow_scan_runs (
    id uuid primary key default gen_random_uuid(),
    status text not null check (status in ('RUNNING','COMPLETED','FAILED','CANCELLED')),
    universe_count integer not null default 0 check (universe_count >= 0),
    processed_count integer not null default 0 check (processed_count >= 0),
    error_count integer not null default 0 check (error_count >= 0),
    config jsonb not null default '{}'::jsonb,
    started_at timestamptz not null default now(),
    completed_at timestamptz
);

create table if not exists public.flow_scan_results (
    run_id uuid not null references public.flow_scan_runs(id) on delete cascade,
    ticker text not null,
    as_of_date date not null,
    final_score numeric not null check (final_score between 0 and 100),
    phase text not null,
    action text not null,
    evidence_tier text not null,
    evidence_coverage_pct numeric not null check (evidence_coverage_pct between 0 and 100),
    real_money_state text not null,
    distribution_risk numeric,
    estimated_smart_money_cost numeric,
    premium_to_cost_pct numeric,
    entry_low numeric,
    entry_high numeric,
    invalidation numeric,
    tp1 numeric,
    tp2 numeric,
    components jsonb not null default '{}'::jsonb,
    diagnostics jsonb not null default '{}'::jsonb,
    guardrail_reason text,
    created_at timestamptz not null default now(),
    primary key (run_id, ticker)
);
create index if not exists flow_scan_results_score_idx on public.flow_scan_results (run_id, final_score desc);
create index if not exists flow_scan_results_ticker_idx on public.flow_scan_results (ticker, as_of_date desc);

create table if not exists public.flow_ingestion_audit (
    id bigint generated always as identity primary key,
    provider text not null,
    dataset text not null,
    ticker text,
    started_at timestamptz not null default now(),
    completed_at timestamptz,
    status text not null,
    rows_received integer not null default 0,
    rows_accepted integer not null default 0,
    rows_rejected integer not null default 0,
    freshness_date date,
    error_code text,
    details jsonb not null default '{}'::jsonb
);
create index if not exists flow_ingestion_audit_provider_idx on public.flow_ingestion_audit (provider, dataset, started_at desc);

alter table public.flow_issuers enable row level security;
alter table public.flow_daily_prices enable row level security;
alter table public.flow_broker_flows enable row level security;
alter table public.flow_feature_snapshots enable row level security;
alter table public.flow_scan_runs enable row level security;
alter table public.flow_scan_results enable row level security;
alter table public.flow_ingestion_audit enable row level security;

revoke all on table public.flow_issuers from anon, authenticated;
revoke all on table public.flow_daily_prices from anon, authenticated;
revoke all on table public.flow_broker_flows from anon, authenticated;
revoke all on table public.flow_feature_snapshots from anon, authenticated;
revoke all on table public.flow_scan_runs from anon, authenticated;
revoke all on table public.flow_scan_results from anon, authenticated;
revoke all on table public.flow_ingestion_audit from anon, authenticated;
revoke usage, select on all sequences in schema public from anon, authenticated;

comment on table public.flow_broker_flows is 'Direct broker-summary evidence. Never populate with price-volume proxy data.';
comment on column public.flow_feature_snapshots.evidence_tier is 'BROKER_DIRECT only when direct broker-summary coverage passes configured threshold; otherwise PRICE_PROXY.';
