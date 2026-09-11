-- Prospective runtime health v5.
--
-- Purpose:
-- 1. Preserve the current-session v4 capture contract for normal EOD operation.
-- 2. Permit a bounded historical catch-up only when every mutable source needed by
--    the prospective signal was already present before the next Jakarta midnight.
-- 3. Make cron retries select the oldest eligible missing session instead of
--    permanently abandoning yesterday after the calendar date rolls over.
-- 4. Keep every predictive artifact shadow-only; production influence remains OFF.

create or replace function public.flow_prospective_lineage_status_v5(p_signal_date date)
returns jsonb
language plpgsql
stable
security invoker
set search_path=''
as $fn$
declare
  v_today date := (clock_timestamp() at time zone 'Asia/Jakarta')::date;
  v_cutoff timestamptz := ((p_signal_date + 1)::timestamp at time zone 'Asia/Jakarta');
  v_selected integer := 0;
  v_stock integer := 0;
  v_residual integer := 0;
  v_sector integer := 0;
  v_composite integer := 0;
  v_late_financial integer := 0;
  v_universe_captured timestamptz;
  v_stock_ingested timestamptz;
  v_residual_computed timestamptz;
  v_sector_captured timestamptz;
  v_index_ingested timestamptz;
begin
  if p_signal_date is null or p_signal_date < date '2026-09-09' then
    return jsonb_build_object('ready',false,'failure_class','OUTSIDE_PROSPECTIVE_START','signal_date',p_signal_date);
  end if;
  if p_signal_date >= v_today then
    return jsonb_build_object('ready',false,'failure_class','NOT_HISTORICAL_SESSION','signal_date',p_signal_date);
  end if;
  if p_signal_date < v_today - 7 then
    return jsonb_build_object('ready',false,'failure_class','CATCHUP_WINDOW_EXCEEDED','signal_date',p_signal_date,'max_age_calendar_days',7);
  end if;

  select m.selected_count,m.captured_at into v_selected,v_universe_captured
  from public.flow_universe_capture_manifest_v1 m
  where m.universe_contract='TOP_900_UNIVERSE_V1'
    and m.snapshot_date=p_signal_date
    and m.official_eod_date=p_signal_date
    and m.capture_state='CAPTURED'
  order by m.captured_at desc limit 1;

  select count(*)::int,max(s.ingested_at) into v_stock,v_stock_ingested
  from public.flow_universe_snapshot_v1 u
  join public.flow_official_stock_summary s
    on s.ticker=u.ticker and s.trade_date=p_signal_date
   and s.source_verified
   and s.source='IDX_OFFICIAL_STOCK_SUMMARY'
   and s.provenance_state='VERIFIED_OFFICIAL_IDX_STOCK_SUMMARY_RAW_PANEL'
  where u.universe_contract='TOP_900_UNIVERSE_V1'
    and u.snapshot_date=p_signal_date and u.selected_top900;

  select count(*)::int,max(r.computed_at) into v_residual,v_residual_computed
  from public.flow_universe_snapshot_v1 u
  join public.flow_stock_residual_activity_v2 r
    on r.ticker=u.ticker and r.trade_date=p_signal_date and r.source_verified
  where u.universe_contract='TOP_900_UNIVERSE_V1'
    and u.snapshot_date=p_signal_date and u.selected_top900;

  select count(*)::int,max(s.captured_at) into v_sector,v_sector_captured
  from public.flow_universe_snapshot_v1 u
  join public.flow_sector_membership_snapshot_v1 s
    on s.ticker=u.ticker and s.snapshot_date=p_signal_date
  where u.universe_contract='TOP_900_UNIVERSE_V1'
    and u.snapshot_date=p_signal_date and u.selected_top900;

  select count(*)::int,max(i.ingested_at) into v_composite,v_index_ingested
  from public.flow_official_index_summary i
  where i.trade_date=p_signal_date and i.index_code='COMPOSITE' and i.source_verified
    and i.source='IDX_OFFICIAL_INDEX_SUMMARY'
    and i.provenance_state='VERIFIED_OFFICIAL_IDX_INDEX_SUMMARY';

  -- Financial v6 is PIT by available_from_date.  Historical recovery additionally
  -- refuses to run if any filing that would be eligible for the historical date was
  -- only ingested after that session's next-midnight boundary.
  select count(*)::int into v_late_financial
  from public.flow_financial_filing_feature_v5 f
  join public.flow_financial_filing_evidence_v5 e on e.filing_id=f.filing_id
  where f.available_from_date<=p_signal_date and e.ingested_at>=v_cutoff;

  if coalesce(v_selected,0)<>900 or v_universe_captured is null or v_universe_captured>=v_cutoff then
    return jsonb_build_object('ready',false,'failure_class','UNIVERSE_NOT_SAME_SESSION_FINAL',
      'signal_date',p_signal_date,'selected_count',coalesce(v_selected,0),
      'universe_captured_at',v_universe_captured,'cutoff',v_cutoff);
  end if;
  if v_stock<>900 or v_stock_ingested is null or v_stock_ingested>=v_cutoff then
    return jsonb_build_object('ready',false,'failure_class','OFFICIAL_STOCK_NOT_SAME_SESSION_FINAL',
      'signal_date',p_signal_date,'exact_stock_rows',v_stock,'stock_max_ingested_at',v_stock_ingested,'cutoff',v_cutoff);
  end if;
  if v_residual<>900 or v_residual_computed is null or v_residual_computed>=v_cutoff then
    return jsonb_build_object('ready',false,'failure_class','RESIDUAL_NOT_SAME_SESSION_FINAL',
      'signal_date',p_signal_date,'exact_residual_rows',v_residual,'residual_max_computed_at',v_residual_computed,'cutoff',v_cutoff);
  end if;
  if v_sector<>900 or v_sector_captured is null or v_sector_captured>=v_cutoff then
    return jsonb_build_object('ready',false,'failure_class','SECTOR_NOT_SAME_SESSION_FINAL',
      'signal_date',p_signal_date,'sector_rows',v_sector,'sector_max_captured_at',v_sector_captured,'cutoff',v_cutoff);
  end if;
  if v_composite<1 or v_index_ingested is null or v_index_ingested>=v_cutoff then
    return jsonb_build_object('ready',false,'failure_class','COMPOSITE_NOT_SAME_SESSION_FINAL',
      'signal_date',p_signal_date,'composite_rows',v_composite,'index_max_ingested_at',v_index_ingested,'cutoff',v_cutoff);
  end if;
  if v_late_financial<>0 then
    return jsonb_build_object('ready',false,'failure_class','LATE_FINANCIAL_BACKFILL_WOULD_LEAK',
      'signal_date',p_signal_date,'late_financial_rows',v_late_financial,'cutoff',v_cutoff);
  end if;
  if exists(select 1 from public.flow_attribution_forward_outcome_v1
      where attribution_contract='IDX_PREDICTIVE_ATTRIBUTION_SHADOW_V1'
        and signal_date=p_signal_date) then
    return jsonb_build_object('ready',false,'failure_class','OUTCOME_ALREADY_EXISTS_CAPTURE_IMMUTABLE',
      'signal_date',p_signal_date);
  end if;

  return jsonb_build_object('ready',true,'signal_date',p_signal_date,'cutoff',v_cutoff,
    'selected_count',v_selected,'exact_stock_rows',v_stock,'exact_residual_rows',v_residual,
    'sector_rows',v_sector,'composite_rows',v_composite,'late_financial_rows',v_late_financial,
    'same_session_lineage_verified',true);
end
$fn$;

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
    details=details||jsonb_build_object('runtime_contract','PROSPECTIVE_TOP900_PIPELINE_V5',
      'exact_stock_rows',v_exact_stock,'exact_residual_rows',v_exact_residual,
      'runtime_mode',p_runtime_mode,'pit_catchup',p_runtime_mode='PIT_CATCHUP',
      'same_session_lineage_required',p_runtime_mode='PIT_CATCHUP',
      'exact_date_normalization',true,'missing_is_not_zero',true)
  where attribution_contract='IDX_PREDICTIVE_ATTRIBUTION_SHADOW_V1'
    and signal_date=p_signal_date and capture_state='CAPTURED';

  return jsonb_build_object('status',case when p_base_status='ALREADY_CAPTURED'
      then 'ALREADY_CAPTURED' else 'CAPTURED' end,
    'pipeline_contract','PROSPECTIVE_TOP900_PIPELINE_V5','signal_date',p_signal_date,
    'selected_count',900,'attempted_count',900,'driver_rows',4500,
    'candidate_rows',11700,'active_candidate_rows',v_active,
    'exact_stock_rows',v_exact_stock,'exact_residual_rows',v_exact_residual,
    'runtime_mode',p_runtime_mode,'production_influence_enabled',false);
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
  v_today date := (clock_timestamp() at time zone 'Asia/Jakarta')::date;
  v_lineage jsonb;
  v_result jsonb;
begin
  if p_signal_date=v_today then
    return public.flow_capture_attribution_prospective_signals_v3(p_signal_date);
  end if;
  if p_signal_date>v_today then
    return jsonb_build_object('status','FAILED_CLOSED','failure_class','FUTURE_SESSION_FORBIDDEN',
      'signal_date',p_signal_date,'production_influence_enabled',false);
  end if;
  if exists(select 1 from public.flow_attribution_capture_manifest_v1 m
      where m.attribution_contract='IDX_PREDICTIVE_ATTRIBUTION_SHADOW_V1'
        and m.signal_date=p_signal_date and m.capture_state='CAPTURED'
        and m.prospective_driver_rows=4500 and m.candidate_rows=11700) then
    return jsonb_build_object('status','ALREADY_CAPTURED','signal_date',p_signal_date,
      'pipeline_contract','PROSPECTIVE_TOP900_PIPELINE_V5','production_influence_enabled',false);
  end if;

  v_lineage:=public.flow_prospective_lineage_status_v5(p_signal_date);
  if coalesce((v_lineage->>'ready')::boolean,false)=false then
    return jsonb_build_object('status','SOURCE_NOT_READY','failure_class',v_lineage->>'failure_class',
      'signal_date',p_signal_date,'lineage',v_lineage,'production_influence_enabled',false);
  end if;

  v_result:=public.flow_capture_attribution_prospective_signals_v2(p_signal_date);
  if coalesce(v_result->>'status','') not in('CAPTURED','ALREADY_CAPTURED') then
    return v_result||jsonb_build_object('lineage',v_lineage,'runtime_mode','PIT_CATCHUP');
  end if;
  return public.flow_finalize_attribution_prospective_signal_v5(
    p_signal_date,coalesce(v_result->>'status','CAPTURED'),'PIT_CATCHUP'
  )||jsonb_build_object('lineage',v_lineage,'same_session_lineage_verified',true);
end
$fn$;

create or replace function public.flow_select_prospective_session_v5(p_stage text)
returns date
language plpgsql
stable
security invoker
set search_path=''
as $fn$
declare
  v_today date := (clock_timestamp() at time zone 'Asia/Jakarta')::date;
  v_date date;
  r record;
begin
  if p_stage not in('SIGNAL','STRUCTURED','THESIS','SHADOW','OUTCOMES') then
    raise exception 'unknown prospective stage %',p_stage;
  end if;
  if p_stage='OUTCOMES' then return v_today; end if;

  if p_stage='SIGNAL' then
    for r in
      select m.snapshot_date
      from public.flow_universe_capture_manifest_v1 m
      where m.universe_contract='TOP_900_UNIVERSE_V1' and m.capture_state='CAPTURED'
        and m.selected_count=900 and m.official_eod_date=m.snapshot_date
        and m.snapshot_date between v_today-7 and v_today
        and not exists(select 1 from public.flow_attribution_capture_manifest_v1 a
          where a.attribution_contract='IDX_PREDICTIVE_ATTRIBUTION_SHADOW_V1'
            and a.signal_date=m.snapshot_date and a.capture_state='CAPTURED'
            and a.prospective_driver_rows=4500 and a.candidate_rows=11700)
      order by m.snapshot_date
    loop
      if r.snapshot_date=v_today or coalesce((public.flow_prospective_lineage_status_v5(r.snapshot_date)->>'ready')::boolean,false) then
        return r.snapshot_date;
      end if;
    end loop;
    return v_today;
  end if;

  if p_stage='STRUCTURED' then
    select a.signal_date into v_date
    from public.flow_attribution_capture_manifest_v1 a
    where a.attribution_contract='IDX_PREDICTIVE_ATTRIBUTION_SHADOW_V1'
      and a.capture_state='CAPTURED' and a.prospective_driver_rows=4500 and a.candidate_rows=11700
      and a.signal_date between v_today-7 and v_today
      and (select count(*) from public.flow_attribution_structured_snapshot_v2 s
        where s.signal_date=a.signal_date and s.attribution_contract='IDX_STRUCTURED_ATTRIBUTION_SHADOW_V2')<900
    order by a.signal_date limit 1;
  elsif p_stage='THESIS' then
    select a.signal_date into v_date
    from public.flow_attribution_capture_manifest_v1 a
    where a.attribution_contract='IDX_PREDICTIVE_ATTRIBUTION_SHADOW_V1'
      and a.capture_state='CAPTURED' and a.prospective_driver_rows=4500 and a.candidate_rows=11700
      and a.signal_date between v_today-7 and v_today
      and (select count(*) from public.flow_attribution_structured_snapshot_v2 s
        where s.signal_date=a.signal_date and s.attribution_contract='IDX_STRUCTURED_ATTRIBUTION_SHADOW_V2')=900
      and not exists(select 1 from public.flow_prospective_pipeline_run_v2 p
        where p.session_date=a.signal_date and p.stage='THESIS' and p.run_state='COMPLETED')
    order by a.signal_date limit 1;
  else
    select a.signal_date into v_date
    from public.flow_attribution_capture_manifest_v1 a
    where a.attribution_contract='IDX_PREDICTIVE_ATTRIBUTION_SHADOW_V1'
      and a.capture_state='CAPTURED' and a.prospective_driver_rows=4500 and a.candidate_rows=11700
      and a.signal_date between v_today-7 and v_today
      and (select count(*) from public.flow_attribution_structured_snapshot_v2 s
        where s.signal_date=a.signal_date and s.attribution_contract='IDX_STRUCTURED_ATTRIBUTION_SHADOW_V2')=900
      and (select count(*) from public.flow_shadow_predictive_score_v1 s
        where s.signal_date=a.signal_date and s.model_contract='SHADOW_PREDICTIVE_SCORE_V1')<900
    order by a.signal_date limit 1;
  end if;
  return coalesce(v_date,v_today);
end
$fn$;

create or replace function public.flow_run_prospective_stage_v5(
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
      v_result:=public.flow_capture_attribution_prospective_signals_v5(p_session_date);
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
        then coalesce(v_result->>'failure_class',v_result->>'reason') end,
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

create or replace function public.flow_run_prospective_auto_v5(p_stage text)
returns jsonb
language plpgsql
security invoker
set search_path=''
as $fn$
declare v_date date;v_result jsonb;
begin
  v_date:=public.flow_select_prospective_session_v5(p_stage);
  v_result:=public.flow_run_prospective_stage_v5(p_stage,v_date);
  return v_result||jsonb_build_object('auto_selected_session',v_date,'scheduler_contract','PROSPECTIVE_AUTO_CATCHUP_V5');
end
$fn$;

revoke all on function public.flow_prospective_lineage_status_v5(date),
  public.flow_finalize_attribution_prospective_signal_v5(date,text,text),
  public.flow_capture_attribution_prospective_signals_v5(date),
  public.flow_select_prospective_session_v5(text),
  public.flow_run_prospective_stage_v5(text,date),
  public.flow_run_prospective_auto_v5(text)
  from public,anon,authenticated,service_role;
grant execute on function public.flow_prospective_lineage_status_v5(date),
  public.flow_capture_attribution_prospective_signals_v5(date),
  public.flow_select_prospective_session_v5(text),
  public.flow_run_prospective_stage_v5(text,date),
  public.flow_run_prospective_auto_v5(text) to service_role;

-- Replace only the prospective stage jobs. PIT source capture remains separate and
-- continues to run before the retry wave.
do $do$
declare r record;
begin
  for r in select jobid from cron.job where jobname in(
    'flow-attribution-forward-signals-v1','flow-attribution-structured-v2',
    'flow-attribution-thesis-v2','flow-attribution-shadow-score-v2',
    'flow-attribution-forward-outcomes-v1','flow-attribution-forward-signals-retry-v2',
    'flow-attribution-structured-retry-v2','flow-attribution-thesis-retry-v2',
    'flow-attribution-shadow-score-retry-v2','flow-gate15-lifecycle-retry-v2'
  ) loop perform cron.unschedule(r.jobid); end loop;
  perform cron.schedule('flow-attribution-forward-signals-v1','40 11 * * 1-5',
    'select public.flow_run_prospective_auto_v5(''SIGNAL'');');
  perform cron.schedule('flow-attribution-structured-v2','43 11 * * 1-5',
    'select public.flow_run_prospective_auto_v5(''STRUCTURED'');');
  perform cron.schedule('flow-attribution-thesis-v2','46 11 * * 1-5',
    'select public.flow_run_prospective_auto_v5(''THESIS'');');
  perform cron.schedule('flow-attribution-shadow-score-v2','49 11 * * 1-5',
    'select public.flow_run_prospective_auto_v5(''SHADOW'');');
  perform cron.schedule('flow-attribution-forward-outcomes-v1','0 12 * * 1-5',
    'select public.flow_run_prospective_auto_v5(''OUTCOMES'');');
  perform cron.schedule('flow-attribution-forward-signals-retry-v2','10 12 * * 1-5',
    'select public.flow_run_prospective_auto_v5(''SIGNAL'');');
  perform cron.schedule('flow-attribution-structured-retry-v2','13 12 * * 1-5',
    'select public.flow_run_prospective_auto_v5(''STRUCTURED'');');
  perform cron.schedule('flow-attribution-thesis-retry-v2','16 12 * * 1-5',
    'select public.flow_run_prospective_auto_v5(''THESIS'');');
  perform cron.schedule('flow-attribution-shadow-score-retry-v2','19 12 * * 1-5',
    'select public.flow_run_prospective_auto_v5(''SHADOW'');');
  perform cron.schedule('flow-gate15-lifecycle-retry-v2','25 12 * * 1-5',
    'select public.flow_run_prospective_auto_v5(''OUTCOMES'');');
end
$do$;
