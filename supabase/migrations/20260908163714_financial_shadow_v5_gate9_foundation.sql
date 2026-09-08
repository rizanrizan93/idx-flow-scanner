-- Gate 9 foundation: immutable weekly PIT historical panel for leakage-safe OOS calibration.

create table if not exists public.flow_financial_shadow_panel_v5 (
  sample_contract text not null,
  as_of_date date not null,
  ticker text not null,
  sector text,
  financial_state text not null check (financial_state in ('AVAILABLE','MISSING','STALE','NOT_APPLICABLE','INVALID','INSUFFICIENT_HISTORY')),
  current_filing_id text,
  prior_filing_id text,
  quality_score numeric,
  growth_score numeric,
  balance_score numeric,
  cashflow_score numeric,
  financial_shadow_score numeric,
  target_date_5d date,
  target_date_20d date,
  target_date_60d date,
  clean_alpha_vs_sector_5d_pct numeric,
  clean_alpha_vs_sector_20d_pct numeric,
  clean_alpha_vs_sector_60d_pct numeric,
  feature_states jsonb not null,
  source_verified boolean not null check (source_verified=true),
  production_influence_enabled boolean not null check (production_influence_enabled=false),
  captured_at timestamptz not null default now(),
  primary key(sample_contract,as_of_date,ticker)
);

create index if not exists flow_financial_shadow_panel_v5_factor_idx
  on public.flow_financial_shadow_panel_v5(as_of_date,sector,financial_shadow_score)
  where financial_shadow_score is not null;

alter table public.flow_financial_shadow_panel_v5 enable row level security;
revoke all on public.flow_financial_shadow_panel_v5 from public,anon,authenticated,service_role;
grant select,insert,update,delete on public.flow_financial_shadow_panel_v5 to service_role;

-- The first deployed refresh implementation was later replaced by the set-based
-- implementation in 20260908164151. Fresh environments intentionally receive the
-- final implementation there rather than replaying the expensive interim body.
