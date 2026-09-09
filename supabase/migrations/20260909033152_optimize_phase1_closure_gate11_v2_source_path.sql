create or replace function public.flow_refresh_driver_feature_stage_v2()
returns jsonb
language plpgsql
security invoker
set search_path=''
set work_mem='96MB'
as $fn$
declare
  v_contract constant text := 'IDX_DRIVER_WEEKLY_PIT_PANEL_V2';
  v_rows bigint;
  v_at timestamptz := clock_timestamp();
begin
  if not exists(select 1 from public.flow_driver_signal_panel_v1 where panel_contract=v_contract) then
    raise exception 'Gate11 V2 signal stage missing';
  end if;
  delete from public.flow_driver_panel_manifest_v1 where panel_contract=v_contract;
  delete from public.flow_driver_coverage_v1 where panel_contract=v_contract;
  delete from public.flow_driver_feature_panel_v1 where panel_contract=v_contract;

  insert into public.flow_driver_feature_panel_v1
  with bounds as (
    select min(signal_date) min_d,max(signal_date) max_d
    from public.flow_driver_signal_panel_v1 where panel_contract=v_contract
  ), residual_hist as (
    select r.*,
      lag(r.close,5) over(partition by r.ticker order by r.trade_date) close_lag5,
      lag(r.close,20) over(partition by r.ticker order by r.trade_date) close_lag20,
      max(r.high) over(partition by r.ticker order by r.trade_date rows between 19 preceding and current row) high_20
    from public.flow_stock_residual_activity_v2 r
    cross join bounds b
    where r.source_verified and r.trade_date between (b.min_d-interval '90 days')::date and b.max_d
  ), ihsg as (
    select trade_date,100.0*(close/nullif(lag(close,20) over(order by trade_date),0)-1.0) ihsg_return20
    from public.flow_official_index_summary where index_code='COMPOSITE' and source_verified
  ), b as (
    select r.trade_date as as_of_date,r.ticker,
      case when r.previous>0 then 100.0*(r.close/r.previous-1.0) end return_1d_pct,
      case when r.close_lag5>0 then 100.0*(r.close/r.close_lag5-1.0) end return_5d_pct,
      case when r.close_lag20>0 then 100.0*(r.close/r.close_lag20-1.0) end return_20d_pct,
      r.volatility_range_pct,case when r.high_20>0 then 100.0*(r.close/r.high_20-1.0) end close_vs_20d_high_pct,
      r.volume,r.traded_value,r.frequency,r.foreign_net,r.foreign_net_volume_pct,r.market_turnover_share_pct,
      r.volume_residual_z,r.stock_residual_activity_z,i.ihsg_return20,
      case when r.close_lag20 is not null then 21 when r.close_lag5 is not null then 6 else 1 end history_count_21,
      f.financial_state,f.current_filing_id,f.prior_filing_id,f.quality_score,f.growth_score,f.balance_score,f.cashflow_score,f.feature_states,
      ff.published_at financial_published_at,ff.available_from_date financial_available_from_date,m.source_snapshot_hash
    from public.flow_driver_signal_panel_v1 s
    join residual_hist r on r.trade_date=s.signal_date and r.ticker=s.ticker
    join public.flow_financial_shadow_panel_v5 f on f.as_of_date=s.signal_date and f.ticker=s.ticker and f.sample_contract='FINANCIAL_V5_WEEKLY_LAST_TRADING_DAY_PIT_1'
    join public.flow_market_memory_manifest_v4 m on m.as_of_date=s.signal_date and m.feature_contract='MARKET_MEMORY_V4_1' and m.source_verified
    left join public.flow_financial_filing_feature_v5 ff on ff.filing_id=f.current_filing_id
    left join ihsg i on i.trade_date=s.signal_date
    where s.panel_contract=v_contract
  )
  select v_contract,as_of_date,ticker,'MARKET_MEMORY_V4_1',history_count_21,
    jsonb_build_object(
      'FLOW_FOREIGN_ACCUMULATION',foreign_net_volume_pct,'FLOW_FOREIGN_DISTRIBUTION',foreign_net_volume_pct,
      'FLOW_PARTICIPANT_ACCUMULATION',case when return_5d_pct>0 then stock_residual_activity_z else 0 end,
      'FLOW_PARTICIPANT_DISTRIBUTION',case when return_5d_pct<0 then stock_residual_activity_z else 0 end,
      'FLOW_PERSISTENCE_20D',null,'FLOW_ACCELERATION_5V20',null,
      'FLOW_ABSORPTION',foreign_net_volume_pct-abs(return_5d_pct)+greatest(stock_residual_activity_z,0),
      'FLOW_DISTRIBUTION_RISK',greatest(-foreign_net_volume_pct,0)+greatest(-return_5d_pct,0)+greatest(stock_residual_activity_z,0),
      'PV_VOLUME_EXPANSION',null,'PV_ABNORMAL_VOLUME',volume_residual_z,
      'PV_PRICE_VOLUME_CONFIRMATION',greatest(return_5d_pct,0)*greatest(volume_residual_z,0),
      'PV_PRICE_VOLUME_DIVERGENCE',greatest(return_5d_pct,0)*greatest(-volume_residual_z,0),
      'PV_BREAKOUT_20D',close_vs_20d_high_pct,'PV_RELATIVE_MOMENTUM_20D',return_20d_pct-ihsg_return20,
      'PV_VOLATILITY_EXPANSION',null,'PV_VOLATILITY_CONTRACTION',null,'PV_LIQUIDITY_CONDITION',ln(1+market_turnover_share_pct),
      'MKT_IHSG_REGIME_20D',ihsg_return20,'MKT_BREADTH_20D',null,'MKT_RISK_ON_CONTEXT',null,
      'TECH_BOS_20D',null,'TECH_CHOCH',null,'TECH_LIQUIDITY_SWEEP_20D',null,'TECH_FVG_BULLISH',null,
      'TECH_DISPLACEMENT',null,'TECH_TREND_STRUCTURE',null,
      'TECH_PULLBACK_CONTINUATION',(return_20d_pct>0 and return_5d_pct between -5 and 0 and close_vs_20d_high_pct>-10)::int,
      'TECH_REVERSAL_ACCUMULATION',null,
      'FIN_BALANCE',balance_score,'FIN_CASHFLOW',cashflow_score,'FIN_GROWTH',growth_score,'FIN_QUALITY',quality_score,
      'LIQ_ADTV20',null,'LIQ_TURNOVER',market_turnover_share_pct,
      'LIQ_ILLIQUIDITY_AMIHUD',abs(return_1d_pct)/nullif(traded_value,0),
      'LIQ_PRICE_IMPACT_PROXY',volatility_range_pct/nullif(ln(1+traded_value),0),
      'LIQ_TRADABILITY_CONSTRAINT',(volume=0 or frequency=0 or traded_value=0)::int
    ),financial_state,coalesce(feature_states,'{}'::jsonb),financial_published_at,financial_available_from_date,
    current_filing_id,prior_filing_id,source_snapshot_hash,v_at,false
  from b;
  get diagnostics v_rows=row_count;
  return jsonb_build_object('status','FEATURE_STAGE_READY','feature_rows',v_rows,'panel_contract',v_contract,
    'source_path','DIRECT_PIT_RESIDUAL_PLUS_FINANCIAL_NO_HEAVY_VIEW','production_influence_enabled',false);
end;$fn$;

revoke all on function public.flow_refresh_driver_feature_stage_v2() from public,anon,authenticated;
grant execute on function public.flow_refresh_driver_feature_stage_v2() to service_role;
