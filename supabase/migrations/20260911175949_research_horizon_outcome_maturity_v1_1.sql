create or replace function public.flow_refresh_research_horizon_outcomes_v1()
returns jsonb
language plpgsql
set search_path=''
as $function$
declare v_rows integer;
begin
  with active as (
    select s.*,c.elem
    from public.flow_research_horizon_snapshot_v1 s
    cross join lateral jsonb_array_elements(s.components) c(elem)
    where s.signal_state='ACTIVE' and s.production_influence_enabled=false
  ), joined as (
    select a.strategy_contract,a.strategy_id,a.horizon_days,a.signal_date,a.eligible_count,
      a.elem->>'ticker' ticker,l.*,
      case a.horizon_days when 5 then l.target_date_5d when 20 then l.target_date_20d when 60 then l.target_date_60d end target_d,
      case a.horizon_days when 5 then l.clean_forward_return_5d_pct when 20 then l.clean_forward_return_20d_pct when 60 then l.clean_forward_return_60d_pct end ret,
      case a.horizon_days when 5 then l.clean_alpha_vs_ihsg_5d_pct when 20 then l.clean_alpha_vs_ihsg_20d_pct when 60 then l.clean_alpha_vs_ihsg_60d_pct end alpha_i,
      case a.horizon_days when 5 then l.clean_alpha_vs_sector_5d_pct when 20 then l.clean_alpha_vs_sector_20d_pct when 60 then l.clean_alpha_vs_sector_60d_pct end alpha_s,
      case a.horizon_days when 5 then l.clean_mfe_5d_pct when 20 then l.clean_mfe_20d_pct when 60 then l.clean_mfe_60d_pct end mfe,
      case a.horizon_days when 5 then l.clean_mae_5d_pct when 20 then l.clean_mae_20d_pct when 60 then l.clean_mae_60d_pct end mae
    from active a
    left join public.flow_market_learning_labels_clean_v4c l on l.as_of_date=a.signal_date and l.ticker=a.elem->>'ticker'
  ), agg as (
    select strategy_contract,strategy_id,horizon_days,signal_date,max(eligible_count) component_count,
      max(target_d) target_date,count(*) filter(where ret is not null) valid_count,
      count(*) filter(where target_d is not null) target_seen,
      avg(ret) mean_ret,percentile_cont(0.5) within group(order by ret) filter(where ret is not null) median_ret,
      100.0*avg(case when ret>0 then 1.0 else 0.0 end) filter(where ret is not null) win_rate,
      avg(alpha_i) filter(where ret is not null) mean_alpha_i,avg(alpha_s) filter(where ret is not null) mean_alpha_s,
      avg(mfe) filter(where ret is not null) mean_mfe,avg(mae) filter(where ret is not null) mean_mae
    from joined group by strategy_contract,strategy_id,horizon_days,signal_date
  )
  insert into public.flow_research_horizon_outcome_v1(
    strategy_contract,strategy_id,horizon_days,signal_date,target_date,maturity_state,component_count,valid_component_count,
    excluded_component_count,coverage_pct,mean_return_pct,median_return_pct,win_rate_pct,mean_alpha_vs_ihsg_pct,
    mean_alpha_vs_sector_pct,mean_mfe_pct,mean_mae_pct,evaluated_at,production_influence_enabled
  )
  select strategy_contract,strategy_id,horizon_days,signal_date,target_date,
    case when target_seen<component_count then 'SOURCE_NOT_READY'
         when valid_count=component_count then 'MATURE_CLEAN'
         when valid_count>0 then 'MATURE_WITH_EXCLUSIONS'
         else 'MATURE_NO_CLEAN_COMPONENTS' end,
    component_count,valid_count,
    case when target_seen<component_count then 0 else greatest(component_count-valid_count,0) end,
    case when target_seen<component_count then null
         when component_count>0 then 100.0*valid_count/component_count end,
    mean_ret,median_ret,win_rate,mean_alpha_i,mean_alpha_s,mean_mfe,mean_mae,now(),false
  from agg
  on conflict(strategy_contract,strategy_id,signal_date) do update set
    target_date=excluded.target_date,maturity_state=excluded.maturity_state,component_count=excluded.component_count,
    valid_component_count=excluded.valid_component_count,excluded_component_count=excluded.excluded_component_count,
    coverage_pct=excluded.coverage_pct,mean_return_pct=excluded.mean_return_pct,median_return_pct=excluded.median_return_pct,
    win_rate_pct=excluded.win_rate_pct,mean_alpha_vs_ihsg_pct=excluded.mean_alpha_vs_ihsg_pct,
    mean_alpha_vs_sector_pct=excluded.mean_alpha_vs_sector_pct,mean_mfe_pct=excluded.mean_mfe_pct,mean_mae_pct=excluded.mean_mae_pct,
    evaluated_at=excluded.evaluated_at,production_influence_enabled=false;
  get diagnostics v_rows=row_count;
  return jsonb_build_object('status','REFRESHED','outcome_rows',v_rows,'production_influence_enabled',false);
end;
$function$;

comment on function public.flow_refresh_research_horizon_outcomes_v1() is 'Refresh clean prospective OOS basket outcomes. Immature baskets are SOURCE_NOT_READY with excluded=0 and NULL coverage until target maturity.';
