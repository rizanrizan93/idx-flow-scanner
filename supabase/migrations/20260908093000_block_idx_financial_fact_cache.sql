-- Evidence v5 financial facts: sharded, content-addressed canonical ingestion.
-- Official IDX instance.zip only. Production scoring is intentionally unchanged.

alter table public.flow_financial_fact_evidence_v5
  add column if not exists taxonomy_namespace text;

create unique index if not exists flow_financial_fact_v5_filing_metric_uidx
  on public.flow_financial_fact_evidence_v5(filing_id, metric_key);

create table if not exists public.flow_financial_metric_catalog_v5 (
  metric_key text primary key,
  metric_label text not null,
  statement_type text not null check (statement_type in ('BALANCE_SHEET','INCOME_STATEMENT','CASH_FLOW_STATEMENT')),
  period_kind text not null check (period_kind in ('instant','duration')),
  concepts text[] not null check (cardinality(concepts) > 0),
  catalog_sha256 text not null,
  created_at timestamptz not null default now()
);

create table if not exists public.flow_financial_fact_manifest_v5 (
  manifest_sha256 text primary key check (manifest_sha256 ~ '^[0-9a-f]{64}$'),
  manifest_url text not null unique,
  artifact_commit_sha text not null check (artifact_commit_sha ~ '^[0-9a-f]{40}$'),
  source_run_id bigint not null,
  source_head_sha text not null check (source_head_sha ~ '^[0-9a-f]{40}$'),
  metric_catalog_sha256 text not null,
  selected_filing_rows integer not null check (selected_filing_rows >= 0),
  parsed_filing_rows integer not null check (parsed_filing_rows >= 0),
  permanent_excluded_filing_rows integer not null check (permanent_excluded_filing_rows >= 0),
  manifest_raw text not null,
  exclusions_raw text not null,
  check (selected_filing_rows = parsed_filing_rows + permanent_excluded_filing_rows),
  fact_rows integer not null check (fact_rows >= 0),
  shard_count integer not null check (shard_count > 0),
  exact_locator_resolution_rows integer not null default 0 check (exact_locator_resolution_rows >= 0),
  manifest_payload jsonb not null,
  ingest_state text not null default 'REGISTERED'
    check (ingest_state in ('REGISTERED','INGESTING','COMPLETE')),
  registered_at timestamptz not null default now(),
  completed_at timestamptz
);

create table if not exists public.flow_financial_fact_shard_ingest_v5 (
  manifest_sha256 text not null
    references public.flow_financial_fact_manifest_v5(manifest_sha256) on delete cascade,
  shard_index integer not null check (shard_index > 0),
  file_name text not null,
  shard_url text not null,
  expected_sha256 text not null check (expected_sha256 ~ '^[0-9a-f]{64}$'),
  expected_bytes bigint not null check (expected_bytes > 0),
  expected_filing_rows integer not null check (expected_filing_rows > 0),
  expected_fact_rows integer not null check (expected_fact_rows >= 0),
  ingest_state text not null default 'PENDING'
    check (ingest_state in ('PENDING','INGESTING','COMPLETE')),
  inserted_fact_rows integer,
  expected_relational_sha256 text,
  actual_relational_sha256 text,
  verified_at timestamptz,
  ingested_at timestamptz,
  primary key (manifest_sha256, shard_index),
  unique (manifest_sha256, file_name)
);

create table if not exists public.flow_financial_fact_manifest_filing_v5 (
  manifest_sha256 text not null
    references public.flow_financial_fact_manifest_v5(manifest_sha256) on delete cascade,
  shard_index integer not null,
  filing_id text not null
    references public.flow_financial_filing_evidence_v5(filing_id) on delete cascade,
  content_hash text not null check (content_hash ~ '^[0-9a-f]{64}$'),
  registered_at timestamptz not null default now(),
  primary key (manifest_sha256, filing_id),
  foreign key (manifest_sha256, shard_index)
    references public.flow_financial_fact_shard_ingest_v5(manifest_sha256, shard_index)
    on delete cascade
);

create table if not exists public.flow_financial_fact_manifest_exclusion_v5 (
  manifest_sha256 text not null references public.flow_financial_fact_manifest_v5(manifest_sha256),
  filing_id text not null references public.flow_financial_filing_evidence_v5(filing_id),
  ticker text not null,
  failure_class text not null check (failure_class in ('OFFICIAL_ATTACHMENT_UNAVAILABLE_CONFIRMED','OFFICIAL_ATTACHMENT_CORRUPT_CONFIRMED')),
  retryable boolean not null check (retryable = false),
  point_in_time_identity_preserved boolean not null check (point_in_time_identity_preserved = true),
  classification_reason text not null check (length(classification_reason)>0),
  provenance_payload jsonb not null,
  registered_at timestamptz not null default now(),
  primary key (manifest_sha256, filing_id)
);
alter table public.flow_financial_fact_manifest_exclusion_v5 enable row level security;
revoke all on public.flow_financial_fact_manifest_exclusion_v5 from public, anon, authenticated, service_role;
grant select, insert on public.flow_financial_fact_manifest_exclusion_v5 to service_role;

-- Numeric normalization preserves factual values while making source/DB hashes comparable.
create or replace function public.flow_financial_fact_row_digest_v5(p_payload jsonb)
returns text language sql immutable security invoker set search_path = '' as $$
  select encode(extensions.digest(convert_to(
    jsonb_set(p_payload, '{metric_value}', to_jsonb(trim_scale((p_payload->>'metric_value')::numeric)))::text,
    'UTF8'), 'sha256'), 'hex');
$$;
revoke all on function public.flow_financial_fact_row_digest_v5(jsonb) from public, anon, authenticated, service_role;
grant execute on function public.flow_financial_fact_row_digest_v5(jsonb) to service_role;

alter table public.flow_financial_metric_catalog_v5 enable row level security;
alter table public.flow_financial_fact_manifest_v5 enable row level security;
alter table public.flow_financial_fact_shard_ingest_v5 enable row level security;
alter table public.flow_financial_fact_manifest_filing_v5 enable row level security;

revoke all on public.flow_financial_metric_catalog_v5 from public, anon, authenticated, service_role;
revoke all on public.flow_financial_fact_manifest_v5 from public, anon, authenticated, service_role;
revoke all on public.flow_financial_fact_shard_ingest_v5 from public, anon, authenticated, service_role;
revoke all on public.flow_financial_fact_manifest_filing_v5 from public, anon, authenticated, service_role;

grant select on public.flow_financial_metric_catalog_v5 to service_role;
grant select, insert, update on public.flow_financial_fact_manifest_v5 to service_role;
grant select, insert, update on public.flow_financial_fact_shard_ingest_v5 to service_role;
grant select, insert on public.flow_financial_fact_manifest_filing_v5 to service_role;

insert into public.flow_financial_metric_catalog_v5
(metric_key, metric_label, statement_type, period_kind, concepts, catalog_sha256)
values
('total_assets','Total assets','BALANCE_SHEET','instant',array['Assets'],'fdb22a134597d5161632aedef260fdaf9342f997aa55c4d11e670043a372b930'),
('current_assets','Current assets','BALANCE_SHEET','instant',array['CurrentAssets'],'fdb22a134597d5161632aedef260fdaf9342f997aa55c4d11e670043a372b930'),
('non_current_assets','Non-current assets','BALANCE_SHEET','instant',array['NonCurrentAssets'],'fdb22a134597d5161632aedef260fdaf9342f997aa55c4d11e670043a372b930'),
('total_liabilities','Total liabilities','BALANCE_SHEET','instant',array['Liabilities'],'fdb22a134597d5161632aedef260fdaf9342f997aa55c4d11e670043a372b930'),
('current_liabilities','Current liabilities','BALANCE_SHEET','instant',array['CurrentLiabilities'],'fdb22a134597d5161632aedef260fdaf9342f997aa55c4d11e670043a372b930'),
('non_current_liabilities','Non-current liabilities','BALANCE_SHEET','instant',array['NonCurrentLiabilities'],'fdb22a134597d5161632aedef260fdaf9342f997aa55c4d11e670043a372b930'),
('total_equity','Total equity','BALANCE_SHEET','instant',array['Equity'],'fdb22a134597d5161632aedef260fdaf9342f997aa55c4d11e670043a372b930'),
('equity_attributable_to_parent','Equity attributable to owners of parent','BALANCE_SHEET','instant',array['EquityAttributableToEquityOwnersOfParentEntity'],'fdb22a134597d5161632aedef260fdaf9342f997aa55c4d11e670043a372b930'),
('cash_and_cash_equivalents','Cash and cash equivalents','BALANCE_SHEET','instant',array['CashAndCashEquivalents','CashAndCashEquivalentsCashFlows'],'fdb22a134597d5161632aedef260fdaf9342f997aa55c4d11e670043a372b930'),
('sales_and_revenue','Sales and revenue','INCOME_STATEMENT','duration',array['SalesAndRevenue'],'fdb22a134597d5161632aedef260fdaf9342f997aa55c4d11e670043a372b930'),
('interest_and_sharia_income','Interest and sharia income','INCOME_STATEMENT','duration',array['TotalInterestAndShariaIncome','InterestIncome'],'fdb22a134597d5161632aedef260fdaf9342f997aa55c4d11e670043a372b930'),
('cost_of_sales_and_revenue','Cost of sales and revenue','INCOME_STATEMENT','duration',array['CostOfSalesAndRevenue'],'fdb22a134597d5161632aedef260fdaf9342f997aa55c4d11e670043a372b930'),
('gross_profit','Gross profit','INCOME_STATEMENT','duration',array['GrossProfit'],'fdb22a134597d5161632aedef260fdaf9342f997aa55c4d11e670043a372b930'),
('profit_before_income_tax','Profit before income tax','INCOME_STATEMENT','duration',array['ProfitLossBeforeIncomeTax'],'fdb22a134597d5161632aedef260fdaf9342f997aa55c4d11e670043a372b930'),
('profit_loss','Profit or loss','INCOME_STATEMENT','duration',array['ProfitLoss'],'fdb22a134597d5161632aedef260fdaf9342f997aa55c4d11e670043a372b930'),
('profit_attributable_to_parent','Profit attributable to owners of parent','INCOME_STATEMENT','duration',array['ProfitLossAttributableToParentEntity'],'fdb22a134597d5161632aedef260fdaf9342f997aa55c4d11e670043a372b930'),
('operating_cash_flow','Net cash flow from operating activities','CASH_FLOW_STATEMENT','duration',array['NetCashFlowsReceivedFromUsedInOperatingActivities'],'fdb22a134597d5161632aedef260fdaf9342f997aa55c4d11e670043a372b930'),
('investing_cash_flow','Net cash flow from investing activities','CASH_FLOW_STATEMENT','duration',array['NetCashFlowsReceivedFromUsedInInvestingActivities'],'fdb22a134597d5161632aedef260fdaf9342f997aa55c4d11e670043a372b930'),
('financing_cash_flow','Net cash flow from financing activities','CASH_FLOW_STATEMENT','duration',array['NetCashFlowsReceivedFromUsedInFinancingActivities'],'fdb22a134597d5161632aedef260fdaf9342f997aa55c4d11e670043a372b930')
on conflict (metric_key) do nothing;

-- Only fact inserts and parent extraction metadata updates are needed by this pipeline.
revoke all on public.flow_financial_fact_evidence_v5 from public, anon, authenticated, service_role;
grant select, insert on public.flow_financial_fact_evidence_v5 to service_role;
