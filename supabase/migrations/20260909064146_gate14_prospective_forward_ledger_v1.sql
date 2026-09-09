create table if not exists public.flow_attribution_prospective_driver_v1(
  attribution_contract text not null,
  signal_date date not null,
  ticker text not null,
  driver_id text not null,
  raw_value numeric,
  normalized_value numeric,
  driver_state text not null,
  source_state text not null,
  captured_at timestamptz not null default now(),
  production_influence_enabled boolean not null default false check(production_influence_enabled=false),
  primary key(attribution_contract,signal_date,ticker,driver_id)
);

create table if not exists public.flow_attribution_prospective_candidate_v1(
  attribution_contract text not null,
  signal_date date not null,
  ticker text not null,
  candidate_id text not null,
  candidate_type text not null,
  active_signal boolean not null,
  signal_state text not null,
  component_ids text[] not null,
  component_percentiles jsonb not null default '{}'::jsonb,
  base_close numeric,
  base_ihsg_close numeric,
  captured_at timestamptz not null default now(),
  production_influence_enabled boolean not null default false check(production_influence_enabled=false),
  primary key(attribution_contract,signal_date,ticker,candidate_id)
);

create table if not exists public.flow_attribution_forward_outcome_v1(
  attribution_contract text not null,
  signal_date date not null,
  ticker text not null,
  candidate_id text not null,
  horizon_days integer not null check(horizon_days in (5,20,60)),
  target_date date not null,
  forward_return_pct numeric,
  ihsg_return_pct numeric,
  alpha_vs_ihsg_pct numeric,
  outcome_state text not null,
  calculated_at timestamptz not null default now(),
  production_influence_enabled boolean not null default false check(production_influence_enabled=false),
  primary key(attribution_contract,signal_date,ticker,candidate_id,horizon_days)
);

create table if not exists public.flow_attribution_capture_manifest_v1(
  attribution_contract text not null,
  signal_date date not null,
  source_stock_rows integer not null default 0,
  source_residual_rows integer not null default 0,
  source_index_rows integer not null default 0,
  sector_snapshot_rows integer not null default 0,
  prospective_driver_rows integer not null default 0,
  candidate_rows integer not null default 0,
  active_candidate_rows integer not null default 0,
  capture_state text not null,
  details jsonb not null default '{}'::jsonb,
  captured_at timestamptz not null default now(),
  production_influence_enabled boolean not null default false check(production_influence_enabled=false),
  primary key(attribution_contract,signal_date)
);

create or replace function public.flow_capture_attribution_prospective_signals_v1(p_signal_date date default ((clock_timestamp() at time zone 'Asia/Jakarta')::date))
returns jsonb
language plpgsql
security invoker
set search_path=''
set work_mem='96MB'
as $fn$
declare
  v_contract text := 'IDX_PREDICTIVE_ATTRIBUTION_SHADOW_V1';
  v_stock integer;
  v_resid integer;
  v_index integer;
  v_sector integer;
  v_driver_rows integer := 0;
  v_candidate_rows integer := 0;
  v_active integer := 0;
begin
  if p_signal_date < date '2026-09-09' then
    raise exception 'Prospective attribution signals cannot be captured before untouched start date 2026-09-09';
  end if;

  select count(distinct ticker)::int into v_stock
  from public.flow_official_stock_summary
  where trade_date=p_signal_date and source_verified;

  select count(distinct ticker)::int into v_resid
  from public.flow_stock_residual_activity_v2
  where trade_date=p_signal_date and source_verified;

  select count(distinct index_code)::int into v_index
  from public.flow_official_index_summary
  where trade_date=p_signal_date and source_verified;

  select count(*)::int into v_sector
  from public.flow_sector_membership_snapshot_v1
  where snapshot_date=p_signal_date;

  if v_stock < 800 or v_resid < 800 or v_index < 12 or v_sector < 800 then
    insert into public.flow_attribution_capture_manifest_v1(
      attribution_contract,signal_date,source_stock_rows,source_residual_rows,source_index_rows,sector_snapshot_rows,capture_state,details,production_influence_enabled
    ) values(
      v_contract,p_signal_date,v_stock,v_resid,v_index,v_sector,'SOURCE_NOT_READY',
      jsonb_build_object('required_stock_rows',800,'required_residual_rows',800,'required_index_codes',12,'required_sector_snapshots',800),false
    ) on conflict(attribution_contract,signal_date) do update set
      source_stock_rows=excluded.source_stock_rows,source_residual_rows=excluded.source_residual_rows,
      source_index_rows=excluded.source_index_rows,sector_snapshot_rows=excluded.sector_snapshot_rows,
      capture_state='SOURCE_NOT_READY',details=excluded.details,captured_at=now();
    return jsonb_build_object('status','SOURCE_NOT_READY','signal_date',p_signal_date,'stock_rows',v_stock,'residual_rows',v_resid,'index_codes',v_index,'sector_snapshots',v_sector,'production_influence_enabled',false);
  end if;

  delete from public.flow_attribution_prospective_candidate_v1 where attribution_contract=v_contract and signal_date=p_signal_date;
  delete from public.flow_attribution_prospective_driver_v1 where attribution_contract=v_contract and signal_date=p_signal_date;

  with price_ranked as (
    select s.ticker,s.trade_date,s.close,
           row_number() over(partition by s.ticker order by s.trade_date desc) rn
    from public.flow_official_stock_summary s
    where s.trade_date<=p_signal_date and s.source_verified and s.close>0
  ), price_features as (
    select ticker,
      max(close) filter(where rn=1) close0,
      max(close) filter(where rn=6) close5,
      max(close) filter(where rn=21) close20,
      avg(close) filter(where rn between 1 and 20) avg20,
      count(*) filter(where rn<=21) history_count
    from price_ranked where rn<=21 group by ticker
  ), stock_base as (
    select p.ticker,p.close0,p.avg20,p.history_count,
      case when p.close5>0 then 100.0*(p.close0/p.close5-1) end return5,
      case when p.close20>0 then 100.0*(p.close0/p.close20-1) end return20,
      r.foreign_net_volume_pct,r.volume_residual_z
    from price_features p
    join public.flow_stock_residual_activity_v2 r on r.ticker=p.ticker and r.trade_date=p_signal_date and r.source_verified
  ), stock_ranked as (
    select b.*,percent_rank() over(order by b.return20) return20_rank
    from stock_base b
  ), index_ranked as (
    select i.index_code,i.trade_date,i.close,
      row_number() over(partition by i.index_code order by i.trade_date desc) rn
    from public.flow_official_index_summary i
    where i.trade_date<=p_signal_date and i.source_verified and i.close>0
  ), index_features as (
    select index_code,
      max(close) filter(where rn=1) close0,
      max(close) filter(where rn=21) close20,
      count(*) filter(where rn<=21) history_count
    from index_ranked where rn<=21 group by index_code
  ), index_returns as (
    select index_code,close0,
      case when close20>0 and history_count>=21 then 100.0*(close0/close20-1) end return20
    from index_features
  ), ihsg as (
    select close0,return20 from index_returns where index_code='COMPOSITE'
  ), sector_raw as (
    select s.ticker,
      case when ir.return20 is not null and h.return20 is not null then ir.return20-h.return20 end raw_value
    from public.flow_sector_membership_snapshot_v1 s
    left join public.flow_sector_index_map_v4 m on m.sector=s.sector
    left join index_returns ir on ir.index_code=m.index_code
    cross join ihsg h
    where s.snapshot_date=p_signal_date
  ), fin as (
    select ticker,balance_score,financial_state
    from public.flow_financial_shadow_snapshot_v5(p_signal_date)
  ), raw as (
    select b.ticker,'FLOW_FOREIGN_ACCUMULATION'::text driver_id,b.foreign_net_volume_pct::numeric raw_value,
      case when b.foreign_net_volume_pct is null then 'MISSING' else 'AVAILABLE' end driver_state,
      'flow_stock_residual_activity_v2'::text source_state
    from stock_ranked b
    union all
    select b.ticker,'PV_PRICE_VOLUME_CONFIRMATION',
      case when b.history_count>=6 and b.return5 is not null and b.volume_residual_z is not null then greatest(b.return5,0)*greatest(b.volume_residual_z,0) end,
      case when b.history_count<6 then 'INSUFFICIENT_HISTORY' when b.return5 is null or b.volume_residual_z is null then 'MISSING' else 'AVAILABLE' end,
      'flow_official_stock_summary+flow_stock_residual_activity_v2'
    from stock_ranked b
    union all
    select b.ticker,'TECH_TREND_STRUCTURE',
      case when b.history_count>=21 and b.return20 is not null and b.avg20 is not null then 0.5*b.return20_rank+0.5*(case when b.close0>=b.avg20 then 1 else 0 end) end,
      case when b.history_count<21 then 'INSUFFICIENT_HISTORY' when b.return20 is null or b.avg20 is null then 'MISSING' else 'AVAILABLE' end,
      'flow_official_stock_summary'
    from stock_ranked b
    union all
    select s.ticker,'MKT_SECTOR_RELATIVE_STRENGTH_20D',s.raw_value,
      case when s.raw_value is null then 'MISSING' else 'AVAILABLE' end,
      'flow_sector_membership_snapshot_v1+flow_sector_index_map_v4+flow_official_index_summary'
    from sector_raw s
    union all
    select b.ticker,'FIN_BALANCE',f.balance_score,
      case when f.ticker is null then 'MISSING' when f.financial_state<>'AVAILABLE' or f.balance_score is null then coalesce(f.financial_state,'MISSING') else 'AVAILABLE' end,
      'flow_financial_shadow_snapshot_v5'
    from stock_ranked b left join fin f on f.ticker=b.ticker
  ), normalized as (
    select r.*,
      case when driver_state='AVAILABLE' and raw_value is not null
           then percent_rank() over(partition by driver_id,driver_state order by raw_value)
      end normalized_value
    from raw r
  )
  insert into public.flow_attribution_prospective_driver_v1(
    attribution_contract,signal_date,ticker,driver_id,raw_value,normalized_value,driver_state,source_state,production_influence_enabled
  )
  select v_contract,p_signal_date,ticker,driver_id,raw_value,normalized_value,driver_state,source_state,false
  from normalized;
  get diagnostics v_driver_rows = row_count;

  with base as (
    select s.ticker,s.close base_close
    from public.flow_official_stock_summary s
    where s.trade_date=p_signal_date and s.source_verified
  ), ihsg as (
    select close base_ihsg_close from public.flow_official_index_summary
    where trade_date=p_signal_date and index_code='COMPOSITE' and source_verified limit 1
  ), components as (
    select b.ticker,f.candidate_id,f.candidate_type,f.component_ids,
      count(d.driver_id) filter(where d.driver_state='AVAILABLE' and d.normalized_value is not null) available_components,
      cardinality(f.component_ids) required_components,
      bool_and(coalesce(d.normalized_value>=0.80,false)) filter(where d.driver_id is not null) all_strong,
      coalesce(jsonb_object_agg(d.driver_id,round(d.normalized_value,6)) filter(where d.driver_id is not null),'{}'::jsonb) percentiles,
      b.base_close,h.base_ihsg_close
    from base b cross join ihsg h
    cross join public.flow_attribution_forward_registry_v1 f
    left join public.flow_attribution_prospective_driver_v1 d
      on d.attribution_contract=v_contract and d.signal_date=p_signal_date and d.ticker=b.ticker and d.driver_id=any(f.component_ids)
    where f.attribution_contract=v_contract and f.untouched_signal_start_date<=p_signal_date
    group by b.ticker,f.candidate_id,f.candidate_type,f.component_ids,b.base_close,h.base_ihsg_close
  )
  insert into public.flow_attribution_prospective_candidate_v1(
    attribution_contract,signal_date,ticker,candidate_id,candidate_type,active_signal,signal_state,component_ids,component_percentiles,
    base_close,base_ihsg_close,production_influence_enabled
  )
  select v_contract,p_signal_date,ticker,candidate_id,candidate_type,
    (available_components=required_components and coalesce(all_strong,false)),
    case when available_components<required_components then 'COMPONENT_UNAVAILABLE'
         when coalesce(all_strong,false) then 'ACTIVE'
         else 'AVAILABLE_NOT_ACTIVE' end,
    component_ids,percentiles,base_close,base_ihsg_close,false
  from components;
  get diagnostics v_candidate_rows = row_count;

  select count(*)::int into v_active
  from public.flow_attribution_prospective_candidate_v1
  where attribution_contract=v_contract and signal_date=p_signal_date and active_signal;

  insert into public.flow_attribution_capture_manifest_v1(
    attribution_contract,signal_date,source_stock_rows,source_residual_rows,source_index_rows,sector_snapshot_rows,
    prospective_driver_rows,candidate_rows,active_candidate_rows,capture_state,details,production_influence_enabled
  ) values(
    v_contract,p_signal_date,v_stock,v_resid,v_index,v_sector,v_driver_rows,v_candidate_rows,v_active,'CAPTURED',
    jsonb_build_object('strong_threshold',0.80,'drivers',jsonb_build_array('FLOW_FOREIGN_ACCUMULATION','MKT_SECTOR_RELATIVE_STRENGTH_20D','TECH_TREND_STRUCTURE','PV_PRICE_VOLUME_CONFIRMATION','FIN_BALANCE'),'untouched_start','2026-09-09'),false
  ) on conflict(attribution_contract,signal_date) do update set
    source_stock_rows=excluded.source_stock_rows,source_residual_rows=excluded.source_residual_rows,source_index_rows=excluded.source_index_rows,
    sector_snapshot_rows=excluded.sector_snapshot_rows,prospective_driver_rows=excluded.prospective_driver_rows,candidate_rows=excluded.candidate_rows,
    active_candidate_rows=excluded.active_candidate_rows,capture_state=excluded.capture_state,details=excluded.details,captured_at=now();

  return jsonb_build_object('status','CAPTURED','signal_date',p_signal_date,'driver_rows',v_driver_rows,'candidate_rows',v_candidate_rows,'active_candidate_rows',v_active,'production_influence_enabled',false);
end
$fn$;

create or replace function public.flow_evaluate_attribution_forward_outcomes_v1()
returns jsonb
language plpgsql
security invoker
set search_path=''
set work_mem='48MB'
as $fn$
declare v_rows integer := 0;
begin
  with active as (
    select c.* from public.flow_attribution_prospective_candidate_v1 c
    where c.attribution_contract='IDX_PREDICTIVE_ATTRIBUTION_SHADOW_V1' and c.active_signal
  ), expanded as (
    select a.*,h.horizon_days
    from active a cross join (values(5),(20),(60)) h(horizon_days)
  ), target_calendar as (
    select e.*,
      (select i.trade_date from public.flow_official_index_summary i
       where i.index_code='COMPOSITE' and i.source_verified and i.trade_date>e.signal_date
       order by i.trade_date offset (e.horizon_days-1) limit 1) target_date
    from expanded e
  ), outcome as (
    select t.*,
      s.close target_close,
      i.close target_ihsg_close
    from target_calendar t
    join public.flow_official_stock_summary s on s.ticker=t.ticker and s.trade_date=t.target_date and s.source_verified
    join public.flow_official_index_summary i on i.index_code='COMPOSITE' and i.trade_date=t.target_date and i.source_verified
    where t.target_date is not null and t.base_close>0 and t.base_ihsg_close>0
  )
  insert into public.flow_attribution_forward_outcome_v1(
    attribution_contract,signal_date,ticker,candidate_id,horizon_days,target_date,forward_return_pct,ihsg_return_pct,alpha_vs_ihsg_pct,outcome_state,production_influence_enabled
  )
  select attribution_contract,signal_date,ticker,candidate_id,horizon_days,target_date,
    100.0*(target_close/base_close-1),100.0*(target_ihsg_close/base_ihsg_close-1),
    100.0*(target_close/base_close-1)-100.0*(target_ihsg_close/base_ihsg_close-1),'MATURED',false
  from outcome
  on conflict(attribution_contract,signal_date,ticker,candidate_id,horizon_days) do nothing;
  get diagnostics v_rows = row_count;
  return jsonb_build_object('status','OK','new_matured_outcomes',v_rows,'production_influence_enabled',false);
end
$fn$;

create or replace function public.flow_run_attribution_pit_capture_v1()
returns jsonb
language plpgsql
security invoker
set search_path=''
as $fn$
declare v_sources jsonb; v_gaps jsonb;
begin
  v_sources := public.flow_capture_attribution_pit_sources_v1();
  v_gaps := public.flow_refresh_attribution_data_gap_v1();
  return jsonb_build_object('sources',v_sources,'gaps_refreshed',v_gaps is not null,'production_influence_enabled',false);
end
$fn$;

alter table public.flow_attribution_prospective_driver_v1 enable row level security;
alter table public.flow_attribution_prospective_candidate_v1 enable row level security;
alter table public.flow_attribution_forward_outcome_v1 enable row level security;
alter table public.flow_attribution_capture_manifest_v1 enable row level security;

revoke all on table public.flow_attribution_prospective_driver_v1,public.flow_attribution_prospective_candidate_v1,public.flow_attribution_forward_outcome_v1,public.flow_attribution_capture_manifest_v1 from public,anon,authenticated;
grant select,insert,update,delete on table public.flow_attribution_prospective_driver_v1,public.flow_attribution_prospective_candidate_v1,public.flow_attribution_forward_outcome_v1,public.flow_attribution_capture_manifest_v1 to service_role;
revoke all on function public.flow_capture_attribution_prospective_signals_v1(date),public.flow_evaluate_attribution_forward_outcomes_v1(),public.flow_run_attribution_pit_capture_v1() from public,anon,authenticated;
grant execute on function public.flow_capture_attribution_prospective_signals_v1(date),public.flow_evaluate_attribution_forward_outcomes_v1(),public.flow_run_attribution_pit_capture_v1() to service_role;

do $do$
declare r record;
begin
  for r in select jobid from cron.job where jobname in ('flow-attribution-pit-capture-v1','flow-attribution-forward-signals-v1','flow-attribution-forward-outcomes-v1') loop
    perform cron.unschedule(r.jobid);
  end loop;
  perform cron.schedule('flow-attribution-pit-capture-v1','35 11 * * 1-5','select public.flow_run_attribution_pit_capture_v1();');
  perform cron.schedule('flow-attribution-forward-signals-v1','40 11 * * 1-5','select public.flow_capture_attribution_prospective_signals_v1((now() at time zone ''Asia/Jakarta'')::date);');
  perform cron.schedule('flow-attribution-forward-outcomes-v1','50 11 * * 1-5','select public.flow_evaluate_attribution_forward_outcomes_v1();');
end
$do$;
