alter table public.flow_vendor_foreign_flows
  add column if not exists volume numeric not null default 0,
  add column if not exists traded_value numeric not null default 0;

alter table public.flow_scan_runs
  add column if not exists foreign_evidence_days integer not null default 0,
  add column if not exists foreign_evidence_tickers integer not null default 0,
  add column if not exists foreign_evidence_sources jsonb not null default '{}'::jsonb;

comment on column public.flow_vendor_foreign_flows.volume is
  'Daily traded share volume used to keep foreign-flow intensity dimensionally consistent.';
comment on column public.flow_vendor_foreign_flows.traded_value is
  'Daily traded value retained for audit/context; foreign buy/sell fields remain in flow_unit units.';
comment on column public.flow_scan_runs.official_flow_days is
  'Trading-day coverage from direct IDX official stock-summary transport only.';
comment on column public.flow_scan_runs.official_flow_tickers is
  'Ticker coverage from direct IDX official stock-summary transport only.';
comment on column public.flow_scan_runs.foreign_evidence_days is
  'Trading-day coverage of the selected verified foreign evidence, direct IDX or vendor-derived.';
comment on column public.flow_scan_runs.foreign_evidence_tickers is
  'Ticker coverage of the selected verified foreign evidence.';
comment on column public.flow_scan_runs.foreign_evidence_sources is
  'Selected foreign evidence ticker counts by provenance source; never broker-direct evidence.';
