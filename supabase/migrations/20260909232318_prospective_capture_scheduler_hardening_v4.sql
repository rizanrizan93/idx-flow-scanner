-- Current-session-only capture guard, exact-source normalization, prerequisite
-- ordering, PIT retry, and V3 promotion lifecycle routing.

create or replace function public.flow_capture_attribution_prospective_signals_v3(
  p_signal_date date default ((clock_timestamp() at time zone 'Asia/Jakarta')::date)
)
returns jsonb
language plpgsql
security invoker
set search_path=''
set work_mem='64MB'
as $fn$
declare v_result jsonb;v_exact_stock integer;v_exact_residual integer;v_active integer;
  v_now timestamp:=clock_timestamp() at time zone 'Asia/Jakarta';
begin
  if p_signal_date<>v_now::date then
    return jsonb_build_object('status','FAILED_CLOSED',
      'failure_class','NON_CURRENT_SESSION_CAPTURE_FORBIDDEN',
      'requested_date',p_signal_date,'current_jakarta_date',v_now::date,
      'production_influence_enabled',false);
  end if;
  if v_now::time<time '18:30' then
    return jsonb_build_object('status','SOURCE_NOT_READY',
      'failure_class','EOD_CUTOFF_NOT_REACHED','signal_date',p_signal_date,
      'earliest_capture_time_wib','18:30:00','production_influence_enabled',false);
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
      'failure_class','CAPTURE_IMMUTABILITY_COUNT_BREACH',
      'signal_date',p_signal_date,'production_influence_enabled',false);
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
  if v_exact_stock<800 or v_exact_residual<800 then
    return jsonb_build_object('status','SOURCE_NOT_READY',
      'failure_class','EXACT_DATE_SOURCE_COVERAGE_BELOW_BOUNDARY',
      'signal_date',p_signal_date,'exact_stock_rows',v_exact_stock,
      'exact_residual_rows',v_exact_residual,'required_rows',800,
      'production_influence_enabled',false);
  end if;

  v_result:=public.flow_capture_attribution_prospective_signals_v2(p_signal_date);
  if coalesce(v_result->>'status','') not in('CAPTURED','ALREADY_CAPTURED') then
    return v_result;
  end if;

  -- A ticker without an exact verified EOD base is unavailable, even if older
  -- history exists.  Then recompute cross-sectional percentiles without it.
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

  with evidence as(
    select c.ticker,c.candidate_id,
      count(d.driver_id) filter(where d.driver_state='AVAILABLE'
        and d.normalized_value is not null)::int available_components,
      cardinality(c.component_ids)::int required_components,
      bool_and(coalesce(d.normalized_value>=0.80,false))
        filter(where d.driver_id is not null) all_strong,
      coalesce(jsonb_object_agg(d.driver_id,round(d.normalized_value,6))
        filter(where d.driver_id is not null),'{}'::jsonb) percentiles
    from public.flow_attribution_prospective_candidate_v1 c
    left join public.flow_attribution_prospective_driver_v1 d
      on d.attribution_contract=c.attribution_contract and d.signal_date=c.signal_date
      and d.ticker=c.ticker and d.driver_id=any(c.component_ids)
    where c.attribution_contract='IDX_PREDICTIVE_ATTRIBUTION_SHADOW_V1'
      and c.signal_date=p_signal_date
    group by c.ticker,c.candidate_id,c.component_ids
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
    details=details||jsonb_build_object('runtime_contract','PROSPECTIVE_TOP900_PIPELINE_V4',
      'exact_stock_rows',v_exact_stock,'exact_residual_rows',v_exact_residual,
      'current_session_only',true,'eod_cutoff_wib','18:30:00',
      'exact_date_normalization',true,'missing_is_not_zero',true)
  where attribution_contract='IDX_PREDICTIVE_ATTRIBUTION_SHADOW_V1'
    and signal_date=p_signal_date and capture_state='CAPTURED';
  return jsonb_build_object('status',case when v_result->>'status'='ALREADY_CAPTURED'
      then 'ALREADY_CAPTURED' else 'CAPTURED' end,
    'pipeline_contract','PROSPECTIVE_TOP900_PIPELINE_V4','signal_date',p_signal_date,
    'selected_count',900,'attempted_count',900,'driver_rows',4500,
    'candidate_rows',11700,'active_candidate_rows',v_active,
    'exact_stock_rows',v_exact_stock,'exact_residual_rows',v_exact_residual,
    'production_influence_enabled',false);
end
$fn$;

create or replace function public.flow_run_prospective_stage_v4(
  p_stage text,p_session_date date default ((clock_timestamp() at time zone 'Asia/Jakarta')::date)
)
returns jsonb
language plpgsql
security invoker
set search_path=''
as $fn$
declare v_result jsonb;v_attempt integer;v_run uuid;v_started timestamptz:=clock_timestamp();
  v_state text;v_output integer;
begin
  if p_stage not in('SIGNAL','STRUCTURED','THESIS','SHADOW','OUTCOMES') then
    raise exception 'unknown prospective stage %',p_stage;
  end if;
  if not pg_try_advisory_xact_lock(hashtext('PROSPECTIVE_TOP900_PIPELINE_V4:'||p_stage),
      (p_session_date-date '2000-01-01')::integer) then
    return jsonb_build_object('status','FAILED_CLOSED','reason','STAGE_ALREADY_RUNNING',
      'stage',p_stage,'session_date',p_session_date,'production_influence_enabled',false);
  end if;
  select coalesce(max(attempt_no),0)+1 into v_attempt
  from public.flow_prospective_pipeline_run_v2
  where pipeline_contract='PROSPECTIVE_TOP900_PIPELINE_V4'
    and session_date=p_session_date and stage=p_stage;
  insert into public.flow_prospective_pipeline_run_v2(
    pipeline_contract,session_date,stage,attempt_no,run_state,selected_count,
    attempted_count,production_influence_enabled
  ) values('PROSPECTIVE_TOP900_PIPELINE_V4',p_session_date,p_stage,v_attempt,'STARTED',
    case when p_stage<>'OUTCOMES' then 900 end,
    case when p_stage<>'OUTCOMES' then 900 end,false) returning run_id into v_run;
  begin
    if p_stage in('STRUCTURED','THESIS','SHADOW') and not exists(
      select 1 from public.flow_attribution_capture_manifest_v1
      where attribution_contract='IDX_PREDICTIVE_ATTRIBUTION_SHADOW_V1'
        and signal_date=p_session_date and capture_state='CAPTURED'
        and prospective_driver_rows=4500 and candidate_rows=11700) then
      v_result:=jsonb_build_object('status','SOURCE_NOT_READY',
        'failure_class','SIGNAL_PREREQUISITE_NOT_CAPTURED','stage',p_stage,
        'session_date',p_session_date,'production_influence_enabled',false);
    elsif p_stage='SIGNAL' then
      v_result:=public.flow_capture_attribution_prospective_signals_v3(p_session_date);
    elsif p_stage='STRUCTURED' then
      v_result:=public.flow_capture_structured_attribution_v2(p_session_date);
    elsif p_stage='THESIS' then
      v_result:=public.flow_refresh_thesis_lifecycle_v2(p_session_date);
    elsif p_stage='SHADOW' then
      v_result:=public.flow_capture_shadow_predictive_score_v1(p_session_date);
    else
      v_result:=public.flow_run_gate15_lifecycle_cycle_v3();
    end if;
    v_state:=case when v_result->>'status'='SOURCE_NOT_READY' then 'SOURCE_NOT_READY'
      when v_result->>'status'='ALREADY_CAPTURED' then 'ALREADY_CAPTURED'
      when v_result->>'status' in('CAPTURED','OK','COMPLETED') then
        case when p_stage in('SIGNAL','STRUCTURED','SHADOW') then 'CAPTURED'
          else 'COMPLETED' end else 'FAILED_CLOSED' end;
    v_output:=coalesce((v_result->>'candidate_rows')::int,(v_result->>'rows')::int,
      (v_result->>'lifecycle_rows')::int,
      (v_result#>>'{outcomes,candidate_outcomes,new_matured_outcomes}')::int,0);
    update public.flow_prospective_pipeline_run_v2 set run_state=v_state,
      output_count=v_output,details=v_result,
      failure_class=case when v_state in('SOURCE_NOT_READY','FAILED_CLOSED')
        then v_result->>'failure_class' end,
      duration_ms=extract(epoch from(clock_timestamp()-v_started))*1000,
      finished_at=clock_timestamp() where run_id=v_run;
    return v_result;
  exception when others then
    update public.flow_prospective_pipeline_run_v2 set run_state='FAILED_CLOSED',
      failure_class=sqlstate,failure_message=left(sqlerrm,1000),
      duration_ms=extract(epoch from(clock_timestamp()-v_started))*1000,
      finished_at=clock_timestamp() where run_id=v_run;
    return jsonb_build_object('status','FAILED_CLOSED','stage',p_stage,
      'sqlstate',sqlstate,'message',left(sqlerrm,1000),
      'production_influence_enabled',false);
  end;
end
$fn$;

revoke all on function public.flow_capture_attribution_prospective_signals_v3(date),
  public.flow_run_prospective_stage_v4(text,date),
  public.flow_run_prospective_stage_v3(text,date)
  from public,anon,authenticated,service_role;
grant execute on function public.flow_capture_attribution_prospective_signals_v3(date),
  public.flow_run_prospective_stage_v4(text,date) to service_role;

do $do$
declare r record;
begin
  for r in select jobid from cron.job where jobname in(
    'flow-attribution-pit-capture-retry-v4','flow-attribution-forward-signals-v1',
    'flow-attribution-structured-v2','flow-attribution-thesis-v2',
    'flow-attribution-shadow-score-v2','flow-attribution-forward-outcomes-v1',
    'flow-attribution-forward-signals-retry-v2','flow-attribution-structured-retry-v2',
    'flow-attribution-thesis-retry-v2','flow-attribution-shadow-score-retry-v2',
    'flow-gate15-lifecycle-retry-v2'
  ) loop perform cron.unschedule(r.jobid); end loop;
  perform cron.schedule('flow-attribution-forward-signals-v1','40 11 * * 1-5',
    'select public.flow_run_prospective_stage_v4(''SIGNAL'',(now() at time zone ''Asia/Jakarta'')::date);');
  perform cron.schedule('flow-attribution-structured-v2','43 11 * * 1-5',
    'select public.flow_run_prospective_stage_v4(''STRUCTURED'',(now() at time zone ''Asia/Jakarta'')::date);');
  perform cron.schedule('flow-attribution-thesis-v2','46 11 * * 1-5',
    'select public.flow_run_prospective_stage_v4(''THESIS'',(now() at time zone ''Asia/Jakarta'')::date);');
  perform cron.schedule('flow-attribution-shadow-score-v2','49 11 * * 1-5',
    'select public.flow_run_prospective_stage_v4(''SHADOW'',(now() at time zone ''Asia/Jakarta'')::date);');
  perform cron.schedule('flow-attribution-forward-outcomes-v1','0 12 * * 1-5',
    'select public.flow_run_prospective_stage_v4(''OUTCOMES'',(now() at time zone ''Asia/Jakarta'')::date);');
  perform cron.schedule('flow-attribution-pit-capture-retry-v4','8 12 * * 1-5',
    'select public.flow_run_attribution_pit_capture_v1();');
  perform cron.schedule('flow-attribution-forward-signals-retry-v2','10 12 * * 1-5',
    'select public.flow_run_prospective_stage_v4(''SIGNAL'',(now() at time zone ''Asia/Jakarta'')::date);');
  perform cron.schedule('flow-attribution-structured-retry-v2','13 12 * * 1-5',
    'select public.flow_run_prospective_stage_v4(''STRUCTURED'',(now() at time zone ''Asia/Jakarta'')::date);');
  perform cron.schedule('flow-attribution-thesis-retry-v2','16 12 * * 1-5',
    'select public.flow_run_prospective_stage_v4(''THESIS'',(now() at time zone ''Asia/Jakarta'')::date);');
  perform cron.schedule('flow-attribution-shadow-score-retry-v2','19 12 * * 1-5',
    'select public.flow_run_prospective_stage_v4(''SHADOW'',(now() at time zone ''Asia/Jakarta'')::date);');
  perform cron.schedule('flow-gate15-lifecycle-retry-v2','25 12 * * 1-5',
    'select public.flow_run_prospective_stage_v4(''OUTCOMES'',(now() at time zone ''Asia/Jakarta'')::date);');
end
$do$;
