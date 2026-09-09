create or replace function public.flow_restore_gate11_pit_rollups_v2()
returns jsonb
language plpgsql
security invoker
set search_path=''
set work_mem='128MB'
as $fn$
declare
  v_contract constant text := 'IDX_DRIVER_WEEKLY_PIT_PANEL_V2';
  v_rows bigint;
begin
  drop table if exists pg_temp.flow_gate11_pit_rollups_v2;
  create temp table flow_gate11_pit_rollups_v2 on commit drop as
  with bounds as (
    select min(signal_date) min_d,max(signal_date) max_d
    from public.flow_driver_feature_panel_v1 where panel_contract=v_contract
  ), market_daily as (
    select r.trade_date as as_of_date,r.ticker,
      case when r.previous>0 then 100.0*(r.close/r.previous-1.0) end return_1d_pct,
      case when lag(r.close,5) over(partition by r.ticker order by r.trade_date)>0 then 100.0*(r.close/lag(r.close,5) over(partition by r.ticker order by r.trade_date)-1.0) end return_5d_pct,
      case when lag(r.close,20) over(partition by r.ticker order by r.trade_date)>0 then 100.0*(r.close/lag(r.close,20) over(partition by r.ticker order by r.trade_date)-1.0) end return_20d_pct,
      r.volatility_range_pct,r.volume,r.traded_value,r.frequency,r.foreign_net,r.foreign_net_volume_pct,
      r.market_turnover_share_pct,r.volume_residual_z,r.stock_residual_activity_z,r.close,r.high,r.low,
      count(*) over(partition by r.ticker order by r.trade_date rows between 20 preceding and current row) history_count_21,
      avg(r.foreign_net_volume_pct) over(partition by r.ticker order by r.trade_date rows between 4 preceding and current row) flow_avg5,
      avg(r.foreign_net_volume_pct) over(partition by r.ticker order by r.trade_date rows between 19 preceding and current row) flow_avg20,
      avg((r.foreign_net>0)::int) over(partition by r.ticker order by r.trade_date rows between 19 preceding and current row) flow_persistence20,
      avg(r.volume) over(partition by r.ticker order by r.trade_date rows between 19 preceding and current row) volume_avg20,
      avg(r.volatility_range_pct) over(partition by r.ticker order by r.trade_date rows between 19 preceding and current row) range_avg20,
      avg(r.traded_value) over(partition by r.ticker order by r.trade_date rows between 19 preceding and current row) adtv20,
      stddev_samp(case when r.previous>0 then 100.0*(r.close/r.previous-1.0) end) over(partition by r.ticker order by r.trade_date rows between 19 preceding and current row) return_sd20,
      avg(r.close) over(partition by r.ticker order by r.trade_date rows between 19 preceding and current row) close_avg20,
      max(r.high) over(partition by r.ticker order by r.trade_date rows between 20 preceding and 1 preceding) prior_high20,
      min(r.low) over(partition by r.ticker order by r.trade_date rows between 20 preceding and 1 preceding) prior_low20,
      max(r.high) over(partition by r.ticker order by r.trade_date rows between 5 preceding and 1 preceding) prior_high5,
      lag(r.high,2) over(partition by r.ticker order by r.trade_date) high_lag2
    from public.flow_stock_residual_activity_v2 r
    cross join bounds b
    where r.source_verified and r.trade_date between (b.min_d-interval '90 days')::date and b.max_d
  ), breadth as (
    select as_of_date,avg((close>=close_avg20)::int::numeric) filter(where history_count_21>=20) market_breadth20 from market_daily group by as_of_date
  ), ihsg_returns as (
    select trade_date,100.0*(close/nullif(lag(close,20) over(order by trade_date),0)-1.0) ihsg_return20
    from public.flow_official_index_summary where index_code='COMPOSITE' and source_verified
  ), ihsg_ranked as (
    select h.trade_date,h.ihsg_return20,r.trailing_rank
    from ihsg_returns h
    left join lateral (
      select case when count(*)>=20 then (count(*) filter(where t.ihsg_return20<=h.ihsg_return20)-1)::numeric/nullif(count(*)-1,0) end trailing_rank
      from (select x.ihsg_return20 from ihsg_returns x where x.trade_date<=h.trade_date and x.ihsg_return20 is not null order by x.trade_date desc limit 252) t
    ) r on true
  ), signal_calc as (
    select m.*,b.market_breadth20,i.ihsg_return20,i.trailing_rank
    from market_daily m
    join public.flow_driver_feature_panel_v1 f on f.panel_contract=v_contract and f.signal_date=m.as_of_date and f.ticker=m.ticker
    left join breadth b on b.as_of_date=m.as_of_date
    left join ihsg_ranked i on i.trade_date=m.as_of_date
  ), ranked as (
    select signal_calc.*,percent_rank() over(partition by as_of_date order by return_20d_pct) return20_xsec_rank from signal_calc
  )
  select as_of_date signal_date,ticker,history_count_21,
    flow_persistence20,flow_avg5-flow_avg20 flow_acceleration_5v20,
    volume/nullif(volume_avg20,0) pv_volume_expansion,
    volatility_range_pct/nullif(range_avg20,0) pv_volatility_expansion,
    -volatility_range_pct/nullif(range_avg20,0) pv_volatility_contraction,
    market_breadth20,(trailing_rank+market_breadth20)/2.0 mkt_risk_on_context,adtv20,
    (close>prior_high20)::int tech_bos_20d,(return_20d_pct<0 and close>prior_high5)::int tech_choch,
    return_1d_pct/nullif(return_sd20,0) tech_displacement,(low>high_lag2)::int tech_fvg_bullish,
    (low<prior_low20 and close>prior_low20)::int tech_liquidity_sweep_20d,
    (return_20d_pct<0 and close>prior_high5 and foreign_net_volume_pct>0)::int tech_reversal_accumulation,
    (return20_xsec_rank+(close>=close_avg20)::int)/2.0 tech_trend_structure
  from ranked;

  analyze pg_temp.flow_gate11_pit_rollups_v2;
  update public.flow_driver_feature_panel_v1 f
  set history_count=t.history_count_21,
      raw_values=f.raw_values || jsonb_build_object(
        'FLOW_PERSISTENCE_20D',t.flow_persistence20,'FLOW_ACCELERATION_5V20',t.flow_acceleration_5v20,
        'PV_VOLUME_EXPANSION',t.pv_volume_expansion,'PV_VOLATILITY_EXPANSION',t.pv_volatility_expansion,
        'PV_VOLATILITY_CONTRACTION',t.pv_volatility_contraction,'MKT_BREADTH_20D',t.market_breadth20,
        'MKT_RISK_ON_CONTEXT',t.mkt_risk_on_context,'LIQ_ADTV20',t.adtv20,
        'TECH_BOS_20D',t.tech_bos_20d,'TECH_CHOCH',t.tech_choch,'TECH_DISPLACEMENT',t.tech_displacement,
        'TECH_FVG_BULLISH',t.tech_fvg_bullish,'TECH_LIQUIDITY_SWEEP_20D',t.tech_liquidity_sweep_20d,
        'TECH_REVERSAL_ACCUMULATION',t.tech_reversal_accumulation,'TECH_TREND_STRUCTURE',t.tech_trend_structure
      )
  from pg_temp.flow_gate11_pit_rollups_v2 t
  where f.panel_contract=v_contract and f.signal_date=t.signal_date and f.ticker=t.ticker;
  get diagnostics v_rows=row_count;
  return jsonb_build_object('status','PASS','panel_contract',v_contract,'patched_feature_rows',v_rows,
    'method','DIRECT_PIT_RESIDUAL_TRAILING_WINDOWS_SIGNAL_DATE_ONLY_V2',
    'market_rank_method','TRAILING_UP_TO_252_OBSERVATIONS_NO_FUTURE_DATES',
    'sector_membership_repaired',false,'production_influence_enabled',false);
end;$fn$;

create or replace function public.flow_refresh_driver_lineage_v2()
returns jsonb language plpgsql security invoker set search_path='' as $fn$
declare v_contract constant text:='IDX_DRIVER_WEEKLY_PIT_PANEL_V2';v_rows bigint;v_at timestamptz:=clock_timestamp();
begin
  delete from public.flow_driver_panel_lineage_v2 where panel_contract=v_contract;
  insert into public.flow_driver_panel_lineage_v2(panel_contract,signal_date,ticker,market_source_max_date,stock_source_max_date,
    financial_current_available_from_date,financial_prior_available_from_date,sector_history_state,normalization_scope,calculated_at,production_influence_enabled)
  select v_contract,f.signal_date,f.ticker,f.signal_date,f.signal_date,f.financial_available_from_date,pf.available_from_date,
    s.sector_history_state,'SAME_SIGNAL_DATE_ONLY',v_at,false
  from public.flow_driver_feature_panel_v1 f
  join public.flow_driver_signal_panel_v1 s on s.panel_contract=v_contract and s.signal_date=f.signal_date and s.ticker=f.ticker
  left join public.flow_financial_filing_feature_v5 pf on pf.filing_id=f.prior_filing_id
  where f.panel_contract=v_contract;
  get diagnostics v_rows=row_count;
  return jsonb_build_object('status','PASS','lineage_rows',v_rows,'panel_contract',v_contract,'production_influence_enabled',false);
end;$fn$;

create or replace function public.flow_driver_panel_refresh_plan_v2()
returns jsonb language sql security invoker set search_path='' as $fn$
select jsonb_build_object('panel_contract','IDX_DRIVER_WEEKLY_PIT_PANEL_V2','transaction_model','ONE_STAGE_PER_TRANSACTION',
  'steps',jsonb_build_array('flow_refresh_driver_signal_stage_v2','flow_refresh_driver_feature_stage_v2','flow_restore_gate11_pit_rollups_v2','flow_refresh_driver_lineage_v2','flow_finalize_driver_panel_v2'),
  'production_influence_enabled',false);
$fn$;

revoke all on function public.flow_restore_gate11_pit_rollups_v2() from public,anon,authenticated;
revoke all on function public.flow_refresh_driver_lineage_v2() from public,anon,authenticated;
revoke all on function public.flow_driver_panel_refresh_plan_v2() from public,anon,authenticated;
grant execute on function public.flow_restore_gate11_pit_rollups_v2() to service_role;
grant execute on function public.flow_refresh_driver_lineage_v2() to service_role;
grant execute on function public.flow_driver_panel_refresh_plan_v2() to service_role;
