alter function public.flow_refresh_driver_panel_v1() rename to flow_refresh_driver_panel_reuse_only_v1;

create or replace function public.flow_restore_gate11_pit_rollups_v1()
returns jsonb
language plpgsql
security invoker
set search_path=''
set work_mem='96MB'
as $fn$
declare
  v_contract constant text := 'IDX_DRIVER_WEEKLY_PIT_PANEL_V1';
  v_rows bigint;
  v_tech_trend bigint;
  v_zero_before integer;
begin
  select count(*) into v_zero_before
  from public.flow_driver_coverage_v1 c
  join public.flow_driver_registry_v1 r
    on r.registry_version='IDX_DRIVER_REGISTRY_GATE10_V1'
   and r.driver_id=c.entity_id
  where c.panel_contract=v_contract
    and c.entity_type='DRIVER'
    and r.evaluation_eligible
    and c.coverage_pct=0
    and r.driver_id in (
      'FLOW_PERSISTENCE_20D','FLOW_ACCELERATION_5V20','LIQ_ADTV20',
      'MKT_BREADTH_20D','MKT_RISK_ON_CONTEXT',
      'PV_VOLUME_EXPANSION','PV_VOLATILITY_EXPANSION','PV_VOLATILITY_CONTRACTION',
      'TECH_BOS_20D','TECH_CHOCH','TECH_DISPLACEMENT','TECH_FVG_BULLISH',
      'TECH_LIQUIDITY_SWEEP_20D','TECH_REVERSAL_ACCUMULATION','TECH_TREND_STRUCTURE'
    );

  drop table if exists pg_temp.flow_gate11_pit_rollups;
  create temp table flow_gate11_pit_rollups on commit drop as
  with bounds as (
    select min(signal_date) min_d,max(signal_date) max_d
    from public.flow_driver_feature_panel_v1
    where panel_contract=v_contract
  ), market_daily as (
    select p.as_of_date,p.ticker,p.return_1d_pct,p.return_5d_pct,p.return_20d_pct,
      p.volatility_range_pct,p.close_vs_20d_high_pct,p.volume,p.traded_value,p.frequency,
      p.foreign_net,p.foreign_net_volume_pct,p.market_turnover_share_pct,
      p.volume_residual_z,p.stock_residual_activity_z,p.close,
      s.high,s.low,
      count(*) over(partition by p.ticker order by p.as_of_date rows between 20 preceding and current row) history_count_21,
      avg(p.foreign_net_volume_pct) over(partition by p.ticker order by p.as_of_date rows between 4 preceding and current row) flow_avg5,
      avg(p.foreign_net_volume_pct) over(partition by p.ticker order by p.as_of_date rows between 19 preceding and current row) flow_avg20,
      avg((p.foreign_net>0)::int) over(partition by p.ticker order by p.as_of_date rows between 19 preceding and current row) flow_persistence20,
      avg(p.volume) over(partition by p.ticker order by p.as_of_date rows between 19 preceding and current row) volume_avg20,
      avg(p.volatility_range_pct) over(partition by p.ticker order by p.as_of_date rows between 19 preceding and current row) range_avg20,
      avg(p.traded_value) over(partition by p.ticker order by p.as_of_date rows between 19 preceding and current row) adtv20,
      stddev_samp(p.return_1d_pct) over(partition by p.ticker order by p.as_of_date rows between 19 preceding and current row) return_sd20,
      avg(p.close) over(partition by p.ticker order by p.as_of_date rows between 19 preceding and current row) close_avg20,
      max(s.high) over(partition by p.ticker order by p.as_of_date rows between 20 preceding and 1 preceding) prior_high20,
      min(s.low) over(partition by p.ticker order by p.as_of_date rows between 20 preceding and 1 preceding) prior_low20,
      max(s.high) over(partition by p.ticker order by p.as_of_date rows between 5 preceding and 1 preceding) prior_high5,
      lag(s.high,2) over(partition by p.ticker order by p.as_of_date) high_lag2
    from public.flow_market_learning_panel_v4 p
    join public.flow_official_stock_summary s
      on s.trade_date=p.as_of_date and s.ticker=p.ticker
    cross join bounds b
    where p.feature_contract='MARKET_MEMORY_V4_1'
      and p.source_verified and s.source_verified
      and p.as_of_date between (b.min_d-interval '90 days')::date and b.max_d
  ), breadth as (
    select as_of_date,
      avg((close>=close_avg20)::int::numeric) filter(where history_count_21>=20) market_breadth20
    from market_daily
    group by as_of_date
  ), ihsg_series as (
    select trade_date,
      100.0*(close/nullif(lag(close,20) over(order by trade_date),0)-1.0) ihsg_return20
    from public.flow_official_index_summary
    where index_code='COMPOSITE' and source_verified
  ), signal_calc as (
    select m.*,b.market_breadth20,i.ihsg_return20
    from market_daily m
    join public.flow_driver_feature_panel_v1 f
      on f.panel_contract=v_contract and f.signal_date=m.as_of_date and f.ticker=m.ticker
    left join breadth b on b.as_of_date=m.as_of_date
    left join ihsg_series i on i.trade_date=m.as_of_date
  ), ranked as (
    select signal_calc.*,
      percent_rank() over(partition by as_of_date order by return_20d_pct) return20_xsec_rank,
      percent_rank() over(partition by as_of_date order by ihsg_return20) ihsg_xsec_rank
    from signal_calc
  )
  select as_of_date signal_date,ticker,history_count_21,
    flow_persistence20,
    flow_avg5-flow_avg20 flow_acceleration_5v20,
    volume/nullif(volume_avg20,0) pv_volume_expansion,
    volatility_range_pct/nullif(range_avg20,0) pv_volatility_expansion,
    -volatility_range_pct/nullif(range_avg20,0) pv_volatility_contraction,
    market_breadth20,
    (ihsg_xsec_rank+market_breadth20)/2.0 mkt_risk_on_context,
    adtv20,
    (close>prior_high20)::int tech_bos_20d,
    (return_20d_pct<0 and close>prior_high5)::int tech_choch,
    return_1d_pct/nullif(return_sd20,0) tech_displacement,
    (low>high_lag2)::int tech_fvg_bullish,
    (low<prior_low20 and close>prior_low20)::int tech_liquidity_sweep_20d,
    (return_20d_pct<0 and close>prior_high5 and foreign_net_volume_pct>0)::int tech_reversal_accumulation,
    (return20_xsec_rank+(close>=close_avg20)::int)/2.0 tech_trend_structure
  from ranked;

  analyze pg_temp.flow_gate11_pit_rollups;

  update public.flow_driver_feature_panel_v1 f
  set history_count=t.history_count_21,
      raw_values=f.raw_values || jsonb_build_object(
        'FLOW_PERSISTENCE_20D',t.flow_persistence20,
        'FLOW_ACCELERATION_5V20',t.flow_acceleration_5v20,
        'PV_VOLUME_EXPANSION',t.pv_volume_expansion,
        'PV_VOLATILITY_EXPANSION',t.pv_volatility_expansion,
        'PV_VOLATILITY_CONTRACTION',t.pv_volatility_contraction,
        'MKT_BREADTH_20D',t.market_breadth20,
        'MKT_RISK_ON_CONTEXT',t.mkt_risk_on_context,
        'LIQ_ADTV20',t.adtv20,
        'TECH_BOS_20D',t.tech_bos_20d,
        'TECH_CHOCH',t.tech_choch,
        'TECH_DISPLACEMENT',t.tech_displacement,
        'TECH_FVG_BULLISH',t.tech_fvg_bullish,
        'TECH_LIQUIDITY_SWEEP_20D',t.tech_liquidity_sweep_20d,
        'TECH_REVERSAL_ACCUMULATION',t.tech_reversal_accumulation,
        'TECH_TREND_STRUCTURE',t.tech_trend_structure
      )
  from pg_temp.flow_gate11_pit_rollups t
  where f.panel_contract=v_contract
    and f.signal_date=t.signal_date
    and f.ticker=t.ticker;
  get diagnostics v_rows=row_count;

  select count(*) into v_tech_trend
  from public.flow_driver_feature_panel_v1
  where panel_contract=v_contract
    and nullif(raw_values->>'TECH_TREND_STRUCTURE','') is not null;

  return jsonb_build_object(
    'status','PASS',
    'panel_contract',v_contract,
    'patched_feature_rows',v_rows,
    'previous_zero_coverage_rollups',v_zero_before,
    'tech_trend_nonnull_rows',v_tech_trend,
    'method','FROZEN_GATE10_FORMULAS_DAILY_TRAILING_WINDOWS_SIGNAL_DATE_ONLY',
    'sector_membership_repaired',false,
    'production_influence_enabled',false
  );
end;
$fn$;

create or replace function public.flow_refresh_driver_panel_v1()
returns jsonb
language plpgsql
security invoker
set search_path=''
as $fn$
declare
  v_base jsonb;
  v_rollups jsonb;
begin
  v_base := public.flow_refresh_driver_panel_reuse_only_v1();
  v_rollups := public.flow_restore_gate11_pit_rollups_v1();
  return v_base || jsonb_build_object('pit_rollup_restore',v_rollups);
end;
$fn$;

revoke all on function public.flow_refresh_driver_panel_reuse_only_v1() from public,anon,authenticated;
revoke all on function public.flow_restore_gate11_pit_rollups_v1() from public,anon,authenticated;
revoke all on function public.flow_refresh_driver_panel_v1() from public,anon,authenticated;
grant execute on function public.flow_refresh_driver_panel_reuse_only_v1() to service_role;
grant execute on function public.flow_restore_gate11_pit_rollups_v1() to service_role;
grant execute on function public.flow_refresh_driver_panel_v1() to service_role;
