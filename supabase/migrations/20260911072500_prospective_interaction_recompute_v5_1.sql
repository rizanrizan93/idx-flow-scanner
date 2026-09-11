-- Prospective v5.1: deterministic interaction recompute.
-- Replace driver_id = ANY(component_ids) with one bounded UNNEST + equality join.
-- The logic is equivalent but avoids planner paths that timed out at 120 seconds.

create or replace function public.flow_finalize_attribution_prospective_signal_v5(
  p_signal_date date,
  p_base_status text,
  p_runtime_mode text
)
returns jsonb
language plpgsql
security invoker
set search_path=''
set work_mem='64MB'
as $fn$
declare v_exact_stock integer;v_exact_residual integer;v_active integer;
begin
  select count(*)::int into v_exact_stock
  from public.flow_universe_snapshot_v1 u
  join public.flow_official_stock_summary s on s.ticker=u.ticker
    and s.trade_date=p_signal_date and s.source_verified
    and s.source='IDX_OFFICIAL_STOCK_SUMMARY'
    and s.provenance_state='VERIFIED_OFFICIAL_IDX_STOCK_SUMMARY_RAW_PANEL'
  where u.universe_contract='TOP_900_UNIVERSE_V1' and u.snapshot_date=p_signal_date
    and u.selected_top900;
  select count(*)::int into v_exact_residual
  from public.flow_universe_snapshot_v1 u
  join public.flow_stock_residual_activity_v2 r on r.ticker=u.ticker
    and r.trade_date=p_signal_date and r.source_verified
  where u.universe_contract='TOP_900_UNIVERSE_V1' and u.snapshot_date=p_signal_date
    and u.selected_top900;

  update public.flow_attribution_prospective_driver_v1 d set raw_value=null,
    normalized_value=null,driver_state='MISSING',
    source_state=d.source_state||'+EXACT_EOD_BASE_UNAVAILABLE'
  where d.attribution_contract='IDX_PREDICTIVE_ATTRIBUTION_SHADOW_V1'
    and d.signal_date=p_signal_date and not exists(
      select 1 from public.flow_official_stock_summary s
      where s.ticker=d.ticker and s.trade_date=p_signal_date and s.source_verified
        and s.source='IDX_OFFICIAL_STOCK_SUMMARY'
        and s.provenance_state='VERIFIED_OFFICIAL_IDX_STOCK_SUMMARY_RAW_PANEL');

  with ranked as(
    select d.ticker,d.driver_id,percent_rank() over(
      partition by d.driver_id order by d.raw_value) normalized_value
    from public.flow_attribution_prospective_driver_v1 d
    where d.attribution_contract='IDX_PREDICTIVE_ATTRIBUTION_SHADOW_V1'
      and d.signal_date=p_signal_date and d.driver_state='AVAILABLE'
      and d.raw_value is not null
  )
  update public.flow_attribution_prospective_driver_v1 d
    set normalized_value=r.normalized_value
  from ranked r where d.attribution_contract='IDX_PREDICTIVE_ATTRIBUTION_SHADOW_V1'
    and d.signal_date=p_signal_date and d.ticker=r.ticker and d.driver_id=r.driver_id;

  with component_rows as materialized(
    select c.attribution_contract,c.signal_date,c.ticker,c.candidate_id,
      c.component_ids,x.driver_id
    from public.flow_attribution_prospective_candidate_v1 c
    cross join lateral unnest(c.component_ids) x(driver_id)
    where c.attribution_contract='IDX_PREDICTIVE_ATTRIBUTION_SHADOW_V1'
      and c.signal_date=p_signal_date
  ), evidence as(
    select cr.ticker,cr.candidate_id,
      count(d.driver_id) filter(where d.driver_state='AVAILABLE'
        and d.normalized_value is not null)::int available_components,
      count(*)::int required_components,
      bool_and(coalesce(d.normalized_value>=0.80,false)) all_strong,
      coalesce(jsonb_object_agg(cr.driver_id,round(d.normalized_value,6))
        filter(where d.driver_id is not null),'{}'::jsonb) percentiles
    from component_rows cr
    left join public.flow_attribution_prospective_driver_v1 d
      on d.attribution_contract=cr.attribution_contract and d.signal_date=cr.signal_date
      and d.ticker=cr.ticker and d.driver_id=cr.driver_id
    group by cr.ticker,cr.candidate_id
  )
  update public.flow_attribution_prospective_candidate_v1 c set
    component_percentiles=e.percentiles,
    active_signal=(c.base_close>0 and c.base_ihsg_close>0
      and e.available_components=e.required_components and coalesce(e.all_strong,false)),
    signal_state=case when c.base_close is null or c.base_ihsg_close is null
        then 'BASE_PRICE_UNAVAILABLE'
      when e.available_components<e.required_components then 'COMPONENT_UNAVAILABLE'
      when coalesce(e.all_strong,false) then 'ACTIVE' else 'AVAILABLE_NOT_ACTIVE' end
  from evidence e where c.attribution_contract='IDX_PREDICTIVE_ATTRIBUTION_SHADOW_V1'
    and c.signal_date=p_signal_date and c.ticker=e.ticker and c.candidate_id=e.candidate_id;

  select count(*)::int into v_active
  from public.flow_attribution_prospective_candidate_v1
  where attribution_contract='IDX_PREDICTIVE_ATTRIBUTION_SHADOW_V1'
    and signal_date=p_signal_date and active_signal;

  update public.flow_attribution_capture_manifest_v1 set active_candidate_rows=v_active,
    details=details||jsonb_build_object('runtime_contract','PROSPECTIVE_TOP900_PIPELINE_V5_1',
      'exact_stock_rows',v_exact_stock,'exact_residual_rows',v_exact_residual,
      'runtime_mode',p_runtime_mode,'pit_catchup',p_runtime_mode='PIT_CATCHUP',
      'same_session_lineage_required',p_runtime_mode='PIT_CATCHUP',
      'interaction_recompute','UNNEST_EQUALITY_JOIN_V5_1',
      'exact_date_normalization',true,'missing_is_not_zero',true)
  where attribution_contract='IDX_PREDICTIVE_ATTRIBUTION_SHADOW_V1'
    and signal_date=p_signal_date and capture_state='CAPTURED';

  return jsonb_build_object('status',case when p_base_status='ALREADY_CAPTURED'
      then 'ALREADY_CAPTURED' else 'CAPTURED' end,
    'pipeline_contract','PROSPECTIVE_TOP900_PIPELINE_V5_1','signal_date',p_signal_date,
    'selected_count',900,'attempted_count',900,'driver_rows',4500,
    'candidate_rows',11700,'active_candidate_rows',v_active,
    'exact_stock_rows',v_exact_stock,'exact_residual_rows',v_exact_residual,
    'runtime_mode',p_runtime_mode,'interaction_recompute','UNNEST_EQUALITY_JOIN_V5_1',
    'production_influence_enabled',false);
end
$fn$;

create or replace function public.flow_capture_attribution_prospective_signals_v5(
  p_signal_date date default ((clock_timestamp() at time zone 'Asia/Jakarta')::date)
)
returns jsonb
language plpgsql
security invoker
set search_path=''
set work_mem='64MB'
as $fn$
declare
  v_now timestamp:=clock_timestamp() at time zone 'Asia/Jakarta';
  v_today date:=v_now::date;
  v_lineage jsonb;
  v_result jsonb;
  v_exact_stock integer:=0;
  v_exact_residual integer:=0;
begin
  if p_signal_date>v_today then
    return jsonb_build_object('status','FAILED_CLOSED','failure_class','FUTURE_SESSION_FORBIDDEN',
      'signal_date',p_signal_date,'production_influence_enabled',false);
  end if;

  if exists(select 1 from public.flow_attribution_forward_outcome_v1
      where attribution_contract='IDX_PREDICTIVE_ATTRIBUTION_SHADOW_V1'
        and signal_date=p_signal_date) then
    return jsonb_build_object('status','FAILED_CLOSED',
      'failure_class','OUTCOME_ALREADY_EXISTS_CAPTURE_IMMUTABLE',
      'signal_date',p_signal_date,'production_influence_enabled',false);
  end if;

  if exists(select 1 from public.flow_attribution_capture_manifest_v1 m
      where m.attribution_contract='IDX_PREDICTIVE_ATTRIBUTION_SHADOW_V1'
        and m.signal_date=p_signal_date and m.capture_state='CAPTURED'
        and (m.prospective_driver_rows<>4500 or m.candidate_rows<>11700)) then
    return jsonb_build_object('status','FAILED_CLOSED',
      'failure_class','CAPTURE_IMMUTABILITY_COUNT_BREACH','signal_date',p_signal_date,
      'production_influence_enabled',false);
  end if;

  if exists(select 1 from public.flow_attribution_capture_manifest_v1 m
      where m.attribution_contract='IDX_PREDICTIVE_ATTRIBUTION_SHADOW_V1'
        and m.signal_date=p_signal_date and m.capture_state='CAPTURED'
        and m.prospective_driver_rows=4500 and m.candidate_rows=11700) then
    return jsonb_build_object('status','ALREADY_CAPTURED','signal_date',p_signal_date,
      'pipeline_contract','PROSPECTIVE_TOP900_PIPELINE_V5_1','production_influence_enabled',false);
  end if;

  if p_signal_date=v_today then
    if v_now::time<time '18:30' then
      return jsonb_build_object('status','SOURCE_NOT_READY','failure_class','EOD_CUTOFF_NOT_REACHED',
        'signal_date',p_signal_date,'earliest_capture_time_wib','18:30:00',
        'production_influence_enabled',false);
    end if;
    if not exists(select 1 from public.flow_official_index_summary
        where trade_date=p_signal_date and index_code='COMPOSITE' and source_verified
          and source='IDX_OFFICIAL_INDEX_SUMMARY'
          and provenance_state='VERIFIED_OFFICIAL_IDX_INDEX_SUMMARY') then
      return jsonb_build_object('status','SOURCE_NOT_READY',
        'failure_class','VERIFIED_COMPOSITE_EOD_NOT_READY','signal_date',p_signal_date,
        'production_influence_enabled',false);
    end if;
    select count(*)::int into v_exact_stock
    from public.flow_universe_snapshot_v1 u join public.flow_official_stock_summary s
      on s.ticker=u.ticker and s.trade_date=p_signal_date and s.source_verified
      and s.source='IDX_OFFICIAL_STOCK_SUMMARY'
      and s.provenance_state='VERIFIED_OFFICIAL_IDX_STOCK_SUMMARY_RAW_PANEL'
    where u.universe_contract='TOP_900_UNIVERSE_V1' and u.snapshot_date=p_signal_date and u.selected_top900;
    select count(*)::int into v_exact_residual
    from public.flow_universe_snapshot_v1 u join public.flow_stock_residual_activity_v2 r
      on r.ticker=u.ticker and r.trade_date=p_signal_date and r.source_verified
    where u.universe_contract='TOP_900_UNIVERSE_V1' and u.snapshot_date=p_signal_date and u.selected_top900;
    if v_exact_stock<800 or v_exact_residual<800 then
      return jsonb_build_object('status','SOURCE_NOT_READY',
        'failure_class','EXACT_DATE_SOURCE_COVERAGE_BELOW_BOUNDARY','signal_date',p_signal_date,
        'exact_stock_rows',v_exact_stock,'exact_residual_rows',v_exact_residual,'required_rows',800,
        'production_influence_enabled',false);
    end if;
  else
    v_lineage:=public.flow_prospective_lineage_status_v5(p_signal_date);
    if coalesce((v_lineage->>'ready')::boolean,false)=false then
      return jsonb_build_object('status','SOURCE_NOT_READY','failure_class',v_lineage->>'failure_class',
        'signal_date',p_signal_date,'lineage',v_lineage,'production_influence_enabled',false);
    end if;
  end if;

  v_result:=public.flow_capture_attribution_prospective_signals_v2(p_signal_date);
  if coalesce(v_result->>'status','') not in('CAPTURED','ALREADY_CAPTURED') then
    return v_result||case when v_lineage is null then '{}'::jsonb else jsonb_build_object('lineage',v_lineage) end;
  end if;

  return public.flow_finalize_attribution_prospective_signal_v5(
    p_signal_date,coalesce(v_result->>'status','CAPTURED'),
    case when p_signal_date=v_today then 'CURRENT_EOD' else 'PIT_CATCHUP' end
  )||case when v_lineage is null then '{}'::jsonb
      else jsonb_build_object('lineage',v_lineage,'same_session_lineage_verified',true) end;
end
$fn$;

revoke all on function public.flow_finalize_attribution_prospective_signal_v5(date,text,text),
  public.flow_capture_attribution_prospective_signals_v5(date)
  from public,anon,authenticated,service_role;
grant execute on function public.flow_capture_attribution_prospective_signals_v5(date)
  to service_role;
