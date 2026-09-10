create table if not exists public.flow_operational_e2e_manifest_v1(
  e2e_run_id uuid primary key,
  operational_contract text not null,
  source_rpc text not null,
  source_class text not null,
  source_session_date date not null,
  execution_environment text not null,
  selected_count integer not null check(selected_count=900),
  attempted_count integer not null check(attempted_count=900),
  unique_attempted_count integer not null check(unique_attempted_count=900),
  history_ready_count integer not null,
  insufficient_history_count integer not null,
  failed_count integer not null,
  ranking_eligible_count integer not null,
  production_authorized_count integer not null,
  runtime_seconds numeric not null,
  maximum_resident_set_kb bigint not null,
  membership_sha256 text not null check(length(membership_sha256)=64),
  attempt_sha256 text not null check(length(attempt_sha256)=64),
  ranking_ticker_sha256 text not null check(length(ranking_ticker_sha256)=64),
  failure_classes jsonb not null,
  details jsonb not null default '{}'::jsonb,
  production_scoring_contract_changed boolean not null default false,
  experimental_production_influence_enabled boolean not null default false,
  captured_at timestamptz not null default statement_timestamp(),
  check(history_ready_count+insufficient_history_count=selected_count),
  check(ranking_eligible_count+failed_count=attempted_count),
  check(membership_sha256=attempt_sha256)
);

alter table public.flow_operational_e2e_manifest_v1 enable row level security;
revoke all on table public.flow_operational_e2e_manifest_v1
  from public,anon,authenticated,service_role;
grant select on table public.flow_operational_e2e_manifest_v1 to service_role;

insert into public.flow_operational_e2e_manifest_v1(
  e2e_run_id,operational_contract,source_rpc,source_class,source_session_date,
  execution_environment,selected_count,attempted_count,unique_attempted_count,
  history_ready_count,insufficient_history_count,failed_count,
  ranking_eligible_count,production_authorized_count,runtime_seconds,
  maximum_resident_set_kb,membership_sha256,attempt_sha256,
  ranking_ticker_sha256,failure_classes,details,
  production_scoring_contract_changed,experimental_production_influence_enabled
) values(
  '10b3636a-deb3-4ad4-8e08-ba4ed765e951',
  'IDX_OPERATIONAL_TOP900_V1','flow_load_operational_prices_v1',
  'VERIFIED_OFFICIAL_IDX_STOCK_SUMMARY_RAW_PANEL','2026-09-09',
  'CODEX_READ_ONLY_HARNESS_CANONICAL_RPC_EXPORT',900,900,900,894,6,6,894,0,
  11.069,93044,
  '19d49c85d6a6657d03388b244d0a9f76b66ff63d9ca233e5f42dba3b048ae2a1',
  '19d49c85d6a6657d03388b244d0a9f76b66ff63d9ca233e5f42dba3b048ae2a1',
  '680d598c3514d26ba08a0481f79eecbf938c2cef40613a7fab9a9f010ef8a46b',
  '{"INSUFFICIENT_HISTORY":6}'::jsonb,
  jsonb_build_object('insufficient_history_tickers',
    jsonb_build_array('BACH','EMMI','JECX','JELI','PRDL','RANS'),
    'run_kind','READ_ONLY_PRODUCTION_LIKE_E2E','price_payload_count',900,
    'production_authorization_reason','FOREIGN_EVIDENCE_NOT_INJECTED_IN_READ_ONLY_HARNESS'),
  false,false
) on conflict(e2e_run_id) do nothing;
