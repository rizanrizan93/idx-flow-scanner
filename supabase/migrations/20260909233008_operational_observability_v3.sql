-- Versioned service-only control-plane read model for V4 prospective stages and
-- V3 lifecycle policy.  Cron recency is surfaced; an active job alone is not
-- reported as healthy.

create or replace function public.flow_operational_status_v3()
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
  from latest_universe m join public.flow_universe_snapshot_v1 u
    on u.universe_contract=m.universe_contract and u.snapshot_date=m.snapshot_date
    and u.selected_top900
  left join lateral(select count(*)::int bars from(
    select 1 from public.flow_official_stock_summary s
    where s.ticker=u.ticker and s.source_verified and s.trade_date<=m.snapshot_date
    order by s.trade_date desc limit 120) x) p on true
  group by u.snapshot_date
), latest_scan as(
  select r.* from public.flow_scan_runs r order by r.started_at desc limit 1
), pipeline as(
  select coalesce(jsonb_agg(to_jsonb(x) order by x.stage),'[]'::jsonb) value
  from(select distinct on(stage) stage,session_date,attempt_no,run_state,
      selected_count,attempted_count,output_count,duration_ms,failure_class,
      failure_message,started_at,finished_at
    from public.flow_prospective_pipeline_run_v2
    where pipeline_contract='PROSPECTIVE_TOP900_PIPELINE_V4'
    order by stage,started_at desc) x
), driver_coverage as(
  select coalesce(jsonb_agg(jsonb_build_object('driver_id',driver_id,
      'available',available,'unavailable',900-available,
      'coverage_pct',round(100.0*available/900,2)) order by driver_id),'[]'::jsonb) value
  from(select d.driver_id,count(*) filter(where d.driver_state='AVAILABLE'
      and d.normalized_value is not null)::int available
    from public.flow_attribution_prospective_driver_v1 d
    where d.attribution_contract='IDX_PREDICTIVE_ATTRIBUTION_SHADOW_V1'
      and d.signal_date=(select max(signal_date)
        from public.flow_attribution_capture_manifest_v1
        where attribution_contract='IDX_PREDICTIVE_ATTRIBUTION_SHADOW_V1'
          and capture_state='CAPTURED') group by d.driver_id) x
), lifecycle as(
  select coalesce(jsonb_agg(jsonb_build_object(
    'candidate_id',s.candidate_id,'candidate_type',s.candidate_type,
    'promotion_state',s.promotion_state,'effective_from',s.effective_from,
    'limited_started_at',s.limited_started_at,'full_started_at',s.full_started_at,
    'weight',s.weight,'maximum_weight',s.maximum_weight,
    'production_influence_enabled',s.production_influence_enabled,
    'integrity_state',s.integrity_state,'assessment_state',a.assessment_state,
    'independent_signal_dates',a.independent_matured_signal_dates,
    'minimum_matured_sample_across_horizons',a.minimum_matured_sample_across_horizons,
    'robustness_state',a.robustness_state,'observed_metrics',a.observed_metrics,
    'gate_results',a.gate_results,'assessment_timestamp',s.assessed_at,
    'policy_hash',p.policy_hash) order by s.candidate_id),'[]'::jsonb) value
  from public.flow_strategy_lifecycle_state_v3 s
  join public.flow_strategy_lifecycle_policy_v3 p using(lifecycle_policy_version,candidate_id)
  left join public.flow_gate15_promotion_assessment_v2 a
    on a.assessment_contract='GATE15_PROSPECTIVE_ASSESSMENT_V2'
    and a.candidate_id=s.candidate_id
  where s.lifecycle_policy_version='STRATEGY_LIFECYCLE_POLICY_V3'
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
      where horizon_days=60 and outcome_state='MATURED')) value
), required_jobs as(
  select unnest(array[
    'flow-attribution-pit-capture-v1','flow-attribution-forward-signals-v1',
    'flow-attribution-structured-v2','flow-attribution-thesis-v2',
    'flow-attribution-shadow-score-v2','flow-attribution-forward-outcomes-v1',
    'flow-attribution-pit-capture-retry-v4','flow-attribution-forward-signals-retry-v2',
    'flow-attribution-structured-retry-v2','flow-attribution-thesis-retry-v2',
    'flow-attribution-shadow-score-retry-v2','flow-gate15-lifecycle-retry-v2',
    'flow-storage-observability-v1',
    'flow-financial-filing-feature-incremental-v6-evening',
    'flow-financial-filing-feature-incremental-v6-morning']) jobname
), cron_detail as(
  select r.jobname,j.jobid,j.schedule,j.active,d.status,d.start_time,d.end_time,
    left(d.return_message,500) return_message
  from required_jobs r left join cron.job j using(jobname)
  left join lateral(select x.status,x.start_time,x.end_time,x.return_message
    from cron.job_run_details x where x.jobid=j.jobid order by x.runid desc limit 1) d on true
), scheduler as(
  select jsonb_build_object('required_jobs',count(*),
    'configured_jobs',count(jobid),'active_jobs',count(*) filter(where active),
    'latest_success_jobs',count(*) filter(where status='succeeded'),
    'latest_failed_jobs',count(*) filter(where status='failed'),
    'jobs',jsonb_agg(jsonb_build_object('jobname',jobname,'schedule',schedule,
      'active',coalesce(active,false),'latest_status',coalesce(status,'NEVER_RUN'),
      'latest_start',start_time,'latest_end',end_time,
      'latest_message',return_message) order by jobname)) value from cron_detail
)
select jsonb_build_object('contract','IDX_FLOW_OPERATIONAL_STATUS_V3',
  'captured_at',statement_timestamp(),
  'universe',(select jsonb_build_object('snapshot_date',u.snapshot_date,
    'selected',u.selected_count,'current_tradeable',u.current_tradeable_count,
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
  'driver_coverage',(select value from driver_coverage),
  'pipeline',(select value from pipeline),'maturity',(select value from maturity),
  'strategy_lifecycle',(select value from lifecycle),
  'scheduler',(select value from scheduler),
  'production_influence_enabled',(select exists(select 1
    from public.flow_strategy_lifecycle_state_v3
    where lifecycle_policy_version='STRATEGY_LIFECYCLE_POLICY_V3'
      and production_influence_enabled)))
$fn$;

revoke all on function public.flow_operational_status_v3(),
  public.flow_operational_status_v2() from public,anon,authenticated,service_role;
grant execute on function public.flow_operational_status_v3() to service_role;
