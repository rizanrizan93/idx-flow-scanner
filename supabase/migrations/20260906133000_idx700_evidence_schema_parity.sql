-- Schema-parity repair for the dedicated IDX Flow Scanner database only.
-- Every object created here is isolated to the public.flow_* namespace.

create table if not exists public.flow_zapi_stock_summary (
  ticker text not null check (ticker = upper(ticker) and ticker ~ '^[A-Z0-9]{2,8}$'),
  trade_date date not null,
  foreign_buy numeric,
  foreign_sell numeric,
  foreign_net numeric,
  volume numeric,
  traded_value numeric,
  frequency numeric,
  bid numeric,
  offer numeric,
  bid_volume numeric,
  offer_volume numeric,
  listed_shares numeric not null check (listed_shares > 0),
  tradable_shares numeric not null check (tradable_shares > 0),
  source text not null,
  source_verified boolean not null default false,
  source_url text,
  provenance_state text not null,
  ingested_at timestamptz not null default now(),
  primary key (ticker, trade_date, source),
  check (tradable_shares <= listed_shares * 1.05)
);

create index if not exists flow_zapi_stock_summary_ticker_date_idx
  on public.flow_zapi_stock_summary (ticker, trade_date desc);

create table if not exists public.flow_zapi_ownership (
  ticker text not null check (ticker = upper(ticker) and ticker ~ '^[A-Z0-9]{2,8}$'),
  category text not null,
  holder_identity_hash text not null check (holder_identity_hash ~ '^[0-9a-f]{64}$'),
  holder_name text,
  shares_held numeric check (shares_held is null or shares_held >= 0),
  ownership_percentage numeric check (ownership_percentage is null or ownership_percentage between 0 and 100),
  holder_classification text,
  holder_type text,
  local_foreign_state text,
  report_date date not null,
  report_date_kind text,
  publication_date date,
  source_url text,
  source_file_hash text check (source_file_hash is null or source_file_hash ~ '^[0-9a-f]{64}$'),
  source_verified boolean not null default false,
  provenance_state text not null,
  ingested_at timestamptz not null default now(),
  primary key (ticker, report_date, category, holder_identity_hash)
);

create index if not exists flow_zapi_ownership_ticker_date_idx
  on public.flow_zapi_ownership (ticker, report_date desc);

create table if not exists public.flow_zapi_capital_actions (
  ticker text not null check (ticker = upper(ticker) and ticker ~ '^[A-Z0-9]{2,8}$'),
  event_type text not null,
  event_date date not null,
  event_start_date date,
  event_end_date date,
  publication_date date,
  pre_shares numeric,
  post_shares numeric,
  delta_shares numeric,
  delta_percent numeric,
  ratio_before numeric,
  ratio_after numeric,
  raw_action text,
  source_feed text not null,
  source text,
  source_url text,
  source_verified boolean not null default false,
  observed_on date,
  provenance_state text not null,
  ingested_at timestamptz not null default now(),
  primary key (ticker, event_type, event_date, source_feed)
);

create index if not exists flow_zapi_capital_actions_ticker_date_idx
  on public.flow_zapi_capital_actions (ticker, event_date desc);

create table if not exists public.flow_ownership_evidence (
  ticker text not null check (ticker = upper(ticker) and ticker ~ '^[A-Z0-9]{2,8}$'),
  category text not null,
  holder_identity_hash text not null check (holder_identity_hash ~ '^[0-9a-f]{64}$'),
  holder_name text,
  shares_held numeric check (shares_held is null or shares_held >= 0),
  ownership_percentage numeric check (ownership_percentage is null or ownership_percentage between 0 and 100),
  holder_classification text,
  holder_type text,
  local_foreign_state text,
  report_date date not null,
  report_date_kind text,
  publication_date date,
  source_url text,
  source_file_hash text check (source_file_hash is null or source_file_hash ~ '^[0-9a-f]{64}$'),
  source_verified boolean not null default false,
  provenance_state text not null,
  ingested_at timestamptz not null default now(),
  primary key (ticker, report_date, category, holder_identity_hash)
);

create index if not exists flow_ownership_evidence_ticker_date_idx
  on public.flow_ownership_evidence (ticker, report_date desc);
create index if not exists flow_ownership_evidence_provenance_idx
  on public.flow_ownership_evidence (provenance_state, report_date desc);

create table if not exists public.flow_capital_action_evidence (
  ticker text not null check (ticker = upper(ticker) and ticker ~ '^[A-Z0-9]{2,8}$'),
  event_type text not null,
  event_date date not null,
  event_start_date date,
  event_end_date date,
  publication_date date,
  pre_shares numeric,
  post_shares numeric,
  delta_shares numeric,
  delta_percent numeric,
  ratio_before numeric,
  ratio_after numeric,
  raw_action text,
  source_feed text not null,
  source text,
  source_url text,
  source_verified boolean not null default false,
  validation_state text,
  provenance_state text not null,
  observed_on date,
  ingested_at timestamptz not null default now(),
  primary key (ticker, event_type, event_date, source_feed)
);

create index if not exists flow_capital_action_evidence_ticker_date_idx
  on public.flow_capital_action_evidence (ticker, event_date desc);
create index if not exists flow_capital_action_evidence_provenance_idx
  on public.flow_capital_action_evidence (provenance_state, event_date desc);

alter table public.flow_zapi_stock_summary enable row level security;
alter table public.flow_zapi_ownership enable row level security;
alter table public.flow_zapi_capital_actions enable row level security;
alter table public.flow_ownership_evidence enable row level security;
alter table public.flow_capital_action_evidence enable row level security;

revoke all on table public.flow_zapi_stock_summary from public, anon, authenticated;
revoke all on table public.flow_zapi_ownership from public, anon, authenticated;
revoke all on table public.flow_zapi_capital_actions from public, anon, authenticated;
revoke all on table public.flow_ownership_evidence from public, anon, authenticated;
revoke all on table public.flow_capital_action_evidence from public, anon, authenticated;

grant select, insert, update, delete on table public.flow_zapi_stock_summary to service_role;
grant select, insert, update, delete on table public.flow_zapi_ownership to service_role;
grant select, insert, update, delete on table public.flow_zapi_capital_actions to service_role;
grant select, insert, update, delete on table public.flow_ownership_evidence to service_role;
grant select, insert, update, delete on table public.flow_capital_action_evidence to service_role;

comment on table public.flow_zapi_stock_summary is
  'Verified legacy/fallback stock-summary evidence. TradebleShares is not regulatory free float.';
comment on table public.flow_zapi_ownership is
  'Verified legacy/fallback ownership evidence kept separate from canonical ownership history.';
comment on table public.flow_zapi_capital_actions is
  'Verified legacy/fallback capital-action evidence kept separate from canonical official evidence.';
comment on table public.flow_ownership_evidence is
  'Canonical slow-moving ownership evidence for IDX Flow Scanner, including verified KSEI registration-composition history.';
comment on table public.flow_capital_action_evidence is
  'Canonical factual capital-action evidence for IDX Flow Scanner. No absent-row inference is permitted.';
