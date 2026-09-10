-- Isolate prospective stages into separate transactions and replace correlated
-- thesis work with bounded set-based plans.
create or replace function public.flow_refresh_thesis_lifecycle_v2(p_observation_date date)
returns jsonb
language plpgsql
security invoker
set search_path=''
set work_mem='48MB'
as $fn$
declare v_contract constant text:='IDX_THESIS_LIFECYCLE_SHADOW_V1';
  v_attr constant text:='IDX_STRUCTURED_ATTRIBUTION_SHADOW_V2';
  v_source constant text:='IDX_PREDICTIVE_ATTRIBUTION_SHADOW_V1';
  v_new integer:=0;v_components integer:=0;v_lifecycle integer:=0;
begin
  if not exists(select 1 from public.flow_attribution_structured_snapshot_v2
    where attribution_contract=v_attr and signal_date=p_observation_date) then
    return jsonb_build_object('status','SOURCE_NOT_READY','stage','THESIS',
      'observation_date',p_observation_date,'production_influence_enabled',false);
  end if;

  with active as materialized(
    select c.ticker,array_agg(c.candidate_id order by c.candidate_id) candidate_ids
    from public.flow_attribution_prospective_candidate_v1 c
    where c.attribution_contract=v_source and c.signal_date=p_observation_date
      and c.active_signal group by c.ticker
  ), low20 as materialized(
    select a.ticker,p.structural_invalidation
    from active a
    left join lateral(
      select min(x.low) structural_invalidation from(
        select s.low from public.flow_official_stock_summary s
        where s.ticker=a.ticker and s.source_verified
          and s.trade_date<=p_observation_date
        order by s.trade_date desc limit 20
      ) x
    ) p on true
  )
  insert into public.flow_thesis_signal_v1(
    thesis_contract,signal_date,ticker,primary_candidate_ids,thesis_at_signal,thesis_now,
    structural_invalidation,initial_primary_count,initial_contradicting_count,
    lifecycle_state,changed_drivers,last_observation_date,production_influence_enabled
  )
  select v_contract,p_observation_date,a.ticker,x.candidate_ids,
    jsonb_build_object('primary_drivers',a.primary_drivers,
      'supporting_drivers',a.supporting_drivers,
      'contradicting_drivers',a.contradicting_drivers,
      'predictive_readiness',a.predictive_readiness,
      'data_coverage_pct',a.data_coverage_pct,'captured_before_outcome',true),
    jsonb_build_object('primary_drivers',a.primary_drivers,
      'supporting_drivers',a.supporting_drivers,
      'contradicting_drivers',a.contradicting_drivers,
      'observation_date',p_observation_date),
    l.structural_invalidation,jsonb_array_length(a.primary_drivers),
    jsonb_array_length(a.contradicting_drivers),'INTACT','[]'::jsonb,
    p_observation_date,false
  from public.flow_attribution_structured_snapshot_v2 a
  join active x using(ticker) left join low20 l using(ticker)
  where a.attribution_contract=v_attr and a.signal_date=p_observation_date
  on conflict(thesis_contract,signal_date,ticker) do nothing;
  get diagnostics v_new=row_count;

  insert into public.flow_thesis_signal_component_v1(
    thesis_contract,signal_date,ticker,driver_id,signal_driver_state,signal_percentile,
    signal_role,production_influence_enabled
  )
  select v_contract,p_observation_date,d.ticker,d.driver_id,d.driver_state,d.normalized_value,
    case when d.driver_state<>'AVAILABLE' or d.normalized_value is null then 'UNAVAILABLE'
      when d.normalized_value>=0.80 then 'PRIMARY'
      when d.normalized_value>=0.65 then 'SUPPORTING'
      when d.normalized_value<=0.20 then 'CONTRADICTING' else 'NEUTRAL' end,false
  from public.flow_attribution_prospective_driver_v1 d
  join public.flow_thesis_signal_v1 t on t.thesis_contract=v_contract
    and t.signal_date=p_observation_date and t.ticker=d.ticker
  where d.attribution_contract=v_source and d.signal_date=p_observation_date
  on conflict(thesis_contract,signal_date,ticker,driver_id) do nothing;
  get diagnostics v_components=row_count;

  with calendar as materialized(
    select i.trade_date,row_number() over(order by i.trade_date)::int session_no
    from public.flow_official_index_summary i
    where i.index_code='COMPOSITE' and i.source_verified
      and i.trade_date<=p_observation_date
  ), observation_session as(
    select max(session_no)::int session_no from calendar where trade_date=p_observation_date
  ), current_close as materialized(
    select t.ticker,p.close
    from (select distinct ticker from public.flow_thesis_signal_v1
      where thesis_contract=v_contract and signal_date<=p_observation_date) t
    left join lateral(
      select s.close from public.flow_official_stock_summary s
      where s.ticker=t.ticker and s.source_verified and s.trade_date<=p_observation_date
      order by s.trade_date desc limit 1
    ) p on true
  ), compared as(
    select t.signal_date,t.ticker,t.structural_invalidation,
      c.driver_id,c.signal_driver_state,c.signal_percentile,c.signal_role,
      d.driver_state current_state,d.normalized_value current_percentile,
      cc.close current_close,
      greatest(coalesce(os.session_no,0)-coalesce(sc.session_no,coalesce(os.session_no,0)),0)::int sessions_elapsed
    from public.flow_thesis_signal_v1 t
    join public.flow_thesis_signal_component_v1 c on c.thesis_contract=t.thesis_contract
      and c.signal_date=t.signal_date and c.ticker=t.ticker
    left join public.flow_attribution_prospective_driver_v1 d
      on d.attribution_contract=v_source and d.signal_date=p_observation_date
      and d.ticker=t.ticker and d.driver_id=c.driver_id
    left join current_close cc on cc.ticker=t.ticker
    left join calendar sc on sc.trade_date=t.signal_date cross join observation_session os
    where t.thesis_contract=v_contract and t.signal_date<=p_observation_date
  ), summary as(
    select signal_date,ticker,max(structural_invalidation) structural_invalidation,
      max(current_close) current_close,max(sessions_elapsed) sessions_elapsed,
      count(*) filter(where current_state='AVAILABLE' and current_percentile is not null)::int available_now,
      count(*) filter(where signal_percentile>=0.80)::int strong_then,
      count(*) filter(where current_state='AVAILABLE' and current_percentile>=0.80)::int strong_now,
      avg(signal_percentile) filter(where signal_driver_state='AVAILABLE') mean_then,
      avg(current_percentile) filter(where current_state='AVAILABLE') mean_now,
      bool_or(signal_role='PRIMARY' and
        (current_state is distinct from 'AVAILABLE' or current_percentile is null)) primary_missing,
      bool_or(signal_role='PRIMARY' and current_percentile<=0.20) primary_reversed,
      bool_or(signal_role='PRIMARY' and current_percentile<0.50) primary_weakened,
      jsonb_agg(jsonb_build_object('driver_id',driver_id,'signal_role',signal_role,
        'from_percentile',signal_percentile,'now_percentile',current_percentile,
        'current_state',coalesce(current_state,'MISSING'),'change_state',case
          when current_state is distinct from 'AVAILABLE' or current_percentile is null then 'MISSING_NOW'
          when signal_role='PRIMARY' and current_percentile<=0.20 then 'REVERSED'
          when signal_role='PRIMARY' and current_percentile<0.50 then 'WEAKENED'
          when current_percentile>=coalesce(signal_percentile,0)+0.10 then 'STRENGTHENED'
          else 'UNCHANGED' end) order by driver_id) changes,
      jsonb_agg(jsonb_build_object('driver_id',driver_id,
        'driver_state',coalesce(current_state,'MISSING'),
        'percentile',current_percentile) order by driver_id) current_drivers
    from compared group by signal_date,ticker
  ), states as(
    select s.*,case when available_now=0 then 'INVALID_DATA'
      when sessions_elapsed>60 then 'EXPIRED'
      when (structural_invalidation is not null and current_close<structural_invalidation)
        or primary_reversed then 'BROKEN'
      when primary_missing or primary_weakened then 'WEAKENING'
      when strong_now>strong_then or mean_now>=mean_then+0.10 then 'STRENGTHENING'
      else 'INTACT' end lifecycle_state,
      case when available_now=0 then 'No current comparable driver evidence.'
        when sessions_elapsed>60 then 'Frozen 60-session thesis horizon expired.'
        when structural_invalidation is not null and current_close<structural_invalidation
          then 'Price violated the stored structural invalidation.'
        when primary_reversed then 'At least one primary driver reversed into the bottom quintile.'
        when primary_missing then 'At least one primary driver became missing or invalid.'
        when primary_weakened then 'At least one primary driver fell below the frozen 0.50 weakening boundary.'
        when strong_now>strong_then or mean_now>=mean_then+0.10
          then 'Driver breadth or average percentile strengthened by the frozen rule.'
        else 'Primary evidence remains inside the frozen intact boundaries.' end state_reason
    from summary s
  )
  insert into public.flow_thesis_lifecycle_history_v1(
    thesis_contract,signal_date,observation_date,ticker,lifecycle_state,thesis_now,
    changed_drivers,state_reason,sessions_elapsed,production_influence_enabled
  )
  select v_contract,signal_date,p_observation_date,ticker,lifecycle_state,
    jsonb_build_object('observation_date',p_observation_date,'current_close',current_close,
      'structural_invalidation',structural_invalidation,'drivers',current_drivers),
    changes,state_reason,sessions_elapsed,false from states
  on conflict(thesis_contract,signal_date,observation_date,ticker) do update set
    lifecycle_state=excluded.lifecycle_state,thesis_now=excluded.thesis_now,
    changed_drivers=excluded.changed_drivers,state_reason=excluded.state_reason,
    sessions_elapsed=excluded.sessions_elapsed,observed_at=statement_timestamp();
  get diagnostics v_lifecycle=row_count;

  update public.flow_thesis_signal_v1 t set lifecycle_state=h.lifecycle_state,
    thesis_now=h.thesis_now,changed_drivers=h.changed_drivers,
    last_observation_date=h.observation_date,updated_at=statement_timestamp()
  from public.flow_thesis_lifecycle_history_v1 h
  where h.thesis_contract=t.thesis_contract and h.signal_date=t.signal_date
    and h.ticker=t.ticker and h.observation_date=p_observation_date
    and t.thesis_contract=v_contract;
  return jsonb_build_object('status','COMPLETED','stage','THESIS',
    'observation_date',p_observation_date,'new_theses',v_new,
    'new_components',v_components,'lifecycle_rows',v_lifecycle,
    'production_influence_enabled',false);
end
$fn$;

create or replace function public.flow_run_prospective_stage_v2(
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
  if not pg_try_advisory_xact_lock(hashtext('PROSPECTIVE_TOP900_PIPELINE_V2:'||p_stage),
      (p_session_date-date '2000-01-01')::integer) then
    return jsonb_build_object('status','FAILED_CLOSED','reason','STAGE_ALREADY_RUNNING',
      'stage',p_stage,'session_date',p_session_date,'production_influence_enabled',false);
  end if;
  select coalesce(max(attempt_no),0)+1 into v_attempt
  from public.flow_prospective_pipeline_run_v2
  where pipeline_contract='PROSPECTIVE_TOP900_PIPELINE_V2'
    and session_date=p_session_date and stage=p_stage;
  insert into public.flow_prospective_pipeline_run_v2(
    pipeline_contract,session_date,stage,attempt_no,run_state,selected_count,
    attempted_count,production_influence_enabled
  ) values('PROSPECTIVE_TOP900_PIPELINE_V2',p_session_date,p_stage,v_attempt,
    'STARTED',case when p_stage<>'OUTCOMES' then 900 end,
    case when p_stage<>'OUTCOMES' then 900 end,false) returning run_id into v_run;
  begin
    case p_stage
      when 'SIGNAL' then v_result:=public.flow_capture_attribution_prospective_signals_v2(p_session_date);
      when 'STRUCTURED' then v_result:=public.flow_capture_structured_attribution_v2(p_session_date);
      when 'THESIS' then v_result:=public.flow_refresh_thesis_lifecycle_v2(p_session_date);
      when 'SHADOW' then v_result:=public.flow_capture_shadow_predictive_score_v1(p_session_date);
      when 'OUTCOMES' then v_result:=public.flow_run_gate15_outcome_cycle_v1();
    end case;
    v_state:=case
      when v_result->>'status'='SOURCE_NOT_READY' then 'SOURCE_NOT_READY'
      when v_result->>'status'='ALREADY_CAPTURED' then 'ALREADY_CAPTURED'
      when v_result->>'status' in('CAPTURED','OK','COMPLETED') then
        case when p_stage in('SIGNAL','STRUCTURED','SHADOW') then 'CAPTURED' else 'COMPLETED' end
      else 'FAILED_CLOSED' end;
    v_output:=coalesce((v_result->>'candidate_rows')::int,
      (v_result->>'rows')::int,(v_result->>'lifecycle_rows')::int,
      (v_result->>'new_matured_outcomes')::int,0);
    update public.flow_prospective_pipeline_run_v2 set run_state=v_state,
      output_count=v_output,details=v_result,
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

revoke all on function public.flow_refresh_thesis_lifecycle_v2(date),
  public.flow_run_prospective_stage_v2(text,date)
  from public,anon,authenticated,service_role;
grant execute on function public.flow_refresh_thesis_lifecycle_v2(date),
  public.flow_run_prospective_stage_v2(text,date) to service_role;

do $do$
declare r record;
begin
  for r in select jobid from cron.job where jobname in(
    'flow-attribution-forward-signals-v1','flow-attribution-forward-signals-retry-v2',
    'flow-attribution-structured-v2','flow-attribution-thesis-v2',
    'flow-attribution-shadow-score-v2','flow-attribution-structured-retry-v2',
    'flow-attribution-thesis-retry-v2','flow-attribution-shadow-score-retry-v2'
  ) loop perform cron.unschedule(r.jobid); end loop;
  perform cron.schedule('flow-attribution-forward-signals-v1','40 11 * * 1-5',
    'select public.flow_run_prospective_stage_v2(''SIGNAL'',(now() at time zone ''Asia/Jakarta'')::date);');
  perform cron.schedule('flow-attribution-structured-v2','43 11 * * 1-5',
    'select public.flow_run_prospective_stage_v2(''STRUCTURED'',(now() at time zone ''Asia/Jakarta'')::date);');
  perform cron.schedule('flow-attribution-thesis-v2','46 11 * * 1-5',
    'select public.flow_run_prospective_stage_v2(''THESIS'',(now() at time zone ''Asia/Jakarta'')::date);');
  perform cron.schedule('flow-attribution-shadow-score-v2','49 11 * * 1-5',
    'select public.flow_run_prospective_stage_v2(''SHADOW'',(now() at time zone ''Asia/Jakarta'')::date);');
  perform cron.schedule('flow-attribution-forward-signals-retry-v2','10 12 * * 1-5',
    'select public.flow_run_prospective_stage_v2(''SIGNAL'',(now() at time zone ''Asia/Jakarta'')::date);');
  perform cron.schedule('flow-attribution-structured-retry-v2','13 12 * * 1-5',
    'select public.flow_run_prospective_stage_v2(''STRUCTURED'',(now() at time zone ''Asia/Jakarta'')::date);');
  perform cron.schedule('flow-attribution-thesis-retry-v2','16 12 * * 1-5',
    'select public.flow_run_prospective_stage_v2(''THESIS'',(now() at time zone ''Asia/Jakarta'')::date);');
  perform cron.schedule('flow-attribution-shadow-score-retry-v2','19 12 * * 1-5',
    'select public.flow_run_prospective_stage_v2(''SHADOW'',(now() at time zone ''Asia/Jakarta'')::date);');
end
$do$;
