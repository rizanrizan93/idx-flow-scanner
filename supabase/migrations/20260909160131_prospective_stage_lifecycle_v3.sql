-- Route the OUTCOMES stage through the automated lifecycle cycle and keep its
-- success/failure telemetry consistent with the other isolated stages.
create or replace function public.flow_run_prospective_stage_v3(
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
  if not pg_try_advisory_xact_lock(hashtext('PROSPECTIVE_TOP900_PIPELINE_V3:'||p_stage),
      (p_session_date-date '2000-01-01')::integer) then
    return jsonb_build_object('status','FAILED_CLOSED','reason','STAGE_ALREADY_RUNNING',
      'stage',p_stage,'session_date',p_session_date,'production_influence_enabled',false);
  end if;
  select coalesce(max(attempt_no),0)+1 into v_attempt
  from public.flow_prospective_pipeline_run_v2
  where pipeline_contract='PROSPECTIVE_TOP900_PIPELINE_V3'
    and session_date=p_session_date and stage=p_stage;
  insert into public.flow_prospective_pipeline_run_v2(
    pipeline_contract,session_date,stage,attempt_no,run_state,selected_count,
    attempted_count,production_influence_enabled
  ) values('PROSPECTIVE_TOP900_PIPELINE_V3',p_session_date,p_stage,v_attempt,'STARTED',
    case when p_stage<>'OUTCOMES' then 900 end,
    case when p_stage<>'OUTCOMES' then 900 end,false) returning run_id into v_run;
  begin
    case p_stage
      when 'SIGNAL' then
        v_result:=public.flow_capture_attribution_prospective_signals_v2(p_session_date);
      when 'STRUCTURED' then
        v_result:=public.flow_capture_structured_attribution_v2(p_session_date);
      when 'THESIS' then
        v_result:=public.flow_refresh_thesis_lifecycle_v2(p_session_date);
      when 'SHADOW' then
        v_result:=public.flow_capture_shadow_predictive_score_v1(p_session_date);
      when 'OUTCOMES' then
        v_result:=public.flow_run_gate15_lifecycle_cycle_v2();
    end case;
    v_state:=case
      when v_result->>'status'='SOURCE_NOT_READY' then 'SOURCE_NOT_READY'
      when v_result->>'status'='ALREADY_CAPTURED' then 'ALREADY_CAPTURED'
      when v_result->>'status' in('CAPTURED','OK','COMPLETED') then
        case when p_stage in('SIGNAL','STRUCTURED','SHADOW') then 'CAPTURED' else 'COMPLETED' end
      else 'FAILED_CLOSED' end;
    v_output:=coalesce((v_result->>'candidate_rows')::int,(v_result->>'rows')::int,
      (v_result->>'lifecycle_rows')::int,
      (v_result#>>'{outcomes,candidate_outcomes,new_matured_outcomes}')::int,0);
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

revoke all on function public.flow_run_prospective_stage_v3(text,date)
  from public,anon,authenticated,service_role;
grant execute on function public.flow_run_prospective_stage_v3(text,date) to service_role;

do $do$
declare r record;
begin
  for r in select jobid from cron.job where jobname in(
    'flow-attribution-forward-signals-v1','flow-attribution-structured-v2',
    'flow-attribution-thesis-v2','flow-attribution-shadow-score-v2',
    'flow-attribution-forward-signals-retry-v2','flow-attribution-structured-retry-v2',
    'flow-attribution-thesis-retry-v2','flow-attribution-shadow-score-retry-v2',
    'flow-attribution-forward-outcomes-v1','flow-gate15-lifecycle-retry-v2'
  ) loop perform cron.unschedule(r.jobid); end loop;
  perform cron.schedule('flow-attribution-forward-signals-v1','40 11 * * 1-5',
    'select public.flow_run_prospective_stage_v3(''SIGNAL'',(now() at time zone ''Asia/Jakarta'')::date);');
  perform cron.schedule('flow-attribution-structured-v2','43 11 * * 1-5',
    'select public.flow_run_prospective_stage_v3(''STRUCTURED'',(now() at time zone ''Asia/Jakarta'')::date);');
  perform cron.schedule('flow-attribution-thesis-v2','46 11 * * 1-5',
    'select public.flow_run_prospective_stage_v3(''THESIS'',(now() at time zone ''Asia/Jakarta'')::date);');
  perform cron.schedule('flow-attribution-shadow-score-v2','49 11 * * 1-5',
    'select public.flow_run_prospective_stage_v3(''SHADOW'',(now() at time zone ''Asia/Jakarta'')::date);');
  perform cron.schedule('flow-attribution-forward-outcomes-v1','0 12 * * 1-5',
    'select public.flow_run_prospective_stage_v3(''OUTCOMES'',(now() at time zone ''Asia/Jakarta'')::date);');
  perform cron.schedule('flow-attribution-forward-signals-retry-v2','10 12 * * 1-5',
    'select public.flow_run_prospective_stage_v3(''SIGNAL'',(now() at time zone ''Asia/Jakarta'')::date);');
  perform cron.schedule('flow-attribution-structured-retry-v2','13 12 * * 1-5',
    'select public.flow_run_prospective_stage_v3(''STRUCTURED'',(now() at time zone ''Asia/Jakarta'')::date);');
  perform cron.schedule('flow-attribution-thesis-retry-v2','16 12 * * 1-5',
    'select public.flow_run_prospective_stage_v3(''THESIS'',(now() at time zone ''Asia/Jakarta'')::date);');
  perform cron.schedule('flow-attribution-shadow-score-retry-v2','19 12 * * 1-5',
    'select public.flow_run_prospective_stage_v3(''SHADOW'',(now() at time zone ''Asia/Jakarta'')::date);');
  perform cron.schedule('flow-gate15-lifecycle-retry-v2','25 12 * * 1-5',
    'select public.flow_run_prospective_stage_v3(''OUTCOMES'',(now() at time zone ''Asia/Jakarta'')::date);');
end
$do$;
