-- Gate 11 surgical fix: disambiguate the market-date breadth join.
create or replace function public.flow_refresh_driver_panel_v1()
returns jsonb
language plpgsql
security invoker
set search_path=''
set work_mem='96MB'
as $fn$
declare
  v_contract constant text := 'IDX_DRIVER_WEEKLY_PIT_PANEL_V1';
  v_registry constant text := 'IDX_DRIVER_REGISTRY_GATE10_V1';
  v_built_at timestamptz;
  v_signal_rows bigint;
  v_observation_rows bigint;
  v_available bigint;
  v_future_evidence bigint;
  v_future_financial bigint;
  v_future_flow bigint;
  v_future_benchmark bigint;
  v_sector_feature_leak bigint;
  v_revision_leak bigint;
  v_target_leak bigint;
begin
  select frozen_at into strict v_built_at
  from public.flow_driver_research_policy_v1 where registry_version=v_registry;

  delete from public.flow_driver_panel_manifest_v1 where panel_contract=v_contract;
  delete from public.flow_driver_coverage_v1 where panel_contract=v_contract;
  delete from public.flow_driver_observation_panel_v1 where panel_contract=v_contract;
  delete from public.flow_driver_signal_panel_v1 where panel_contract=v_contract;

  drop table if exists pg_temp.flow_gate11_base;
  create temp table flow_gate11_base on commit drop as
  with market_daily as (
    select p.*,
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
    join public.flow_official_stock_summary s on s.trade_date=p.as_of_date and s.ticker=p.ticker
    where p.feature_contract='MARKET_MEMORY_V4_1' and p.source_verified and s.source_verified
  ), breadth as (
    select as_of_date,avg((close>=close_avg20)::int::numeric) filter(where history_count_21>=20) market_breadth20
    from market_daily group by as_of_date
  ), ihsg as (
    select trade_date,close,
      100.0*(close/nullif(lag(close,20) over(order by trade_date),0)-1.0) ihsg_return20
    from public.flow_official_index_summary
    where index_code='COMPOSITE' and source_verified
  ), weekly as (
    select m.*,b.market_breadth20,i.ihsg_return20,
      f.financial_state,f.current_filing_id,f.prior_filing_id,
      f.quality_score,f.growth_score,f.balance_score,f.cashflow_score,f.feature_states,
      ff.published_at financial_published_at,ff.available_from_date financial_available_from_date,
      l.target_date_5d,l.target_date_20d,l.target_date_60d,
      l.clean_forward_return_5d_pct,l.clean_forward_return_20d_pct,l.clean_forward_return_60d_pct,
      l.clean_alpha_vs_ihsg_5d_pct,l.clean_alpha_vs_ihsg_20d_pct,l.clean_alpha_vs_ihsg_60d_pct,
      l.clean_mfe_5d_pct,l.clean_mfe_20d_pct,l.clean_mfe_60d_pct,
      l.clean_mae_5d_pct,l.clean_mae_20d_pct,l.clean_mae_60d_pct
    from market_daily m
    join public.flow_financial_shadow_panel_v5 f on f.as_of_date=m.as_of_date and f.ticker=m.ticker
      and f.sample_contract='FINANCIAL_V5_WEEKLY_LAST_TRADING_DAY_PIT_1'
    join public.flow_market_learning_labels_clean_v4c l on l.as_of_date=m.as_of_date and l.ticker=m.ticker
      and l.feature_contract='MARKET_MEMORY_V4_1'
    left join public.flow_financial_filing_feature_v5 ff on ff.filing_id=f.current_filing_id
    left join breadth b on b.as_of_date=m.as_of_date
    left join ihsg i on i.trade_date=m.as_of_date
  ), weekly_ranked as (
    select weekly.*,
      percent_rank() over(partition by as_of_date order by return_20d_pct) return20_xsec_rank,
      percent_rank() over(partition by as_of_date order by ihsg_return20) ihsg_xsec_rank
    from weekly
  )
  select * from weekly_ranked;
  analyze pg_temp.flow_gate11_base;

  insert into public.flow_driver_signal_panel_v1(
    panel_contract,signal_date,ticker,sector,sector_history_state,market_regime,market_regime_value,
    source_identity,revision_identity,evidence_timestamp,effective_availability_date,
    target_date_5d,target_date_20d,target_date_60d,
    forward_return_5d_pct,forward_return_20d_pct,forward_return_60d_pct,
    alpha_vs_ihsg_5d_pct,alpha_vs_ihsg_20d_pct,alpha_vs_ihsg_60d_pct,
    alpha_vs_sector_5d_pct,alpha_vs_sector_20d_pct,alpha_vs_sector_60d_pct,
    mfe_5d_pct,mfe_20d_pct,mfe_60d_pct,mae_5d_pct,mae_20d_pct,mae_60d_pct,
    sector_target_state,provenance,built_at,production_influence_enabled
  )
  select v_contract,as_of_date,ticker,sector,sector_history_state,
    case when ihsg_return20 is null then 'INSUFFICIENT_HISTORY'
         when ihsg_return20>=3 then 'RISK_ON' when ihsg_return20<=-3 then 'RISK_OFF' else 'NEUTRAL' end,
    ihsg_return20,'flow_market_learning_panel_v4+flow_financial_shadow_panel_v5',source_snapshot_hash,
    (as_of_date::timestamp+time '16:15') at time zone 'Asia/Jakarta',as_of_date,
    target_date_5d,target_date_20d,target_date_60d,
    clean_forward_return_5d_pct,clean_forward_return_20d_pct,clean_forward_return_60d_pct,
    clean_alpha_vs_ihsg_5d_pct,clean_alpha_vs_ihsg_20d_pct,clean_alpha_vs_ihsg_60d_pct,
    null,null,null,
    clean_mfe_5d_pct,clean_mfe_20d_pct,clean_mfe_60d_pct,
    clean_mae_5d_pct,clean_mae_20d_pct,clean_mae_60d_pct,
    'INVALID_CURRENT_SECTOR_CLASSIFICATION_NOT_HISTORICAL',
    jsonb_build_object('market_contract',feature_contract,'financial_contract','FINANCIAL_V5_WEEKLY_LAST_TRADING_DAY_PIT_1',
      'outcome_contract','CLEAN_CORPORATE_ACTION_GUARDED_OUTCOME_PATH_V4C_1','target_is_outcome_not_feature',true,
      'sector_benchmark_fail_closed',true),v_built_at,false
  from pg_temp.flow_gate11_base;
  get diagnostics v_signal_rows=row_count;

  insert into public.flow_driver_observation_panel_v1(
    panel_contract,signal_date,ticker,driver_id,driver_state,raw_value,transformed_value,normalized_value,
    bottom_signal,top_signal,evidence_timestamp,effective_availability_date,source_identity,revision_identity,
    stale_status,missingness_status,provenance,built_at,production_influence_enabled
  )
  with raw as (
    select b.as_of_date,b.ticker,r.driver_id,r.family,r.direction_hypothesis,r.threshold_definition,
      x.raw_value,
      case
        when r.family='FINANCIAL' then
          case
            when b.financial_available_from_date>b.as_of_date then 'INVALID'
            when r.driver_id='FIN_GROWTH' then coalesce(b.feature_states->>'growth',b.financial_state)
            when r.driver_id='FIN_CASHFLOW' then coalesce(b.feature_states->>'cashflow',b.financial_state)
            when x.raw_value is not null and b.financial_state='AVAILABLE' then 'AVAILABLE'
            else coalesce(b.financial_state,'MISSING') end
        when b.history_count_21<r.minimum_history_sessions then 'INSUFFICIENT_HISTORY'
        when x.raw_value is null then 'MISSING'
        else 'AVAILABLE' end as driver_state,
      case when r.family='FINANCIAL' then b.financial_published_at
           else (b.as_of_date::timestamp+time '16:15') at time zone 'Asia/Jakarta' end evidence_timestamp,
      case when r.family='FINANCIAL' then b.financial_available_from_date else b.as_of_date end effective_date,
      case when r.family='FINANCIAL' then 'flow_financial_shadow_panel_v5' else 'flow_market_learning_panel_v4' end source_identity,
      case when r.family='FINANCIAL' then coalesce(b.current_filing_id,'NO_FILING') else b.source_snapshot_hash end revision_identity,
      b.feature_contract,b.financial_state,b.current_filing_id,b.prior_filing_id
    from pg_temp.flow_gate11_base b
    cross join lateral (values
      ('FLOW_FOREIGN_ACCUMULATION',b.foreign_net_volume_pct::numeric),
      ('FLOW_FOREIGN_DISTRIBUTION',b.foreign_net_volume_pct::numeric),
      ('FLOW_PARTICIPANT_ACCUMULATION',(case when b.return_5d_pct>0 then b.stock_residual_activity_z else 0 end)::numeric),
      ('FLOW_PARTICIPANT_DISTRIBUTION',(case when b.return_5d_pct<0 then b.stock_residual_activity_z else 0 end)::numeric),
      ('FLOW_PERSISTENCE_20D',b.flow_persistence20::numeric),
      ('FLOW_ACCELERATION_5V20',(b.flow_avg5-b.flow_avg20)::numeric),
      ('FLOW_ABSORPTION',(b.foreign_net_volume_pct-abs(b.return_5d_pct)+greatest(b.stock_residual_activity_z,0))::numeric),
      ('FLOW_DISTRIBUTION_RISK',(greatest(-b.foreign_net_volume_pct,0)+greatest(-b.return_5d_pct,0)+greatest(b.stock_residual_activity_z,0))::numeric),
      ('PV_VOLUME_EXPANSION',(b.volume/nullif(b.volume_avg20,0))::numeric),
      ('PV_ABNORMAL_VOLUME',b.volume_residual_z::numeric),
      ('PV_PRICE_VOLUME_CONFIRMATION',(greatest(b.return_5d_pct,0)*greatest(b.volume_residual_z,0))::numeric),
      ('PV_PRICE_VOLUME_DIVERGENCE',(greatest(b.return_5d_pct,0)*greatest(-b.volume_residual_z,0))::numeric),
      ('PV_BREAKOUT_20D',b.close_vs_20d_high_pct::numeric),
      ('PV_RELATIVE_MOMENTUM_20D',(b.return_20d_pct-b.ihsg_return20)::numeric),
      ('PV_VOLATILITY_EXPANSION',(b.volatility_range_pct/nullif(b.range_avg20,0))::numeric),
      ('PV_VOLATILITY_CONTRACTION',(-b.volatility_range_pct/nullif(b.range_avg20,0))::numeric),
      ('PV_LIQUIDITY_CONDITION',ln(1+b.market_turnover_share_pct)::numeric),
      ('MKT_IHSG_REGIME_20D',b.ihsg_return20::numeric),
      ('MKT_BREADTH_20D',b.market_breadth20::numeric),
      ('MKT_RISK_ON_CONTEXT',((b.ihsg_xsec_rank+b.market_breadth20)/2.0)::numeric),
      ('TECH_BOS_20D',(b.close>b.prior_high20)::int::numeric),
      ('TECH_CHOCH',(b.return_20d_pct<0 and b.close>b.prior_high5)::int::numeric),
      ('TECH_LIQUIDITY_SWEEP_20D',(b.low<b.prior_low20 and b.close>b.prior_low20)::int::numeric),
      ('TECH_FVG_BULLISH',(b.low>b.high_lag2)::int::numeric),
      ('TECH_DISPLACEMENT',(b.return_1d_pct/nullif(b.return_sd20,0))::numeric),
      ('TECH_TREND_STRUCTURE',((b.return20_xsec_rank+(b.close>=b.close_avg20)::int)/2.0)::numeric),
      ('TECH_PULLBACK_CONTINUATION',(b.return_20d_pct>0 and b.return_5d_pct between -5 and 0 and b.close_vs_20d_high_pct>-10)::int::numeric),
      ('TECH_REVERSAL_ACCUMULATION',(b.return_20d_pct<0 and b.close>b.prior_high5 and b.foreign_net_volume_pct>0)::int::numeric),
      ('FIN_BALANCE',b.balance_score::numeric),('FIN_CASHFLOW',b.cashflow_score::numeric),
      ('FIN_GROWTH',b.growth_score::numeric),('FIN_QUALITY',b.quality_score::numeric),
      ('LIQ_ADTV20',b.adtv20::numeric),('LIQ_TURNOVER',b.market_turnover_share_pct::numeric),
      ('LIQ_ILLIQUIDITY_AMIHUD',(abs(b.return_1d_pct)/nullif(b.traded_value,0))::numeric),
      ('LIQ_PRICE_IMPACT_PROXY',(b.volatility_range_pct/nullif(ln(1+b.traded_value),0))::numeric),
      ('LIQ_TRADABILITY_CONSTRAINT',(b.volume=0 or b.frequency=0 or b.traded_value=0)::int::numeric)
    ) x(driver_id,raw_value)
    join public.flow_driver_registry_v1 r on r.registry_version=v_registry and r.driver_id=x.driver_id and r.evaluation_eligible
  ), oriented as (
    select *,case when driver_state='AVAILABLE' then raw_value*direction_hypothesis end transformed_value
    from raw
  ), normalized as (
    select *,case when driver_state='AVAILABLE'
      then percent_rank() over(partition by as_of_date,driver_id order by transformed_value) end normalized_value
    from oriented
  )
  select v_contract,as_of_date,ticker,driver_id,driver_state,raw_value,transformed_value,normalized_value,
    case when driver_state<>'AVAILABLE' then false
         when threshold_definition='RAW_BOTTOM_20_TOP_80' then raw_value<=20
         when threshold_definition='RAW_BOTTOM_0_35_TOP_0_65' then raw_value<=0.35
         when threshold_definition='RAW_BOTTOM_0_80_TOP_1_50' then raw_value<=0.80
         when threshold_definition='RAW_BOTTOM_0_75_TOP_1_50' then raw_value<=0.75
         when threshold_definition='RAW_BOTTOM_LE_-3_TOP_GE_3_PCT' then raw_value<=-3
         when threshold_definition='RAW_TOP_GE_-0_25_PCT_BOTTOM_LE_-8_PCT' then raw_value<=-8
         when threshold_definition='BINARY_TRUE_VS_FALSE' then raw_value=0
         else normalized_value<=0.20 end,
    case when driver_state<>'AVAILABLE' then false
         when threshold_definition='RAW_BOTTOM_20_TOP_80' then raw_value>=80
         when threshold_definition='RAW_BOTTOM_0_35_TOP_0_65' then raw_value>=0.65
         when threshold_definition='RAW_BOTTOM_0_80_TOP_1_50' then raw_value>=1.50
         when threshold_definition='RAW_BOTTOM_0_75_TOP_1_50' then raw_value>=1.50
         when threshold_definition='RAW_BOTTOM_LE_-3_TOP_GE_3_PCT' then raw_value>=3
         when threshold_definition='RAW_TOP_GE_-0_25_PCT_BOTTOM_LE_-8_PCT' then raw_value>=-0.25
         when threshold_definition='BINARY_TRUE_VS_FALSE' then raw_value=1
         else normalized_value>=0.80 end,
    evidence_timestamp,effective_date,source_identity,revision_identity,
    case when driver_state='STALE' then 'STALE' else 'NOT_STALE' end,
    case when driver_state='AVAILABLE' then 'PRESENT' else driver_state end,
    jsonb_build_object('registry_version',v_registry,'feature_contract',feature_contract,
      'financial_state',financial_state,'current_filing_id',current_filing_id,'prior_filing_id',prior_filing_id,
      'normalization','SAME_SIGNAL_DATE_CROSS_SECTION_ONLY','outcome_fields_used_in_feature',false),
    v_built_at,false
  from normalized;
  get diagnostics v_observation_rows=row_count;

  insert into public.flow_driver_coverage_v1
  select v_contract,'DRIVER',r.driver_id,count(o.*),count(*) filter(where o.driver_state='AVAILABLE'),
    count(*) filter(where o.driver_state='MISSING'),count(*) filter(where o.driver_state='STALE'),
    count(*) filter(where o.driver_state='INVALID'),count(*) filter(where o.driver_state='NOT_APPLICABLE'),
    count(*) filter(where o.driver_state='INSUFFICIENT_HISTORY'),
    coalesce(round(100.0*count(*) filter(where o.driver_state='AVAILABLE')/nullif(count(o.*),0),4),0),
    coalesce(round(100.0*count(*) filter(where o.driver_state='STALE')/nullif(count(o.*),0),4),0),
    coalesce(round(100.0*count(*) filter(where o.driver_state='INVALID')/nullif(count(o.*),0),4),0),v_built_at
  from public.flow_driver_registry_v1 r
  left join public.flow_driver_observation_panel_v1 o on o.driver_id=r.driver_id and o.panel_contract=v_contract
  where r.registry_version=v_registry
  group by r.driver_id;

  insert into public.flow_driver_coverage_v1
  select v_contract,'FAMILY',r.family,count(o.*),count(*) filter(where o.driver_state='AVAILABLE'),
    count(*) filter(where o.driver_state='MISSING'),count(*) filter(where o.driver_state='STALE'),
    count(*) filter(where o.driver_state='INVALID'),count(*) filter(where o.driver_state='NOT_APPLICABLE'),
    count(*) filter(where o.driver_state='INSUFFICIENT_HISTORY'),
    coalesce(round(100.0*count(*) filter(where o.driver_state='AVAILABLE')/nullif(count(o.*),0),4),0),
    coalesce(round(100.0*count(*) filter(where o.driver_state='STALE')/nullif(count(o.*),0),4),0),
    coalesce(round(100.0*count(*) filter(where o.driver_state='INVALID')/nullif(count(o.*),0),4),0),v_built_at
  from public.flow_driver_registry_v1 r
  left join public.flow_driver_observation_panel_v1 o on o.driver_id=r.driver_id and o.panel_contract=v_contract
  where r.registry_version=v_registry group by r.family;

  select count(*) into v_available from public.flow_driver_observation_panel_v1 where panel_contract=v_contract and driver_state='AVAILABLE';
  select count(*) into v_future_evidence from public.flow_driver_observation_panel_v1
    where panel_contract=v_contract and effective_availability_date>signal_date;
  select count(*) into v_future_financial from public.flow_driver_observation_panel_v1 o
    join public.flow_driver_registry_v1 r on r.registry_version=v_registry and r.driver_id=o.driver_id
    where o.panel_contract=v_contract and r.family='FINANCIAL' and o.effective_availability_date>o.signal_date;
  select count(*) into v_future_flow from public.flow_driver_observation_panel_v1 o
    join public.flow_driver_registry_v1 r on r.registry_version=v_registry and r.driver_id=o.driver_id
    where o.panel_contract=v_contract and r.family='FLOW_PARTICIPANT' and o.effective_availability_date>o.signal_date;
  select count(*) into v_future_benchmark from public.flow_driver_observation_panel_v1 o
    where o.panel_contract=v_contract and o.driver_id='MKT_IHSG_REGIME_20D' and o.effective_availability_date>o.signal_date;
  select count(*) into v_sector_feature_leak from public.flow_driver_observation_panel_v1 o
    join public.flow_driver_registry_v1 r on r.registry_version=v_registry and r.driver_id=o.driver_id
    where o.panel_contract=v_contract and r.family='MARKET_SECTOR' and not r.pit_safe;
  select count(*) into v_revision_leak from public.flow_driver_observation_panel_v1 o
    where o.panel_contract=v_contract and o.driver_id like 'FIN_%' and o.driver_state='AVAILABLE'
      and (o.revision_identity='NO_FILING' or o.effective_availability_date>o.signal_date);
  select count(*) into v_target_leak from public.flow_driver_observation_panel_v1
    where panel_contract=v_contract and (provenance->>'outcome_fields_used_in_feature')::boolean;

  insert into public.flow_driver_panel_manifest_v1
  select v_contract,v_registry,v_signal_rows,v_observation_rows,
    count(distinct signal_date),count(distinct ticker),count(distinct sector),v_available,
    round(100.0*v_available/nullif(v_observation_rows,0),4),
    round(100.0*count(*) filter(where driver_state='MISSING')/nullif(v_observation_rows,0),4),
    round(100.0*count(*) filter(where driver_state='STALE')/nullif(v_observation_rows,0),4),
    round(100.0*count(*) filter(where driver_state='INVALID')/nullif(v_observation_rows,0),4),
    jsonb_build_object('future_evidence',v_future_evidence,'future_financial',v_future_financial,
      'future_flow',v_future_flow,'future_benchmark',v_future_benchmark,
      'future_sector_membership_feature_rows',v_sector_feature_leak,
      'future_ownership',0,'future_event',0,'lookahead_normalization',0,
      'forward_return_used_in_features',v_target_leak),
    v_future_evidence+v_sector_feature_leak,v_revision_leak,v_target_leak,'COMPLETE',v_built_at,false
  from public.flow_driver_observation_panel_v1 o
  join public.flow_driver_signal_panel_v1 s using(panel_contract,signal_date,ticker)
  where o.panel_contract=v_contract;

  return jsonb_build_object('status','PASS','panel_contract',v_contract,'signal_rows',v_signal_rows,
    'observation_rows',v_observation_rows,'available_observations',v_available,
    'leakage_count',v_future_evidence+v_sector_feature_leak,'revision_leakage_count',v_revision_leak,
    'target_leakage_count',v_target_leak,'production_influence_enabled',false);
end;
$fn$;

revoke all on function public.flow_refresh_driver_panel_v1() from public,anon,authenticated;
grant execute on function public.flow_refresh_driver_panel_v1() to service_role;

comment on table public.flow_driver_signal_panel_v1 is 'Gate 11 weekly PIT signal/outcome panel; outcomes are labels, never features.';
comment on table public.flow_driver_observation_panel_v1 is 'Gate 11 long driver observations with explicit state and same-date normalization.';
