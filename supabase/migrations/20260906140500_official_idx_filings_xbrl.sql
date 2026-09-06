create table if not exists public.flow_filing_evidence (
  ticker text not null,
  filing_id text not null,
  publication_date date,
  report_year integer,
  report_period text,
  document_type text not null,
  title text,
  discovery_source text not null,
  official_source_url text,
  official_attachment_url text,
  source_verified boolean not null default false,
  source_file_hash text,
  source_file_size_bytes bigint,
  provenance_state text not null,
  metadata jsonb not null default '{}'::jsonb,
  ingested_at timestamptz not null default now(),
  primary key (ticker, filing_id)
);

create index if not exists flow_filing_evidence_ticker_pub_idx
  on public.flow_filing_evidence (ticker, publication_date desc);
create index if not exists flow_filing_evidence_period_idx
  on public.flow_filing_evidence (report_year desc, report_period, ticker);

create table if not exists public.flow_xbrl_facts (
  ticker text not null,
  filing_id text not null,
  source_file_hash text not null,
  concept_namespace text not null default '',
  concept_local_name text not null,
  context_id text not null,
  entity_identifier text,
  period_start date,
  period_end date,
  instant_date date,
  unit text not null default '',
  decimals text,
  scale integer,
  numeric_value numeric,
  text_value text,
  is_consolidated boolean,
  dimensions jsonb not null default '[]'::jsonb,
  source_url text not null,
  taxonomy_state text not null,
  verified boolean not null default false,
  provenance_state text not null,
  ingested_at timestamptz not null default now(),
  primary key (ticker, source_file_hash, concept_namespace, concept_local_name, context_id, unit)
);

create index if not exists flow_xbrl_facts_ticker_period_idx
  on public.flow_xbrl_facts (ticker, period_end desc, instant_date desc);
create index if not exists flow_xbrl_facts_concept_idx
  on public.flow_xbrl_facts (concept_local_name, ticker);

create table if not exists public.flow_financial_metrics (
  ticker text not null,
  report_year integer not null,
  report_period text not null,
  report_end_date date not null,
  metric_name text not null,
  metric_value numeric not null,
  unit text not null,
  source_concept_namespace text not null default '',
  source_concept_local_name text not null,
  source_context_id text not null,
  source_file_hash text not null,
  source_url text not null,
  taxonomy_state text not null,
  derivation_state text not null,
  verified boolean not null default false,
  provenance_state text not null,
  ingested_at timestamptz not null default now(),
  primary key (ticker, report_year, report_period, metric_name, source_file_hash)
);

create index if not exists flow_financial_metrics_latest_idx
  on public.flow_financial_metrics (ticker, report_year desc, report_period, metric_name);

create table if not exists public.flow_event_evidence (
  ticker text not null,
  event_id text not null,
  publication_date timestamptz not null,
  event_category text not null,
  title text not null,
  subject text,
  announcement_number text,
  form_id text,
  official_source_url text not null,
  official_attachment_url text,
  source_verified boolean not null default false,
  source_file_hash text,
  provenance_state text not null,
  metadata jsonb not null default '{}'::jsonb,
  ingested_at timestamptz not null default now(),
  primary key (ticker, event_id, event_category)
);

create index if not exists flow_event_evidence_ticker_date_idx
  on public.flow_event_evidence (ticker, publication_date desc);
create index if not exists flow_event_evidence_category_date_idx
  on public.flow_event_evidence (event_category, publication_date desc);

create table if not exists public.flow_filing_ingestion_runs (
  run_id text primary key,
  started_at timestamptz not null,
  completed_at timestamptz,
  source text not null,
  requested_periods jsonb not null default '[]'::jsonb,
  universe_count integer not null default 0,
  discovered_filing_count integer not null default 0,
  verified_filing_count integer not null default 0,
  fact_row_count integer not null default 0,
  metric_row_count integer not null default 0,
  event_row_count integer not null default 0,
  covered_ticker_count integer not null default 0,
  status text not null,
  errors jsonb not null default '[]'::jsonb
);

alter table public.flow_filing_evidence enable row level security;
alter table public.flow_xbrl_facts enable row level security;
alter table public.flow_financial_metrics enable row level security;
alter table public.flow_event_evidence enable row level security;
alter table public.flow_filing_ingestion_runs enable row level security;

revoke all on public.flow_filing_evidence from public, anon, authenticated;
revoke all on public.flow_xbrl_facts from public, anon, authenticated;
revoke all on public.flow_financial_metrics from public, anon, authenticated;
revoke all on public.flow_event_evidence from public, anon, authenticated;
revoke all on public.flow_filing_ingestion_runs from public, anon, authenticated;

grant all on public.flow_filing_evidence to service_role;
grant all on public.flow_xbrl_facts to service_role;
grant all on public.flow_financial_metrics to service_role;
grant all on public.flow_event_evidence to service_role;
grant all on public.flow_filing_ingestion_runs to service_role;

alter table public.flow_filing_evidence
  add constraint flow_filing_evidence_hash_chk
  check (source_file_hash is null or source_file_hash ~ '^[0-9a-f]{64}$') not valid;
alter table public.flow_xbrl_facts
  add constraint flow_xbrl_facts_hash_chk
  check (source_file_hash ~ '^[0-9a-f]{64}$') not valid;
alter table public.flow_financial_metrics
  add constraint flow_financial_metrics_hash_chk
  check (source_file_hash ~ '^[0-9a-f]{64}$') not valid;
alter table public.flow_event_evidence
  add constraint flow_event_evidence_hash_chk
  check (source_file_hash is null or source_file_hash ~ '^[0-9a-f]{64}$') not valid;

alter table public.flow_filing_evidence validate constraint flow_filing_evidence_hash_chk;
alter table public.flow_xbrl_facts validate constraint flow_xbrl_facts_hash_chk;
alter table public.flow_financial_metrics validate constraint flow_financial_metrics_hash_chk;
alter table public.flow_event_evidence validate constraint flow_event_evidence_hash_chk;
