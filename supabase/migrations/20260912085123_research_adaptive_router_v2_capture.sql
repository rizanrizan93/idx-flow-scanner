create or replace function public.flow_capture_research_adaptive_router_v2(p_signal_date date default null)
returns jsonb
language plpgsql
set search_path=''
as $function$
declare
  v_date date;
  v_source_rows integer;
  v_rows integer;
begin
  select coalesce(p_signal_date,max(signal_date))
    into v_date
  from public.flow_research_horizon_snapshot_v1;

  if v_date is null then
    return jsonb_build_object('status','SOURCE_NOT_READY','reason','NO_HORIZON_SNAPSHOTS');
  end if;

  select count(*) into v_source_rows
  from public.flow_research_horizon_snapshot_v1
  where signal_date=v_date
    and strategy_contract='RESEARCH_HORIZON_STRATEGIES_V1_1'
    and strategy_id in ('BRFE_5','BPL_20','QBA_60')
    and production_influence_enabled=false;

  if v_source_rows<>3 then
    return jsonb_build_object('status','SOURCE_NOT_READY','signal_date',v_date,'reason','INCOMPLETE_HORIZON_SNAPSHOT_SET','source_rows',v_source_rows);
  end if;

  with p as (
    select *
    from public.flow_research_adaptive_policy_v2
    where router_contract='ADAPTIVE_HORIZON_ROUTER_V2_1'
      and router_id='AHR_V2_40_40_20'
      and production_influence_enabled=false
  ), s as (
    select h.*,
      (p.sleeve_weights->>h.strategy_id)::numeric target_weight_pct,
      case when h.signal_state='ACTIVE' then (p.sleeve_weights->>h.strategy_id)::numeric else 0::numeric end allocated_weight_pct
    from p
    join public.flow_research_horizon_snapshot_v1 h
      on h.signal_date=v_date
     and h.strategy_contract='RESEARCH_HORIZON_STRATEGIES_V1_1'
     and h.strategy_id in ('BRFE_5','BPL_20','QBA_60')
     and h.production_influence_enabled=false
  ), a as (
    select
      p.router_contract,p.router_id,
      count(*) filter(where s.signal_state='ACTIVE')::int active_sleeve_count,
      coalesce(sum(s.allocated_weight_pct),0)::numeric active_weight_pct,
      jsonb_agg(
        jsonb_build_object(
          'strategy_id',s.strategy_id,
          'horizon_days',s.horizon_days,
          'target_weight_pct',s.target_weight_pct,
          'allocated_weight_pct',s.allocated_weight_pct,
          'market_gate_state',s.market_gate_state,
          'signal_state',s.signal_state,
          'eligible_count',s.eligible_count
        ) order by s.horizon_days
      ) allocation
    from p join s on true
    group by p.router_contract,p.router_id
  )
  insert into public.flow_research_adaptive_snapshot_v2(
    router_contract,router_id,signal_date,router_state,active_sleeve_count,
    active_weight_pct,cash_weight_pct,allocation,captured_at,production_influence_enabled
  )
  select
    a.router_contract,a.router_id,v_date,
    case when a.active_weight_pct=0 then 'ALL_CASH' when a.active_weight_pct=100 then 'FULLY_ALLOCATED' else 'ACTIVE_PARTIAL' end,
    a.active_sleeve_count,a.active_weight_pct,100-a.active_weight_pct,a.allocation,now(),false
  from a
  on conflict(router_contract,router_id,signal_date) do update set
    router_state=excluded.router_state,
    active_sleeve_count=excluded.active_sleeve_count,
    active_weight_pct=excluded.active_weight_pct,
    cash_weight_pct=excluded.cash_weight_pct,
    allocation=excluded.allocation,
    captured_at=excluded.captured_at,
    production_influence_enabled=false;

  get diagnostics v_rows=row_count;
  return jsonb_build_object('status','CAPTURED','signal_date',v_date,'router_rows',v_rows,'production_influence_enabled',false);
end;
$function$;