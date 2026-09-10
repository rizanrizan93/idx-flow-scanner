-- One service-only read model for scanner, storage, prospective, scheduler, and
-- strategy lifecycle health.  It never changes production state.
revoke execute on function public.flow_archive_financial_facts_v1(boolean)
  from public,anon,authenticated,service_role;
comment on function public.flow_archive_financial_facts_v1(boolean) is
  'One-time canonical archive function. Execution revoked after successful 2026-09-09 finalization so a later partial fact batch cannot replace the complete cold archive.';

update public.flow_storage_object_registry_v1 set
  storage_class='COLD_RESEARCH',
  reproducibility_state='LOSSLESS_HASHED_ARCHIVE_AND_COMPACT_PIT_FEATURE_RUNTIME',
  retention_requirement='COLD ARCHIVE RETAINED; explicit restore for raw-fact audit',
  canonical_state='CANONICAL_PIT_EVIDENCE_COLD_ARCHIVED',
  derivation_state='PROSPECTIVE_RUNTIME_USES_PARITY_VERIFIED_FILING_FEATURES_V6',
  removal_authorized=false,reviewed_at=statement_timestamp()
where object_name='flow_financial_fact_evidence_v5';

create or replace function public.flow_operational_status_v2()
returns jsonb
language sql
stable
security invoker
set search_path=''
as $fn$
with latest_universe as(
  select * from public.flow_universe_capture_manifest_v1
  where universe_contract='TOP_900_UNIVERSE_V1' and capture_state='CAPTURED'
  order by snapshot_date desc limit 1
), price_coverage as(
  select u.snapshot_date,count(*) selected,
    count(*) filter(where p.bars>=80) data_ready,
    count(*) filter(where p.bars<80 or p.bars is null) insufficient_history
  from latest_universe m
  join public.flow_universe_snapshot_v1 u on u.universe_contract=m.universe_contract
    and u.snapshot_date=m.snapshot_date and u.selected_top900
  left join lateral(
    select count(*)::int bars from(
      select 1 from public.flow_official_stock_summary s
      where s.ticker=u.ticker and s.source_verified and s.trade_date<=m.snapshot_date
      order by s.trade_date desc limit 120
    ) x
  ) p on true group by u.snapshot_date
), latest_scan as(
  select r.* from public.flow_scan_runs r order by r.started_at desc limit 1
), pipeline as(
  select coalesce(jsonb_agg(to_jsonb(x) order by x.stage),'[]'::jsonb) value
  from(
    select distinct on(stage) stage,session_date,attempt_no,run_state,
      selected_count,attempted_count,output_count,duration_ms,failure_class,
      failure_message,started_at,finished_at
    from public.flow_prospective_pipeline_run_v2
    order by stage,session_date desc,attempt_no desc
  ) x
), lifecycle as(
  select coalesce(jsonb_agg(jsonb_build_object(
    'candidate_id',s.candidate_id,'candidate_type',s.candidate_type,
    'promotion_state',s.promotion_state,'effective_from',s.effective_from,
    'weight',s.weight,'maximum_weight',s.maximum_weight,
    'production_influence_enabled',s.production_influence_enabled,
    'assessment_state',a.assessment_state,
    'independent_signal_dates',a.independent_signal_dates,
    'minimum_matured_sample_across_horizons',a.minimum_matured_sample_across_horizons,
    'minimum_observed_coverage_pct',a.minimum_observed_coverage_pct,
    'positive_horizons',a.positive_horizons,'direction_agreement_pct',a.direction_agreement_pct,
    'minimum_observed_rank_ic',a.minimum_observed_rank_ic,
    'regime_consistency_pct',a.regime_consistency_pct,
    'liquidity_consistency_pct',a.liquidity_consistency_pct,
    'assessment_timestamp',s.assessment_timestamp
  ) order by s.candidate_id),'[]'::jsonb) value
  from public.flow_strategy_lifecycle_state_v2 s
  left join public.flow_gate15_promotion_assessment_v1 a
    on a.policy_version='GATE15_PROMOTION_POLICY_V1' and a.candidate_id=s.candidate_id
  where s.lifecycle_policy_version='STRATEGY_LIFECYCLE_POLICY_V2'
), maturity as(
  select jsonb_build_object(
    'prospective_dates',(select count(distinct signal_date)
      from public.flow_attribution_capture_manifest_v1
      where attribution_contract='IDX_PREDICTIVE_ATTRIBUTION_SHADOW_V1'
        and capture_state='CAPTURED'),
    'active_candidates',(select count(*)
      from public.flow_attribution_prospective_candidate_v1 where active_signal),
    'matured_5d',(select count(*) from public.flow_attribution_forward_outcome_v1
      where horizon_days=5 and outcome_state='MATURED'),
    'matured_20d',(select count(*) from public.flow_attribution_forward_outcome_v1
      where horizon_days=20 and outcome_state='MATURED'),
    'matured_60d',(select count(*) from public.flow_attribution_forward_outcome_v1
      where horizon_days=60 and outcome_state='MATURED')
  ) value
), scheduler as(
  select jsonb_build_object('required_jobs',count(*),
    'active_jobs',count(*) filter(where active),
    'jobs',jsonb_agg(jsonb_build_object('jobname',jobname,'schedule',schedule,
      'active',active) order by jobname)) value
  from cron.job where jobname like 'flow-attribution-%'
    or jobname in('flow-gate15-lifecycle-retry-v2','flow-storage-observability-v1')
)
select jsonb_build_object(
  'contract','IDX_FLOW_OPERATIONAL_STATUS_V2','captured_at',statement_timestamp(),
  'universe',(select jsonb_build_object(
    'snapshot_date',u.snapshot_date,'selected',u.selected_count,
    'current_tradeable',u.current_tradeable_count,
    'production_actionable',u.production_actionable_count,
    'selection_digest',u.selection_digest,'capture_state',u.capture_state,
    'data_ready',p.data_ready,'insufficient_history',p.insufficient_history)
    from latest_universe u left join price_coverage p using(snapshot_date)),
  'latest_scan',(select jsonb_build_object('run_id',id,'status',status,
    'universe_count',universe_count,'attempted_count',attempted_count,
    'processed_count',processed_count,'error_count',error_count,
    'price_failures',price_failures,'started_at',started_at,'completed_at',completed_at)
    from latest_scan),
  'storage',public.flow_storage_status_v1(),
  'pipeline',(select value from pipeline),
  'maturity',(select value from maturity),
  'strategy_lifecycle',(select value from lifecycle),
  'scheduler',(select value from scheduler),
  'production_influence_enabled',(select exists(select 1
    from public.flow_strategy_lifecycle_state_v2
    where lifecycle_policy_version='STRATEGY_LIFECYCLE_POLICY_V2'
      and production_influence_enabled))
)
$fn$;

revoke all on function public.flow_operational_status_v2()
  from public,anon,authenticated,service_role;
grant execute on function public.flow_operational_status_v2() to service_role;
