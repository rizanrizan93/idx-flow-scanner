-- Evidence Expansion — point-in-time foundation.
-- Official-first. ZAPI/mirrors are discovery/index aids only and never evidence authority.
-- No production scoring or Phase4D/4E promotion logic is changed here.

create table if not exists public.flow_evidence_source_registry_v5 (
  source_key text primary key,
  evidence_domain text not null check (evidence_domain in ('FUNDAMENTAL','DISCLOSURE','OWNERSHIP')),
  canonical_authority text not null,
  authority_level text not null check (authority_level in ('OFFICIAL_PRIMARY','OFFICIAL_SECONDARY')),
  source_url text not null,
  discovery_method text not null,
  discovery_only_proxy text,
  official_evidence_url_required boolean not null default true,
  point_in_time_eligible boolean not null default true,
  historical_depth_note text not null,
  freshness_cadence text not null,
  extraction_state text not null default 'FOUNDATION_ONLY',
  provenance_policy text not null,
  source_verified boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

insert into public.flow_evidence_source_registry_v5(
  source_key,evidence_domain,canonical_authority,authority_level,source_url,discovery_method,
  discovery_only_proxy,official_evidence_url_required,point_in_time_eligible,historical_depth_note,
  freshness_cadence,provenance_policy
) values
(
  'IDX_XBRL_FINANCIAL_REPORT','FUNDAMENTAL','INDONESIA_STOCK_EXCHANGE','OFFICIAL_PRIMARY',
  'https://www.idx.co.id/id/perusahaan-tercatat/xbrl/',
  'IDX_XBRL_OR_OFFICIAL_FINANCIAL_REPORT_FILE_INDEX','ZAPI_FINANCIAL_REPORT_INDEX_ONLY',true,true,
  'IDX states XBRL financial reporting has been used since 2015; ingest only filings with observable publication/modified timestamp.',
  'QUARTERLY_AND_ANNUAL',
  'OFFICIAL_IDX_FILE_URL_PLUS_PUBLICATION_TIME_REQUIRED; NEVER BACKDATE KNOWLEDGE TO REPORT_PERIOD_END'
),
(
  'IDX_DISCLOSURE_ANNOUNCEMENT','DISCLOSURE','INDONESIA_STOCK_EXCHANGE','OFFICIAL_PRIMARY',
  'https://www.idx.id/en/listed-companies/disclosure',
  'IDX_DISCLOSURE_OR_ANNOUNCEMENT_INDEX','ZAPI_ANNOUNCEMENTS_INDEX_ONLY',true,true,
  'Public IDX announcement interface states three years are available; older history must not be invented.',
  'INTRADAY_EVENT_DRIVEN',
  'OFFICIAL_IDX_ANNOUNCEMENT_ID_AND_PUBLISHED_AT_REQUIRED; ATTACHMENTS MUST RESOLVE TO OFFICIAL IDX OR VERIFIED ISSUER URL'
),
(
  'KSEI_HOLDING_COMPOSITION','OWNERSHIP','KUSTODIAN_SENTRAL_EFEK_INDONESIA','OFFICIAL_PRIMARY',
  'https://web.ksei.co.id/archive_download/holding_composition',
  'KSEI_MONTHLY_ARCHIVE_DIRECT',null,true,true,
  'Monthly local/foreign holding-composition archive; preserve each report/snapshot date exactly as published.',
  'MONTHLY',
  'OFFICIAL_KSEI_ARCHIVE_FILE_AND_SNAPSHOT_DATE_REQUIRED'
),
(
  'IDX_KSEI_MAJOR_HOLDER_FILE','OWNERSHIP','IDX_AND_KSEI','OFFICIAL_PRIMARY',
  'https://www.idx.id/',
  'OFFICIAL_IDX_OWNERSHIP_FILE_INDEX','ZAPI_OWNERSHIP_FILES_INDEX_ONLY',true,true,
  'IDX/KSEI public major-shareholder publication introduced in 2026; use only actually published snapshots/files.',
  'DAILY_OR_MONTHLY_BY_PUBLICATION_CATEGORY',
  'OFFICIAL_IDX_FILE_URL_REQUIRED; ONE_PERCENT_AND_FIVE_PERCENT_CATEGORIES_MUST_RETAIN_PUBLICATION_DATE'
)
on conflict(source_key) do update set
  evidence_domain=excluded.evidence_domain,
  canonical_authority=excluded.canonical_authority,
  authority_level=excluded.authority_level,
  source_url=excluded.source_url,
  discovery_method=excluded.discovery_method,
  discovery_only_proxy=excluded.discovery_only_proxy,
  official_evidence_url_required=excluded.official_evidence_url_required,
  point_in_time_eligible=excluded.point_in_time_eligible,
  historical_depth_note=excluded.historical_depth_note,
  freshness_cadence=excluded.freshness_cadence,
  provenance_policy=excluded.provenance_policy,
  source_verified=excluded.source_verified,
  updated_at=now();

create table if not exists public.flow_financial_filing_evidence_v5 (
  filing_id text primary key,
  ticker text not null,
  report_year integer not null check(report_year between 1990 and 2100),
  report_period text not null check(report_period in ('TW1','TW2','TW3','AUDIT')),
  report_period_end date,
  published_at timestamptz not null,
  file_modified_at timestamptz,
  file_url text not null,
  file_name text not null,
  file_type text,
  report_type text,
  source_key text not null references public.flow_evidence_source_registry_v5(source_key),
  content_hash text,
  publication_time_verified boolean not null default false,
  source_verified boolean not null default false,
  point_in_time_eligible boolean not null default false,
  extraction_state text not null default 'FILE_INDEXED',
  provenance_state text not null default 'OFFICIAL_IDX_FINANCIAL_FILING_POINT_IN_TIME',
  ingested_at timestamptz not null default now(),
  unique(ticker,report_year,report_period,file_url)
);

create table if not exists public.flow_financial_fact_evidence_v5 (
  fact_id text primary key,
  filing_id text not null references public.flow_financial_filing_evidence_v5(filing_id) on delete cascade,
  ticker text not null,
  metric_key text not null,
  metric_label text,
  taxonomy_concept text,
  statement_type text,
  metric_value numeric,
  unit text,
  currency text,
  period_start date,
  period_end date,
  instant_date date,
  fact_state text not null default 'PARSED_NOT_VALIDATED',
  source_verified boolean not null default false,
  point_in_time_eligible boolean not null default false,
  provenance_state text not null default 'OFFICIAL_IDX_XBRL_OR_FINANCIAL_FILE_FACT',
  ingested_at timestamptz not null default now()
);

create table if not exists public.flow_disclosure_evidence_v5 (
  announcement_id text primary key,
  ticker text,
  published_at timestamptz not null,
  announcement_no text,
  title text not null,
  disclosure_type text,
  official_detail_url text,
  attachment_urls jsonb not null default '[]'::jsonb,
  source_key text not null references public.flow_evidence_source_registry_v5(source_key),
  content_hash text,
  publication_time_verified boolean not null default false,
  source_verified boolean not null default false,
  point_in_time_eligible boolean not null default false,
  narrative_extraction_state text not null default 'METADATA_ONLY',
  provenance_state text not null default 'OFFICIAL_IDX_DISCLOSURE_POINT_IN_TIME',
  ingested_at timestamptz not null default now()
);

create table if not exists public.flow_major_holder_ownership_evidence_v5 (
  snapshot_date date not null,
  published_at timestamptz not null,
  ticker text not null,
  holder_identity_hash text not null,
  holder_name text,
  holder_type text,
  local_foreign_state text,
  shares_held numeric,
  ownership_pct numeric check(ownership_pct is null or ownership_pct between 0 and 100),
  threshold_category text not null check(threshold_category in ('ONE_PERCENT','FIVE_PERCENT')),
  file_url text not null,
  source_key text not null references public.flow_evidence_source_registry_v5(source_key),
  content_hash text,
  source_verified boolean not null default false,
  point_in_time_eligible boolean not null default false,
  provenance_state text not null default 'OFFICIAL_IDX_KSEI_MAJOR_HOLDER_POINT_IN_TIME',
  ingested_at timestamptz not null default now(),
  primary key(snapshot_date,ticker,holder_identity_hash,threshold_category)
);

create index if not exists flow_financial_filing_v5_ticker_pub_idx
  on public.flow_financial_filing_evidence_v5(ticker,published_at desc);
create index if not exists flow_financial_fact_v5_ticker_metric_idx
  on public.flow_financial_fact_evidence_v5(ticker,metric_key,period_end desc);
create index if not exists flow_disclosure_v5_ticker_pub_idx
  on public.flow_disclosure_evidence_v5(ticker,published_at desc);
create index if not exists flow_major_holder_v5_ticker_snapshot_idx
  on public.flow_major_holder_ownership_evidence_v5(ticker,snapshot_date desc);

alter table public.flow_evidence_source_registry_v5 enable row level security;
alter table public.flow_financial_filing_evidence_v5 enable row level security;
alter table public.flow_financial_fact_evidence_v5 enable row level security;
alter table public.flow_disclosure_evidence_v5 enable row level security;
alter table public.flow_major_holder_ownership_evidence_v5 enable row level security;

revoke all on public.flow_evidence_source_registry_v5 from public,anon,authenticated;
revoke all on public.flow_financial_filing_evidence_v5 from public,anon,authenticated;
revoke all on public.flow_financial_fact_evidence_v5 from public,anon,authenticated;
revoke all on public.flow_disclosure_evidence_v5 from public,anon,authenticated;
revoke all on public.flow_major_holder_ownership_evidence_v5 from public,anon,authenticated;

grant select,insert,update,delete on public.flow_evidence_source_registry_v5 to service_role;
grant select,insert,update,delete on public.flow_financial_filing_evidence_v5 to service_role;
grant select,insert,update,delete on public.flow_financial_fact_evidence_v5 to service_role;
grant select,insert,update,delete on public.flow_disclosure_evidence_v5 to service_role;
grant select,insert,update,delete on public.flow_major_holder_ownership_evidence_v5 to service_role;

create or replace view public.flow_evidence_expansion_quality_summary_v5
with (security_invoker=true) as
select
  (select count(*) from public.flow_evidence_source_registry_v5 where source_verified) as verified_source_rows,
  (select count(*) from public.flow_financial_filing_evidence_v5) as financial_filing_rows,
  (select count(*) from public.flow_financial_filing_evidence_v5 where source_verified and publication_time_verified and point_in_time_eligible) as financial_pit_eligible_rows,
  (select count(*) from public.flow_financial_fact_evidence_v5) as financial_fact_rows,
  (select count(*) from public.flow_disclosure_evidence_v5) as disclosure_rows,
  (select count(*) from public.flow_disclosure_evidence_v5 where source_verified and publication_time_verified and point_in_time_eligible) as disclosure_pit_eligible_rows,
  (select count(*) from public.flow_major_holder_ownership_evidence_v5) as major_holder_rows,
  (select count(*) from public.flow_major_holder_ownership_evidence_v5 where source_verified and point_in_time_eligible) as major_holder_pit_eligible_rows,
  false as production_scoring_changed,
  'EVIDENCE_EXPANSION_FOUNDATION_READY'::text as evidence_expansion_state;

revoke all on public.flow_evidence_expansion_quality_summary_v5 from public,anon,authenticated;
grant select on public.flow_evidence_expansion_quality_summary_v5 to service_role;

comment on table public.flow_evidence_source_registry_v5 is 'Official-first evidence source registry. Mirrors such as ZAPI may be discovery/index only; official URLs remain evidence authority.';
comment on table public.flow_financial_filing_evidence_v5 is 'Point-in-time financial filing index. published_at controls knowledge availability; report period end must never be used as knowledge time.';
comment on table public.flow_disclosure_evidence_v5 is 'Point-in-time IDX disclosure metadata with immutable publication timestamp and official attachment URLs.';
comment on table public.flow_major_holder_ownership_evidence_v5 is 'Major-holder ownership snapshots from official IDX/KSEI publications. No historical interpolation.';
