create table public.flow_research_adaptive_policy_v2 (
  router_contract text not null,
  router_id text not null,
  display_name text not null,
  description text not null,
  sleeve_weights jsonb not null,
  routing_rules jsonb not null,
  historical_evidence jsonb not null default '{}'::jsonb,
  policy_state text not null,
  production_influence_enabled boolean not null default false check (production_influence_enabled = false),
  frozen_at timestamptz not null default now(),
  primary key (router_contract, router_id)
);

create table public.flow_research_adaptive_snapshot_v2 (
  router_contract text not null,
  router_id text not null,
  signal_date date not null,
  router_state text not null,
  active_sleeve_count integer not null,
  active_weight_pct numeric not null check (active_weight_pct between 0 and 100),
  cash_weight_pct numeric not null check (cash_weight_pct between 0 and 100),
  allocation jsonb not null,
  captured_at timestamptz not null default now(),
  production_influence_enabled boolean not null default false check (production_influence_enabled = false),
  primary key (router_contract, router_id, signal_date),
  check (active_weight_pct + cash_weight_pct = 100)
);

create index flow_research_adaptive_snapshot_v2_date_idx
  on public.flow_research_adaptive_snapshot_v2(signal_date desc);

create table public.flow_research_adaptive_outcome_v2 (
  router_contract text not null,
  router_id text not null,
  signal_date date not null,
  completion_target_date date,
  maturity_state text not null,
  active_sleeve_count integer not null,
  mature_sleeve_count integer not null,
  active_weight_pct numeric not null,
  mature_weight_pct numeric not null,
  cash_weight_pct numeric not null,
  pending_weight_pct numeric not null,
  portfolio_return_pct numeric,
  portfolio_alpha_vs_ihsg_pct numeric,
  weighted_mfe_pct numeric,
  weighted_mae_pct numeric,
  sleeve_outcomes jsonb not null,
  evaluated_at timestamptz not null default now(),
  production_influence_enabled boolean not null default false check (production_influence_enabled = false),
  primary key (router_contract, router_id, signal_date)
);

create index flow_research_adaptive_outcome_v2_date_idx
  on public.flow_research_adaptive_outcome_v2(signal_date desc);

alter table public.flow_research_adaptive_policy_v2 enable row level security;
alter table public.flow_research_adaptive_snapshot_v2 enable row level security;
alter table public.flow_research_adaptive_outcome_v2 enable row level security;

insert into public.flow_research_adaptive_policy_v2(
  router_contract,router_id,display_name,description,sleeve_weights,routing_rules,historical_evidence,
  policy_state,production_influence_enabled
) values (
  'ADAPTIVE_HORIZON_ROUTER_V2_1',
  'AHR_V2_40_40_20',
  'Adaptive Horizon Router v2 · 40/40/20',
  'Research-only multi-horizon portfolio router. Inactive sleeve allocation remains cash.',
  '{"BRFE_5":40.0,"BPL_20":40.0,"QBA_60":20.0}'::jsonb,
  '{"allocation_mode":"INDEPENDENT_SLEEVES","inactive_sleeve_policy":"CASH","portfolio_maturity":"ALL_ACTIVE_SLEEVES_MATURE","rebalance_semantics":"COHORT_SNAPSHOT_AT_CLOSE"}'::jsonb,
  '{"research_date":"2026-09-12","method":"EVENT_DRIVEN_NON_OVERLAP_RESEARCH","brfe_5":{"completed_cycles":22,"historical_compounded_return_pct":40.22},"bpl_20":{"completed_cycles":6,"historical_compounded_return_pct":57.51},"qba_60":{"completed_cycles":4,"historical_compounded_return_pct":127.09,"confidence_note":"LOWER_SAMPLE_HIGH_TAIL_RISK"},"portfolio_40_40_20":{"historical_compounded_return_pct":64.5,"early_return_pct":41.75,"middle_return_pct":0.64,"recent_return_pct":15.87,"cost_0_5pct_per_cycle_return_pct":56.3,"cost_1_0pct_per_cycle_return_pct":48.6,"qba_winner_cap_20pct_plus_cost_0_5pct_return_pct":42.0},"evidence_state":"POST_HOC_RESEARCH_CHALLENGER_REQUIRES_PROSPECTIVE_OOS"}'::jsonb,
  'FROZEN_RESEARCH',false
);