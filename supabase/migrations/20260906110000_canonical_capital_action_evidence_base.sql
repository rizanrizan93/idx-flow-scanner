create table if not exists public.flow_capital_action_evidence (
  ticker text not null check (ticker = upper(ticker) and ticker ~ '^[A-Z0-9]{1,10}$'),
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
  primary key (ticker,event_type,event_date,source_feed)
);

create index if not exists flow_capital_action_evidence_ticker_date_idx
  on public.flow_capital_action_evidence (ticker,event_date desc);

alter table public.flow_capital_action_evidence enable row level security;
revoke all on table public.flow_capital_action_evidence from public,anon,authenticated;
grant select,insert,update,delete on table public.flow_capital_action_evidence to service_role;
