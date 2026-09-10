-- Bounded Top-900 prospective capture with retry-safe manifests and stage telemetry.
create table if not exists public.flow_prospective_pipeline_run_v2(
  run_id uuid primary key default extensions.gen_random_uuid(),
  pipeline_contract text not null,
  session_date date not null,
  stage text not null,
  attempt_no integer not null,
  run_state text not null check(run_state in(
    'STARTED','SOURCE_NOT_READY','CAPTURED','ALREADY_CAPTURED','COMPLETED','FAILED_CLOSED'
  )),
  selected_count integer,
  attempted_count integer,
  output_count integer,
  duration_ms numeric,
  failure_class text,
  failure_message text,
  details jsonb not null default '{}'::jsonb,
  started_at timestamptz not null default clock_timestamp(),
  finished_at timestamptz,
  production_influence_enabled boolean not null default false
    check(production_influence_enabled=false),
  unique(pipeline_contract,session_date,stage,attempt_no)
);

create index if not exists flow_prospective_pipeline_run_v2_latest_idx
  on public.flow_prospective_pipeline_run_v2(session_date desc,stage,attempt_no desc);

alter table public.flow_prospective_pipeline_run_v2 enable row level security;
revoke all on public.flow_prospective_pipeline_run_v2 from public,anon,authenticated,service_role;
grant select,insert,update on public.flow_prospective_pipeline_run_v2 to service_role;

create or replace function public.flow_capture_attribution_prospective_signals_v2(
  p_signal_date date default ((clock_timestamp() at time zone 'Asia/Jakarta')::date)
)
returns jsonb
language plpgsql
security invoker
set search_path=''
set work_mem='64MB'
as $fn$
declare
  v_contract constant text:='IDX_PREDICTIVE_ATTRIBUTION_SHADOW_V1';
  v_universe constant text:='TOP_900_UNIVERSE_V1';
  v_selected integer;v_stock integer;v_resid integer;v_index integer;v_sector integer;
  v_driver_rows integer:=0;v_candidate_rows integer:=0;v_active integer:=0;
  v_existing_state text;v_existing_drivers integer;v_existing_candidates integer;
  v_started timestamptz:=clock_timestamp();
begin
  if p_signal_date<date '2026-09-09' then
    raise exception 'Prospective attribution signals cannot predate untouched start 2026-09-09';
  end if;
  if not pg_try_advisory_xact_lock(hashtext(v_contract),
      (p_signal_date-date '2000-01-01')::integer) then
    return jsonb_build_object('status','FAILED_CLOSED','reason','CAPTURE_ALREADY_RUNNING',
      'signal_date',p_signal_date,'production_influence_enabled',false);
  end if;

  select count(*)::int into v_selected
  from public.flow_universe_snapshot_v1
  where universe_contract=v_universe and snapshot_date=p_signal_date and selected_top900;
  if v_selected<>900 or not exists(
    select 1 from public.flow_universe_capture_manifest_v1
    where universe_contract=v_universe and snapshot_date=p_signal_date
      and capture_state='CAPTURED' and selected_count=900
  ) then
    insert into public.flow_attribution_capture_manifest_v1(
      attribution_contract,signal_date,capture_state,details,production_influence_enabled
    ) values(v_contract,p_signal_date,'SOURCE_NOT_READY',
      jsonb_build_object('failure_class','TOP900_UNIVERSE_NOT_READY',
        'selected_count',v_selected,'required_selected_count',900),false)
    on conflict(attribution_contract,signal_date) do update set
      capture_state='SOURCE_NOT_READY',details=excluded.details,captured_at=clock_timestamp();
    return jsonb_build_object('status','SOURCE_NOT_READY','failure_class',
      'TOP900_UNIVERSE_NOT_READY','selected_count',v_selected,
      'production_influence_enabled',false);
  end if;

  select m.capture_state,m.prospective_driver_rows,m.candidate_rows
    into v_existing_state,v_existing_drivers,v_existing_candidates
  from public.flow_attribution_capture_manifest_v1 m
  where m.attribution_contract=v_contract and m.signal_date=p_signal_date;
  if v_existing_state='CAPTURED' and v_existing_drivers=4500
    and v_existing_candidates=11700
    and (select count(*) from public.flow_attribution_prospective_driver_v1 d
      where d.attribution_contract=v_contract and d.signal_date=p_signal_date)=4500
    and (select count(*) from public.flow_attribution_prospective_candidate_v1 c
      where c.attribution_contract=v_contract and c.signal_date=p_signal_date)=11700 then
    return jsonb_build_object('status','ALREADY_CAPTURED','signal_date',p_signal_date,
      'driver_rows',4500,'candidate_rows',11700,'attempted_count',900,
      'production_influence_enabled',false);
  end if;

  select count(*)::int into v_stock
  from public.flow_universe_snapshot_v1 u
  join public.flow_official_stock_summary s on s.ticker=u.ticker
    and s.trade_date=p_signal_date and s.source_verified
  where u.universe_contract=v_universe and u.snapshot_date=p_signal_date and u.selected_top900;
  select count(*)::int into v_resid
  from public.flow_universe_snapshot_v1 u
  join public.flow_stock_residual_activity_v2 r on r.ticker=u.ticker
    and r.trade_date=p_signal_date and r.source_verified
  where u.universe_contract=v_universe and u.snapshot_date=p_signal_date and u.selected_top900;
  select count(distinct index_code)::int into v_index
  from public.flow_official_index_summary where trade_date=p_signal_date and source_verified;
  select count(*)::int into v_sector
  from public.flow_universe_snapshot_v1 u
  join public.flow_sector_membership_snapshot_v1 s using(ticker)
  where u.universe_contract=v_universe and u.snapshot_date=p_signal_date and u.selected_top900
    and s.snapshot_date=p_signal_date;

  if v_stock<800 or v_resid<800 or v_index<12 or v_sector<800 then
    insert into public.flow_attribution_capture_manifest_v1(
      attribution_contract,signal_date,source_stock_rows,source_residual_rows,
      source_index_rows,sector_snapshot_rows,prospective_driver_rows,candidate_rows,
      active_candidate_rows,capture_state,details,production_influence_enabled
    ) values(v_contract,p_signal_date,v_stock,v_resid,v_index,v_sector,0,0,0,
      'SOURCE_NOT_READY',jsonb_build_object(
        'selected_count',v_selected,'attempted_count',v_selected,
        'required_stock_rows',800,'required_residual_rows',800,
        'required_index_codes',12,'required_sector_snapshots',800,
        'retry_transition','SOURCE_NOT_READY_TO_CAPTURED_ALLOWED'),false)
    on conflict(attribution_contract,signal_date) do update set
      source_stock_rows=excluded.source_stock_rows,
      source_residual_rows=excluded.source_residual_rows,
      source_index_rows=excluded.source_index_rows,
      sector_snapshot_rows=excluded.sector_snapshot_rows,
      prospective_driver_rows=0,candidate_rows=0,active_candidate_rows=0,
      capture_state='SOURCE_NOT_READY',details=excluded.details,captured_at=clock_timestamp();
    return jsonb_build_object('status','SOURCE_NOT_READY','signal_date',p_signal_date,
      'selected_count',v_selected,'attempted_count',v_selected,'stock_rows',v_stock,
      'residual_rows',v_resid,'index_codes',v_index,'sector_snapshots',v_sector,
      'production_influence_enabled',false);
  end if;

  delete from public.flow_attribution_prospective_candidate_v1
    where attribution_contract=v_contract and signal_date=p_signal_date;
  delete from public.flow_attribution_prospective_driver_v1
    where attribution_contract=v_contract and signal_date=p_signal_date;

  with universe as materialized(
    select u.ticker
    from public.flow_universe_snapshot_v1 u
    where u.universe_contract=v_universe and u.snapshot_date=p_signal_date
      and u.selected_top900
  ), price_arrays as materialized(
    select u.ticker,p.closes,p.history_count
    from universe u
    left join lateral(
      select array_agg(x.close order by x.trade_date desc) closes,count(*)::int history_count
      from(
        select s.trade_date,s.close
        from public.flow_official_stock_summary s
        where s.ticker=u.ticker and s.trade_date<=p_signal_date
          and s.source_verified and s.close>0
        order by s.trade_date desc limit 21
      ) x
    ) p on true
  ), price_features as(
    select p.ticker,p.closes[1] close0,p.closes[6] close5,p.closes[21] close20,
      (select avg(v) from unnest(p.closes[1:20]) v) avg20,p.history_count
    from price_arrays p
  ), stock_base as(
    select p.ticker,p.close0,p.avg20,p.history_count,
      case when p.close5>0 then 100.0*(p.close0/p.close5-1) end return5,
      case when p.close20>0 then 100.0*(p.close0/p.close20-1) end return20,
      r.foreign_net_volume_pct,r.volume_residual_z
    from price_features p
    left join public.flow_stock_residual_activity_v2 r on r.ticker=p.ticker
      and r.trade_date=p_signal_date and r.source_verified
  ), stock_ranked as(
    select b.*,case when b.return20 is not null then percent_rank()
      over(partition by(b.return20 is not null) order by b.return20) end return20_rank
    from stock_base b
  ), index_ranked as(
    select i.index_code,i.close,row_number() over(partition by i.index_code order by i.trade_date desc) rn
    from public.flow_official_index_summary i
    where i.trade_date<=p_signal_date and i.source_verified and i.close>0
  ), index_returns as(
    select index_code,max(close) filter(where rn=1) close0,
      case when count(*) filter(where rn<=21)>=21 and max(close) filter(where rn=21)>0
        then 100.0*(max(close) filter(where rn=1)/max(close) filter(where rn=21)-1) end return20
    from index_ranked where rn<=21 group by index_code
  ), ihsg as(select close0,return20 from index_returns where index_code='COMPOSITE'),
  sector_raw as(
    select u.ticker,case when ir.return20 is not null and h.return20 is not null
      then ir.return20-h.return20 end raw_value
    from universe u
    left join public.flow_sector_membership_snapshot_v1 s on s.ticker=u.ticker
      and s.snapshot_date=p_signal_date
    left join public.flow_sector_index_map_v4 m on m.sector=s.sector
    left join index_returns ir on ir.index_code=m.index_code
    cross join ihsg h
  ), fin as materialized(
    select ticker,balance_score,financial_state
    from public.flow_financial_shadow_snapshot_v6(p_signal_date)
  ), raw as(
    select b.ticker,'FLOW_FOREIGN_ACCUMULATION'::text driver_id,
      b.foreign_net_volume_pct::numeric raw_value,
      case when b.foreign_net_volume_pct is null then 'MISSING' else 'AVAILABLE' end driver_state,
      'flow_stock_residual_activity_v2'::text source_state from stock_ranked b
    union all
    select b.ticker,'PV_PRICE_VOLUME_CONFIRMATION',
      case when b.history_count>=6 and b.return5 is not null and b.volume_residual_z is not null
        then greatest(b.return5,0)*greatest(b.volume_residual_z,0) end,
      case when b.history_count<6 then 'INSUFFICIENT_HISTORY'
        when b.return5 is null or b.volume_residual_z is null then 'MISSING' else 'AVAILABLE' end,
      'flow_official_stock_summary+flow_stock_residual_activity_v2' from stock_ranked b
    union all
    select b.ticker,'TECH_TREND_STRUCTURE',
      case when b.history_count>=21 and b.return20 is not null and b.avg20 is not null
        then 0.5*b.return20_rank+0.5*(case when b.close0>=b.avg20 then 1 else 0 end) end,
      case when b.history_count<21 then 'INSUFFICIENT_HISTORY'
        when b.return20 is null or b.avg20 is null then 'MISSING' else 'AVAILABLE' end,
      'flow_official_stock_summary' from stock_ranked b
    union all
    select s.ticker,'MKT_SECTOR_RELATIVE_STRENGTH_20D',s.raw_value,
      case when s.raw_value is null then 'MISSING' else 'AVAILABLE' end,
      'flow_sector_membership_snapshot_v1+flow_sector_index_map_v4+flow_official_index_summary'
      from sector_raw s
    union all
    select b.ticker,'FIN_BALANCE',f.balance_score,
      case when f.ticker is null then 'MISSING'
        when f.financial_state<>'AVAILABLE' or f.balance_score is null
          then coalesce(f.financial_state,'MISSING') else 'AVAILABLE' end,
      'flow_financial_shadow_snapshot_v6'
      from stock_ranked b left join fin f using(ticker)
  ), normalized as(
    select r.*,case when driver_state='AVAILABLE' and raw_value is not null
      then percent_rank() over(partition by driver_id,driver_state order by raw_value) end normalized_value
    from raw r
  )
  insert into public.flow_attribution_prospective_driver_v1(
    attribution_contract,signal_date,ticker,driver_id,raw_value,normalized_value,
    driver_state,source_state,captured_at,production_influence_enabled
  )
  select v_contract,p_signal_date,ticker,driver_id,raw_value,normalized_value,
    driver_state,source_state,v_started,false from normalized;
  get diagnostics v_driver_rows=row_count;
  if v_driver_rows<>4500 then raise exception 'Top900 driver grid mismatch: %',v_driver_rows; end if;

  with universe as(
    select u.ticker
    from public.flow_universe_snapshot_v1 u
    where u.universe_contract=v_universe and u.snapshot_date=p_signal_date and u.selected_top900
  ), base as(
    select u.ticker,s.close base_close
    from universe u left join public.flow_official_stock_summary s on s.ticker=u.ticker
      and s.trade_date=p_signal_date and s.source_verified
  ), ihsg as(
    select close base_ihsg_close from public.flow_official_index_summary
    where trade_date=p_signal_date and index_code='COMPOSITE' and source_verified limit 1
  ), components as(
    select b.ticker,f.candidate_id,f.candidate_type,f.component_ids,
      count(d.driver_id) filter(where d.driver_state='AVAILABLE' and d.normalized_value is not null) available_components,
      cardinality(f.component_ids) required_components,
      bool_and(coalesce(d.normalized_value>=0.80,false)) filter(where d.driver_id is not null) all_strong,
      coalesce(jsonb_object_agg(d.driver_id,round(d.normalized_value,6))
        filter(where d.driver_id is not null),'{}'::jsonb) percentiles,
      b.base_close,h.base_ihsg_close
    from base b cross join ihsg h
    cross join public.flow_attribution_forward_registry_v1 f
    left join public.flow_attribution_prospective_driver_v1 d
      on d.attribution_contract=v_contract and d.signal_date=p_signal_date
      and d.ticker=b.ticker and d.driver_id=any(f.component_ids)
    where f.attribution_contract=v_contract and f.untouched_signal_start_date<=p_signal_date
    group by b.ticker,f.candidate_id,f.candidate_type,f.component_ids,b.base_close,h.base_ihsg_close
  )
  insert into public.flow_attribution_prospective_candidate_v1(
    attribution_contract,signal_date,ticker,candidate_id,candidate_type,active_signal,
    signal_state,component_ids,component_percentiles,base_close,base_ihsg_close,
    captured_at,production_influence_enabled
  )
  select v_contract,p_signal_date,ticker,candidate_id,candidate_type,
    (base_close>0 and base_ihsg_close>0 and available_components=required_components
      and coalesce(all_strong,false)),
    case when base_close is null or base_ihsg_close is null then 'BASE_PRICE_UNAVAILABLE'
      when available_components<required_components then 'COMPONENT_UNAVAILABLE'
      when coalesce(all_strong,false) then 'ACTIVE' else 'AVAILABLE_NOT_ACTIVE' end,
    component_ids,percentiles,base_close,base_ihsg_close,v_started,false
  from components;
  get diagnostics v_candidate_rows=row_count;
  if v_candidate_rows<>11700 then raise exception 'Top900 candidate grid mismatch: %',v_candidate_rows; end if;
  select count(*)::int into v_active from public.flow_attribution_prospective_candidate_v1
  where attribution_contract=v_contract and signal_date=p_signal_date and active_signal;

  insert into public.flow_attribution_capture_manifest_v1(
    attribution_contract,signal_date,source_stock_rows,source_residual_rows,
    source_index_rows,sector_snapshot_rows,prospective_driver_rows,candidate_rows,
    active_candidate_rows,capture_state,details,captured_at,production_influence_enabled
  ) values(v_contract,p_signal_date,v_stock,v_resid,v_index,v_sector,v_driver_rows,
    v_candidate_rows,v_active,'CAPTURED',jsonb_build_object(
      'runtime_contract','PROSPECTIVE_TOP900_PIPELINE_V2','selected_count',v_selected,
      'attempted_count',v_selected,'driver_grid_expected',4500,
      'candidate_grid_expected',11700,'strong_threshold',0.80,
      'financial_source','flow_financial_shadow_snapshot_v6',
      'retry_transition','SOURCE_NOT_READY_TO_CAPTURED_PROVEN',
      'duration_ms',round(extract(epoch from(clock_timestamp()-v_started))*1000,3),
      'untouched_start','2026-09-09'),v_started,false)
  on conflict(attribution_contract,signal_date) do update set
    source_stock_rows=excluded.source_stock_rows,
    source_residual_rows=excluded.source_residual_rows,
    source_index_rows=excluded.source_index_rows,
    sector_snapshot_rows=excluded.sector_snapshot_rows,
    prospective_driver_rows=excluded.prospective_driver_rows,
    candidate_rows=excluded.candidate_rows,
    active_candidate_rows=excluded.active_candidate_rows,
    capture_state='CAPTURED',details=excluded.details,captured_at=excluded.captured_at;
  return jsonb_build_object('status','CAPTURED','signal_date',p_signal_date,
    'selected_count',v_selected,'attempted_count',v_selected,'driver_rows',v_driver_rows,
    'candidate_rows',v_candidate_rows,'active_candidate_rows',v_active,
    'duration_ms',round(extract(epoch from(clock_timestamp()-v_started))*1000,3),
    'production_influence_enabled',false);
end
$fn$;

create or replace function public.flow_run_attribution_signal_cycle_v3(
  p_signal_date date default ((clock_timestamp() at time zone 'Asia/Jakarta')::date)
)
returns jsonb
language plpgsql
security invoker
set search_path=''
as $fn$
declare v_signal jsonb;v_structured jsonb;v_thesis jsonb;v_shadow jsonb;
  v_attempt integer;v_run uuid;v_started timestamptz:=clock_timestamp();
begin
  select coalesce(max(attempt_no),0)+1 into v_attempt
  from public.flow_prospective_pipeline_run_v2
  where pipeline_contract='PROSPECTIVE_TOP900_PIPELINE_V2'
    and session_date=p_signal_date and stage='SIGNAL_CYCLE';
  insert into public.flow_prospective_pipeline_run_v2(
    pipeline_contract,session_date,stage,attempt_no,run_state,selected_count,
    attempted_count,production_influence_enabled
  ) values('PROSPECTIVE_TOP900_PIPELINE_V2',p_signal_date,'SIGNAL_CYCLE',v_attempt,
    'STARTED',900,900,false) returning run_id into v_run;
  begin
    v_signal:=public.flow_capture_attribution_prospective_signals_v2(p_signal_date);
    if coalesce(v_signal->>'status','') not in('CAPTURED','ALREADY_CAPTURED') then
      update public.flow_prospective_pipeline_run_v2 set
        run_state=case when v_signal->>'status'='SOURCE_NOT_READY'
          then 'SOURCE_NOT_READY' else 'FAILED_CLOSED' end,
        output_count=0,details=v_signal,
        duration_ms=extract(epoch from(clock_timestamp()-v_started))*1000,
        finished_at=clock_timestamp() where run_id=v_run;
      return jsonb_build_object('signal',v_signal,'structured',jsonb_build_object('status','NOT_RUN'),
        'thesis',jsonb_build_object('status','NOT_RUN'),
        'shadow_score',jsonb_build_object('status','NOT_RUN'),
        'production_influence_enabled',false);
    end if;
    v_structured:=public.flow_capture_structured_attribution_v2(p_signal_date);
    if coalesce(v_structured->>'status','')='CAPTURED' then
      v_thesis:=public.flow_refresh_thesis_lifecycle_v1(p_signal_date);
      v_shadow:=public.flow_capture_shadow_predictive_score_v1(p_signal_date);
    else
      v_thesis:=jsonb_build_object('status','NOT_RUN');
      v_shadow:=jsonb_build_object('status','NOT_RUN');
    end if;
    update public.flow_prospective_pipeline_run_v2 set
      run_state=case when v_signal->>'status'='ALREADY_CAPTURED'
        then 'ALREADY_CAPTURED' else 'CAPTURED' end,
      output_count=coalesce((v_signal->>'candidate_rows')::int,11700),
      details=jsonb_build_object('signal',v_signal,'structured',v_structured,
        'thesis',v_thesis,'shadow_score',v_shadow),
      duration_ms=extract(epoch from(clock_timestamp()-v_started))*1000,
      finished_at=clock_timestamp() where run_id=v_run;
    return jsonb_build_object('signal',v_signal,'structured',v_structured,'thesis',v_thesis,
      'shadow_score',v_shadow,'production_influence_enabled',false);
  exception when others then
    update public.flow_prospective_pipeline_run_v2 set run_state='FAILED_CLOSED',
      failure_class=sqlstate,failure_message=left(sqlerrm,1000),
      duration_ms=extract(epoch from(clock_timestamp()-v_started))*1000,
      finished_at=clock_timestamp() where run_id=v_run;
    return jsonb_build_object('signal',jsonb_build_object('status','FAILED_CLOSED',
      'sqlstate',sqlstate,'message',left(sqlerrm,1000)),
      'structured',jsonb_build_object('status','NOT_RUN'),
      'thesis',jsonb_build_object('status','NOT_RUN'),
      'shadow_score',jsonb_build_object('status','NOT_RUN'),
      'production_influence_enabled',false);
  end;
end
$fn$;

revoke all on function public.flow_capture_attribution_prospective_signals_v2(date),
  public.flow_run_attribution_signal_cycle_v3(date)
  from public,anon,authenticated,service_role;
grant execute on function public.flow_capture_attribution_prospective_signals_v2(date),
  public.flow_run_attribution_signal_cycle_v3(date) to service_role;

do $do$
declare r record;
begin
  for r in select jobid from cron.job where jobname in(
    'flow-attribution-forward-signals-v1','flow-attribution-forward-signals-retry-v2'
  ) loop perform cron.unschedule(r.jobid); end loop;
  perform cron.schedule('flow-attribution-forward-signals-v1','40 11 * * 1-5',
    'select public.flow_run_attribution_signal_cycle_v3((now() at time zone ''Asia/Jakarta'')::date);');
  perform cron.schedule('flow-attribution-forward-signals-retry-v2','10 12 * * 1-5',
    'select public.flow_run_attribution_signal_cycle_v3((now() at time zone ''Asia/Jakarta'')::date);');
end
$do$;
