-- Gate 11 timeout-safe staging. COMPLETE is written only by the finalizer.

create or replace function public.flow_refresh_driver_signal_stage_v1()
returns jsonb language plpgsql security invoker set search_path='' set work_mem='64MB' as $fn$
declare v_contract constant text:='IDX_DRIVER_WEEKLY_PIT_PANEL_V1';v_built_at timestamptz;v_rows bigint;
begin
  select frozen_at into strict v_built_at from public.flow_driver_research_policy_v1 where registry_version='IDX_DRIVER_REGISTRY_GATE10_V1';
  delete from public.flow_driver_panel_manifest_v1 where panel_contract=v_contract;
  delete from public.flow_driver_coverage_v1 where panel_contract=v_contract;
  delete from public.flow_driver_feature_panel_v1 where panel_contract=v_contract;
  delete from public.flow_driver_signal_panel_v1 where panel_contract=v_contract;
  insert into public.flow_driver_signal_panel_v1
  with ihsg as (
    select trade_date,100.0*(close/nullif(lag(close,20) over(order by trade_date),0)-1.0) ihsg_return20
    from public.flow_official_index_summary where index_code='COMPOSITE' and source_verified
  )
  select v_contract,f.as_of_date,f.ticker,f.sector,'CURRENT_REGISTRY_CLASSIFICATION_NOT_HISTORICAL',
    case when i.ihsg_return20 is null then 'INSUFFICIENT_HISTORY' when i.ihsg_return20>=3 then 'RISK_ON'
      when i.ihsg_return20<=-3 then 'RISK_OFF' else 'NEUTRAL' end,i.ihsg_return20,
    'flow_financial_shadow_panel_v5+flow_market_learning_labels_clean_v4c',
    concat('FIN:',coalesce(f.current_filing_id,'NONE'),':MARKET:',f.as_of_date,':',f.ticker),
    (f.as_of_date::timestamp+time '16:15') at time zone 'Asia/Jakarta',f.as_of_date,
    l.target_date_5d,l.target_date_20d,l.target_date_60d,
    l.clean_forward_return_5d_pct,l.clean_forward_return_20d_pct,l.clean_forward_return_60d_pct,
    l.clean_alpha_vs_ihsg_5d_pct,l.clean_alpha_vs_ihsg_20d_pct,l.clean_alpha_vs_ihsg_60d_pct,
    null,null,null,l.clean_mfe_5d_pct,l.clean_mfe_20d_pct,l.clean_mfe_60d_pct,
    l.clean_mae_5d_pct,l.clean_mae_20d_pct,l.clean_mae_60d_pct,
    'INVALID_CURRENT_SECTOR_CLASSIFICATION_NOT_HISTORICAL',
    jsonb_build_object('financial_contract',f.sample_contract,'outcome_contract',l.clean_path_version,
      'target_is_outcome_not_feature',true,'sector_benchmark_fail_closed',true,'stage','SIGNAL'),v_built_at,false
  from public.flow_financial_shadow_panel_v5 f
  join public.flow_market_learning_labels_clean_v4c l on l.as_of_date=f.as_of_date and l.ticker=f.ticker
    and l.feature_contract='MARKET_MEMORY_V4_1'
  left join ihsg i on i.trade_date=f.as_of_date
  where f.sample_contract='FINANCIAL_V5_WEEKLY_LAST_TRADING_DAY_PIT_1';
  get diagnostics v_rows=row_count;
  return jsonb_build_object('status','SIGNAL_STAGE_READY','signal_rows',v_rows,'manifest_complete',false,'production_influence_enabled',false);
end;$fn$;

create or replace function public.flow_refresh_driver_feature_stage_v1()
returns jsonb language plpgsql security invoker set search_path='' set work_mem='64MB' as $fn$
declare v_contract constant text:='IDX_DRIVER_WEEKLY_PIT_PANEL_V1';v_built_at timestamptz;v_rows bigint;
begin
  select frozen_at into strict v_built_at from public.flow_driver_research_policy_v1 where registry_version='IDX_DRIVER_REGISTRY_GATE10_V1';
  if not exists(select 1 from public.flow_driver_signal_panel_v1 where panel_contract=v_contract) then raise exception 'Gate11 signal stage missing'; end if;
  delete from public.flow_driver_panel_manifest_v1 where panel_contract=v_contract;
  delete from public.flow_driver_coverage_v1 where panel_contract=v_contract;
  delete from public.flow_driver_feature_panel_v1 where panel_contract=v_contract;
  insert into public.flow_driver_feature_panel_v1
  with ihsg as (
    select trade_date,100.0*(close/nullif(lag(close,20) over(order by trade_date),0)-1.0) ihsg_return20
    from public.flow_official_index_summary where index_code='COMPOSITE' and source_verified
  ), b as (
    select p.*,i.ihsg_return20,
      case when p.return_20d_pct is not null then 21 when p.return_5d_pct is not null then 6 else 1 end history_count_21,
      f.financial_state,f.current_filing_id,f.prior_filing_id,f.quality_score,f.growth_score,f.balance_score,f.cashflow_score,f.feature_states,
      ff.published_at financial_published_at,ff.available_from_date financial_available_from_date
    from public.flow_driver_signal_panel_v1 s
    join public.flow_market_learning_panel_v4 p on p.as_of_date=s.signal_date and p.ticker=s.ticker
      and p.feature_contract='MARKET_MEMORY_V4_1' and p.source_verified
    join public.flow_financial_shadow_panel_v5 f on f.as_of_date=s.signal_date and f.ticker=s.ticker
      and f.sample_contract='FINANCIAL_V5_WEEKLY_LAST_TRADING_DAY_PIT_1'
    left join public.flow_financial_filing_feature_v5 ff on ff.filing_id=f.current_filing_id
    left join ihsg i on i.trade_date=s.signal_date
    where s.panel_contract=v_contract
  )
  select v_contract,as_of_date,ticker,feature_contract,history_count_21,
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
    current_filing_id,prior_filing_id,source_snapshot_hash,v_built_at,false from b;
  get diagnostics v_rows=row_count;
  return jsonb_build_object('status','FEATURE_STAGE_READY','feature_rows',v_rows,'manifest_complete',false,'production_influence_enabled',false);
end;$fn$;

create or replace function public.flow_refresh_driver_panel_v1()
returns jsonb language sql security invoker set search_path='' as $fn$
select jsonb_build_object('status','STAGED_REFRESH_REQUIRED','steps',jsonb_build_array(
 'flow_refresh_driver_signal_stage_v1','flow_refresh_driver_feature_stage_v1','flow_finalize_driver_panel_v1'),
 'partial_failure_safe',true,'production_influence_enabled',false);
$fn$;

revoke all on function public.flow_refresh_driver_signal_stage_v1() from public,anon,authenticated;
revoke all on function public.flow_refresh_driver_feature_stage_v1() from public,anon,authenticated;
revoke all on function public.flow_refresh_driver_panel_v1() from public,anon,authenticated;
grant execute on function public.flow_refresh_driver_signal_stage_v1() to service_role;
grant execute on function public.flow_refresh_driver_feature_stage_v1() to service_role;
grant execute on function public.flow_refresh_driver_panel_v1() to service_role;
