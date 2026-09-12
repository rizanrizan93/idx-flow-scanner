create or replace function public.flow_refresh_research_adaptive_outcomes_v2()
returns jsonb
language plpgsql
set search_path=''
as $function$
declare
  v_rows integer;
begin
  with base as (
    select
      a.router_contract,a.router_id,a.signal_date,a.active_sleeve_count,
      a.active_weight_pct,a.cash_weight_pct,
      h.strategy_id,h.horizon_days,h.signal_state,
      (p.sleeve_weights->>h.strategy_id)::numeric target_weight_pct,
      case when h.signal_state='ACTIVE' then (p.sleeve_weights->>h.strategy_id)::numeric else 0::numeric end allocated_weight_pct,
      o.target_date,o.maturity_state,o.mean_return_pct,o.mean_alpha_vs_ihsg_pct,o.mean_mfe_pct,o.mean_mae_pct
    from public.flow_research_adaptive_snapshot_v2 a
    join public.flow_research_adaptive_policy_v2 p
      on p.router_contract=a.router_contract and p.router_id=a.router_id
     and p.production_influence_enabled=false
    join public.flow_research_horizon_snapshot_v1 h
      on h.signal_date=a.signal_date
     and h.strategy_contract='RESEARCH_HORIZON_STRATEGIES_V1_1'
     and h.strategy_id in ('BRFE_5','BPL_20','QBA_60')
     and h.production_influence_enabled=false
    left join public.flow_research_horizon_outcome_v1 o
      on o.signal_date=a.signal_date and o.strategy_id=h.strategy_id
     and o.production_influence_enabled=false
    where a.production_influence_enabled=false
  ), agg as (
    select
      router_contract,router_id,signal_date,
      max(active_sleeve_count)::int active_sleeve_count,
      max(active_weight_pct)::numeric active_weight_pct,
      max(cash_weight_pct)::numeric cash_weight_pct,
      count(*) filter(where signal_state='ACTIVE' and maturity_state like 'MATURE%')::int mature_sleeve_count,
      coalesce(sum(allocated_weight_pct) filter(where signal_state='ACTIVE' and maturity_state like 'MATURE%'),0)::numeric mature_weight_pct,
      max(target_date) filter(where signal_state='ACTIVE') completion_target_date,
      bool_and(coalesce(maturity_state='MATURE_CLEAN',false)) filter(where signal_state='ACTIVE') all_active_clean,
      jsonb_agg(
        jsonb_build_object(
          'strategy_id',strategy_id,
          'horizon_days',horizon_days,
          'signal_state',signal_state,
          'target_weight_pct',target_weight_pct,
          'allocated_weight_pct',allocated_weight_pct,
          'target_date',target_date,
          'maturity_state',maturity_state,
          'mean_return_pct',mean_return_pct,
          'mean_alpha_vs_ihsg_pct',mean_alpha_vs_ihsg_pct,
          'mean_mfe_pct',mean_mfe_pct,
          'mean_mae_pct',mean_mae_pct
        ) order by horizon_days
      ) sleeve_outcomes,
      sum((allocated_weight_pct/100.0)*mean_return_pct)
        filter(where signal_state='ACTIVE' and maturity_state like 'MATURE%') weighted_ret_partial,
      sum((allocated_weight_pct/100.0)*mean_alpha_vs_ihsg_pct)
        filter(where signal_state='ACTIVE' and maturity_state like 'MATURE%') weighted_alpha_partial,
      sum((allocated_weight_pct/100.0)*mean_mfe_pct)
        filter(where signal_state='ACTIVE' and maturity_state like 'MATURE%') weighted_mfe_partial,
      sum((allocated_weight_pct/100.0)*mean_mae_pct)
        filter(where signal_state='ACTIVE' and maturity_state like 'MATURE%') weighted_mae_partial
    from base
    group by router_contract,router_id,signal_date
  )
  insert into public.flow_research_adaptive_outcome_v2(
    router_contract,router_id,signal_date,completion_target_date,maturity_state,
    active_sleeve_count,mature_sleeve_count,active_weight_pct,mature_weight_pct,cash_weight_pct,pending_weight_pct,
    portfolio_return_pct,portfolio_alpha_vs_ihsg_pct,weighted_mfe_pct,weighted_mae_pct,
    sleeve_outcomes,evaluated_at,production_influence_enabled
  )
  select
    router_contract,router_id,signal_date,completion_target_date,
    case
      when active_sleeve_count=0 then 'NO_ACTIVE_SLEEVES'
      when mature_sleeve_count<active_sleeve_count then 'SOURCE_NOT_READY'
      when coalesce(all_active_clean,false) then 'MATURE_CLEAN'
      else 'MATURE_WITH_EXCLUSIONS'
    end,
    active_sleeve_count,mature_sleeve_count,active_weight_pct,mature_weight_pct,cash_weight_pct,
    greatest(active_weight_pct-mature_weight_pct,0),
    case when active_sleeve_count>0 and mature_sleeve_count=active_sleeve_count then weighted_ret_partial end,
    case when active_sleeve_count>0 and mature_sleeve_count=active_sleeve_count then weighted_alpha_partial end,
    case when active_sleeve_count>0 and mature_sleeve_count=active_sleeve_count then weighted_mfe_partial end,
    case when active_sleeve_count>0 and mature_sleeve_count=active_sleeve_count then weighted_mae_partial end,
    sleeve_outcomes,now(),false
  from agg
  on conflict(router_contract,router_id,signal_date) do update set
    completion_target_date=excluded.completion_target_date,
    maturity_state=excluded.maturity_state,
    active_sleeve_count=excluded.active_sleeve_count,
    mature_sleeve_count=excluded.mature_sleeve_count,
    active_weight_pct=excluded.active_weight_pct,
    mature_weight_pct=excluded.mature_weight_pct,
    cash_weight_pct=excluded.cash_weight_pct,
    pending_weight_pct=excluded.pending_weight_pct,
    portfolio_return_pct=excluded.portfolio_return_pct,
    portfolio_alpha_vs_ihsg_pct=excluded.portfolio_alpha_vs_ihsg_pct,
    weighted_mfe_pct=excluded.weighted_mfe_pct,
    weighted_mae_pct=excluded.weighted_mae_pct,
    sleeve_outcomes=excluded.sleeve_outcomes,
    evaluated_at=excluded.evaluated_at,
    production_influence_enabled=false;

  get diagnostics v_rows=row_count;
  return jsonb_build_object('status','REFRESHED','adaptive_outcome_rows',v_rows,'production_influence_enabled',false);
end;
$function$;