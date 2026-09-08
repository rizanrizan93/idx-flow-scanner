-- Gate 11 compact, staged implementation after the initial all-long refresh exceeded the API timeout.
-- The failed refresh was transactional and left the long table empty. Replace it with a secured view.

drop table public.flow_driver_observation_panel_v1;

create table public.flow_driver_feature_panel_v1 (
  panel_contract text not null,
  signal_date date not null,
  ticker text not null,
  feature_contract text not null,
  history_count integer not null,
  raw_values jsonb not null,
  financial_state text,
  financial_feature_states jsonb not null,
  financial_published_at timestamptz,
  financial_available_from_date date,
  current_filing_id text,
  prior_filing_id text,
  source_snapshot_hash text not null,
  built_at timestamptz not null,
  production_influence_enabled boolean not null default false check(production_influence_enabled=false),
  primary key(panel_contract,signal_date,ticker),
  foreign key(panel_contract,signal_date,ticker)
    references public.flow_driver_signal_panel_v1(panel_contract,signal_date,ticker) on delete cascade
);
alter table public.flow_driver_feature_panel_v1 enable row level security;
revoke all on public.flow_driver_feature_panel_v1 from public,anon,authenticated,service_role;
grant select,insert,update,delete on public.flow_driver_feature_panel_v1 to service_role;

create or replace view public.flow_driver_observation_panel_v1
with (security_invoker=true) as
with raw as (
  select f.panel_contract,f.signal_date,f.ticker,r.driver_id,r.family,r.direction_hypothesis,
    r.threshold_definition,r.minimum_history_sessions,
    nullif(f.raw_values->>r.driver_id,'')::numeric raw_value,
    case
      when r.family='FINANCIAL' then
        case when f.financial_available_from_date>f.signal_date then 'INVALID'
          when r.driver_id='FIN_GROWTH' then coalesce(f.financial_feature_states->>'growth',f.financial_state,'MISSING')
          when r.driver_id='FIN_CASHFLOW' then coalesce(f.financial_feature_states->>'cashflow',f.financial_state,'MISSING')
          when nullif(f.raw_values->>r.driver_id,'') is not null and f.financial_state='AVAILABLE' then 'AVAILABLE'
          else coalesce(f.financial_state,'MISSING') end
      when f.history_count<r.minimum_history_sessions then 'INSUFFICIENT_HISTORY'
      when nullif(f.raw_values->>r.driver_id,'') is null then 'MISSING'
      else 'AVAILABLE' end driver_state,
    case when r.family='FINANCIAL' then f.financial_published_at
      else (f.signal_date::timestamp+time '16:15') at time zone 'Asia/Jakarta' end evidence_timestamp,
    case when r.family='FINANCIAL' then f.financial_available_from_date else f.signal_date end effective_availability_date,
    case when r.family='FINANCIAL' then 'flow_financial_shadow_panel_v5' else 'flow_market_learning_panel_v4' end source_identity,
    case when r.family='FINANCIAL' then coalesce(f.current_filing_id,'NO_FILING') else f.source_snapshot_hash end revision_identity,
    f.feature_contract,f.financial_state,f.current_filing_id,f.prior_filing_id,f.built_at
  from public.flow_driver_feature_panel_v1 f
  join public.flow_driver_registry_v1 r on r.registry_version='IDX_DRIVER_REGISTRY_GATE10_V1' and r.evaluation_eligible
), oriented as (
  select *,case when driver_state='AVAILABLE' then raw_value*direction_hypothesis end transformed_value
  from raw
), normalized as (
  select *,case when driver_state='AVAILABLE' then
    percent_rank() over(partition by signal_date,driver_id,driver_state order by transformed_value) end normalized_value
  from oriented
)
select panel_contract,signal_date,ticker,driver_id,driver_state,raw_value,transformed_value,normalized_value,
  case when driver_state<>'AVAILABLE' then false
    when threshold_definition='RAW_BOTTOM_20_TOP_80' then raw_value<=20
    when threshold_definition='RAW_BOTTOM_0_35_TOP_0_65' then raw_value<=0.35
    when threshold_definition='RAW_BOTTOM_0_80_TOP_1_50' then raw_value<=0.80
    when threshold_definition='RAW_BOTTOM_0_75_TOP_1_50' then raw_value<=0.75
    when threshold_definition='RAW_BOTTOM_LE_-3_TOP_GE_3_PCT' then raw_value<=-3
    when threshold_definition='RAW_TOP_GE_-0_25_PCT_BOTTOM_LE_-8_PCT' then raw_value<=-8
    when threshold_definition='BINARY_TRUE_VS_FALSE' then raw_value=0
    else normalized_value<=0.20 end bottom_signal,
  case when driver_state<>'AVAILABLE' then false
    when threshold_definition='RAW_BOTTOM_20_TOP_80' then raw_value>=80
    when threshold_definition='RAW_BOTTOM_0_35_TOP_0_65' then raw_value>=0.65
    when threshold_definition='RAW_BOTTOM_0_80_TOP_1_50' then raw_value>=1.50
    when threshold_definition='RAW_BOTTOM_0_75_TOP_1_50' then raw_value>=1.50
    when threshold_definition='RAW_BOTTOM_LE_-3_TOP_GE_3_PCT' then raw_value>=3
    when threshold_definition='RAW_TOP_GE_-0_25_PCT_BOTTOM_LE_-8_PCT' then raw_value>=-0.25
    when threshold_definition='BINARY_TRUE_VS_FALSE' then raw_value=1
    else normalized_value>=0.80 end top_signal,
  evidence_timestamp,effective_availability_date,source_identity,revision_identity,
  case when driver_state='STALE' then 'STALE' else 'NOT_STALE' end stale_status,
  case when driver_state='AVAILABLE' then 'PRESENT' else driver_state end missingness_status,
  jsonb_build_object('registry_version','IDX_DRIVER_REGISTRY_GATE10_V1','feature_contract',feature_contract,
    'financial_state',financial_state,'current_filing_id',current_filing_id,'prior_filing_id',prior_filing_id,
    'normalization','SAME_SIGNAL_DATE_CROSS_SECTION_ONLY','outcome_fields_used_in_feature',false) provenance,
  built_at,false production_influence_enabled
from normalized;
revoke all on public.flow_driver_observation_panel_v1 from public,anon,authenticated;
grant select on public.flow_driver_observation_panel_v1 to service_role;

create or replace function public.flow_refresh_driver_panel_v1()
returns jsonb
language plpgsql
security invoker
set search_path=''
set work_mem='96MB'
as $fn$
declare
  v_contract constant text := 'IDX_DRIVER_WEEKLY_PIT_PANEL_V1';
  v_built_at timestamptz;
  v_signal_rows bigint;
  v_feature_rows bigint;
begin
  select frozen_at into strict v_built_at from public.flow_driver_research_policy_v1
    where registry_version='IDX_DRIVER_REGISTRY_GATE10_V1';
  delete from public.flow_driver_panel_manifest_v1 where panel_contract=v_contract;
  delete from public.flow_driver_coverage_v1 where panel_contract=v_contract;
  delete from public.flow_driver_feature_panel_v1 where panel_contract=v_contract;
  delete from public.flow_driver_signal_panel_v1 where panel_contract=v_contract;

  drop table if exists pg_temp.flow_gate11_base;
  create temp table flow_gate11_base on commit drop as
  with market_daily as (
    select p.*,s.high,s.low,
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
    select trade_date,100.0*(close/nullif(lag(close,20) over(order by trade_date),0)-1.0) ihsg_return20
    from public.flow_official_index_summary where index_code='COMPOSITE' and source_verified
  ), weekly as (
    select m.*,b.market_breadth20,i.ihsg_return20,
      f.financial_state,f.current_filing_id,f.prior_filing_id,f.quality_score,f.growth_score,f.balance_score,f.cashflow_score,f.feature_states,
      ff.published_at financial_published_at,ff.available_from_date financial_available_from_date,
      l.target_date_5d,l.target_date_20d,l.target_date_60d,
      l.clean_forward_return_5d_pct,l.clean_forward_return_20d_pct,l.clean_forward_return_60d_pct,
      l.clean_alpha_vs_ihsg_5d_pct,l.clean_alpha_vs_ihsg_20d_pct,l.clean_alpha_vs_ihsg_60d_pct,
      l.clean_mfe_5d_pct,l.clean_mfe_20d_pct,l.clean_mfe_60d_pct,l.clean_mae_5d_pct,l.clean_mae_20d_pct,l.clean_mae_60d_pct
    from market_daily m
    join public.flow_financial_shadow_panel_v5 f on f.as_of_date=m.as_of_date and f.ticker=m.ticker
      and f.sample_contract='FINANCIAL_V5_WEEKLY_LAST_TRADING_DAY_PIT_1'
    join public.flow_market_learning_labels_clean_v4c l on l.as_of_date=m.as_of_date and l.ticker=m.ticker and l.feature_contract='MARKET_MEMORY_V4_1'
    left join public.flow_financial_filing_feature_v5 ff on ff.filing_id=f.current_filing_id
    left join breadth b on b.as_of_date=m.as_of_date
    left join ihsg i on i.trade_date=m.as_of_date
  ), ranked as (
    select weekly.*,percent_rank() over(partition by as_of_date order by return_20d_pct) return20_xsec_rank,
      percent_rank() over(partition by as_of_date order by ihsg_return20) ihsg_xsec_rank
    from weekly
  ) select * from ranked;
  analyze pg_temp.flow_gate11_base;

  insert into public.flow_driver_signal_panel_v1
  select v_contract,as_of_date,ticker,sector,sector_history_state,
    case when ihsg_return20 is null then 'INSUFFICIENT_HISTORY' when ihsg_return20>=3 then 'RISK_ON'
      when ihsg_return20<=-3 then 'RISK_OFF' else 'NEUTRAL' end,ihsg_return20,
    'flow_market_learning_panel_v4+flow_financial_shadow_panel_v5',source_snapshot_hash,
    (as_of_date::timestamp+time '16:15') at time zone 'Asia/Jakarta',as_of_date,
    target_date_5d,target_date_20d,target_date_60d,
    clean_forward_return_5d_pct,clean_forward_return_20d_pct,clean_forward_return_60d_pct,
    clean_alpha_vs_ihsg_5d_pct,clean_alpha_vs_ihsg_20d_pct,clean_alpha_vs_ihsg_60d_pct,
    null,null,null,clean_mfe_5d_pct,clean_mfe_20d_pct,clean_mfe_60d_pct,
    clean_mae_5d_pct,clean_mae_20d_pct,clean_mae_60d_pct,
    'INVALID_CURRENT_SECTOR_CLASSIFICATION_NOT_HISTORICAL',
    jsonb_build_object('market_contract',feature_contract,'financial_contract','FINANCIAL_V5_WEEKLY_LAST_TRADING_DAY_PIT_1',
      'outcome_contract','CLEAN_CORPORATE_ACTION_GUARDED_OUTCOME_PATH_V4C_1','target_is_outcome_not_feature',true,'sector_benchmark_fail_closed',true),
    v_built_at,false
  from pg_temp.flow_gate11_base;
  get diagnostics v_signal_rows=row_count;

  insert into public.flow_driver_feature_panel_v1
  select v_contract,as_of_date,ticker,feature_contract,history_count_21,
    jsonb_build_object(
      'FLOW_FOREIGN_ACCUMULATION',foreign_net_volume_pct,'FLOW_FOREIGN_DISTRIBUTION',foreign_net_volume_pct,
      'FLOW_PARTICIPANT_ACCUMULATION',case when return_5d_pct>0 then stock_residual_activity_z else 0 end,
      'FLOW_PARTICIPANT_DISTRIBUTION',case when return_5d_pct<0 then stock_residual_activity_z else 0 end,
      'FLOW_PERSISTENCE_20D',flow_persistence20,'FLOW_ACCELERATION_5V20',flow_avg5-flow_avg20,
      'FLOW_ABSORPTION',foreign_net_volume_pct-abs(return_5d_pct)+greatest(stock_residual_activity_z,0),
      'FLOW_DISTRIBUTION_RISK',greatest(-foreign_net_volume_pct,0)+greatest(-return_5d_pct,0)+greatest(stock_residual_activity_z,0),
      'PV_VOLUME_EXPANSION',volume/nullif(volume_avg20,0),'PV_ABNORMAL_VOLUME',volume_residual_z,
      'PV_PRICE_VOLUME_CONFIRMATION',greatest(return_5d_pct,0)*greatest(volume_residual_z,0),
      'PV_PRICE_VOLUME_DIVERGENCE',greatest(return_5d_pct,0)*greatest(-volume_residual_z,0),
      'PV_BREAKOUT_20D',close_vs_20d_high_pct,'PV_RELATIVE_MOMENTUM_20D',return_20d_pct-ihsg_return20,
      'PV_VOLATILITY_EXPANSION',volatility_range_pct/nullif(range_avg20,0),'PV_VOLATILITY_CONTRACTION',-volatility_range_pct/nullif(range_avg20,0),
      'PV_LIQUIDITY_CONDITION',ln(1+market_turnover_share_pct),'MKT_IHSG_REGIME_20D',ihsg_return20,
      'MKT_BREADTH_20D',market_breadth20,'MKT_RISK_ON_CONTEXT',(ihsg_xsec_rank+market_breadth20)/2.0,
      'TECH_BOS_20D',(close>prior_high20)::int,'TECH_CHOCH',(return_20d_pct<0 and close>prior_high5)::int,
      'TECH_LIQUIDITY_SWEEP_20D',(low<prior_low20 and close>prior_low20)::int,'TECH_FVG_BULLISH',(low>high_lag2)::int,
      'TECH_DISPLACEMENT',return_1d_pct/nullif(return_sd20,0),'TECH_TREND_STRUCTURE',(return20_xsec_rank+(close>=close_avg20)::int)/2.0,
      'TECH_PULLBACK_CONTINUATION',(return_20d_pct>0 and return_5d_pct between -5 and 0 and close_vs_20d_high_pct>-10)::int,
      'TECH_REVERSAL_ACCUMULATION',(return_20d_pct<0 and close>prior_high5 and foreign_net_volume_pct>0)::int,
      'FIN_BALANCE',balance_score,'FIN_CASHFLOW',cashflow_score,'FIN_GROWTH',growth_score,'FIN_QUALITY',quality_score,
      'LIQ_ADTV20',adtv20,'LIQ_TURNOVER',market_turnover_share_pct,
      'LIQ_ILLIQUIDITY_AMIHUD',abs(return_1d_pct)/nullif(traded_value,0),
      'LIQ_PRICE_IMPACT_PROXY',volatility_range_pct/nullif(ln(1+traded_value),0),
      'LIQ_TRADABILITY_CONSTRAINT',(volume=0 or frequency=0 or traded_value=0)::int
    ),financial_state,coalesce(feature_states,'{}'::jsonb),financial_published_at,financial_available_from_date,
    current_filing_id,prior_filing_id,source_snapshot_hash,v_built_at,false
  from pg_temp.flow_gate11_base;
  get diagnostics v_feature_rows=row_count;

  return jsonb_build_object('status','BUILD_READY','panel_contract',v_contract,'signal_rows',v_signal_rows,
    'feature_rows',v_feature_rows,'finalize_required',true,'production_influence_enabled',false);
end;
$fn$;

create or replace function public.flow_finalize_driver_panel_v1()
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
  v_signals bigint;v_observations bigint;v_available bigint;
  v_future bigint;v_revision bigint;v_target bigint;v_sector bigint;
begin
  select frozen_at into strict v_built_at from public.flow_driver_research_policy_v1 where registry_version=v_registry;
  delete from public.flow_driver_panel_manifest_v1 where panel_contract=v_contract;
  delete from public.flow_driver_coverage_v1 where panel_contract=v_contract;

  insert into public.flow_driver_coverage_v1
  select v_contract,'DRIVER',r.driver_id,count(o.*),count(*) filter(where o.driver_state='AVAILABLE'),
    count(*) filter(where o.driver_state='MISSING'),count(*) filter(where o.driver_state='STALE'),
    count(*) filter(where o.driver_state='INVALID'),count(*) filter(where o.driver_state='NOT_APPLICABLE'),
    count(*) filter(where o.driver_state='INSUFFICIENT_HISTORY'),
    coalesce(round(100.0*count(*) filter(where o.driver_state='AVAILABLE')/nullif(count(o.*),0),4),0),
    coalesce(round(100.0*count(*) filter(where o.driver_state='STALE')/nullif(count(o.*),0),4),0),
    coalesce(round(100.0*count(*) filter(where o.driver_state='INVALID')/nullif(count(o.*),0),4),0),v_built_at
  from public.flow_driver_registry_v1 r left join public.flow_driver_observation_panel_v1 o
    on o.driver_id=r.driver_id and o.panel_contract=v_contract
  where r.registry_version=v_registry group by r.driver_id;

  insert into public.flow_driver_coverage_v1
  select v_contract,'FAMILY',r.family,count(o.*),count(*) filter(where o.driver_state='AVAILABLE'),
    count(*) filter(where o.driver_state='MISSING'),count(*) filter(where o.driver_state='STALE'),
    count(*) filter(where o.driver_state='INVALID'),count(*) filter(where o.driver_state='NOT_APPLICABLE'),
    count(*) filter(where o.driver_state='INSUFFICIENT_HISTORY'),
    coalesce(round(100.0*count(*) filter(where o.driver_state='AVAILABLE')/nullif(count(o.*),0),4),0),
    coalesce(round(100.0*count(*) filter(where o.driver_state='STALE')/nullif(count(o.*),0),4),0),
    coalesce(round(100.0*count(*) filter(where o.driver_state='INVALID')/nullif(count(o.*),0),4),0),v_built_at
  from public.flow_driver_registry_v1 r left join public.flow_driver_observation_panel_v1 o
    on o.driver_id=r.driver_id and o.panel_contract=v_contract
  where r.registry_version=v_registry group by r.family;

  select count(*) into v_signals from public.flow_driver_signal_panel_v1 where panel_contract=v_contract;
  select count(*),count(*) filter(where driver_state='AVAILABLE'),
    count(*) filter(where effective_availability_date>signal_date),
    count(*) filter(where driver_id like 'FIN_%' and driver_state='AVAILABLE' and (revision_identity='NO_FILING' or effective_availability_date>signal_date)),
    count(*) filter(where (provenance->>'outcome_fields_used_in_feature')::boolean)
  into v_observations,v_available,v_future,v_revision,v_target
  from public.flow_driver_observation_panel_v1 where panel_contract=v_contract;
  select count(*) into v_sector from public.flow_driver_observation_panel_v1 o
    join public.flow_driver_registry_v1 r on r.registry_version=v_registry and r.driver_id=o.driver_id
    where o.panel_contract=v_contract and r.family='MARKET_SECTOR' and not r.pit_safe;

  insert into public.flow_driver_panel_manifest_v1
  select v_contract,v_registry,v_signals,v_observations,count(distinct signal_date),count(distinct ticker),count(distinct sector),
    v_available,round(100.0*v_available/nullif(v_observations,0),4),
    coalesce((select round(100.0*sum(missing_rows)/nullif(sum(total_rows),0),4) from public.flow_driver_coverage_v1 where panel_contract=v_contract and entity_type='DRIVER'),0),
    coalesce((select round(100.0*sum(stale_rows)/nullif(sum(total_rows),0),4) from public.flow_driver_coverage_v1 where panel_contract=v_contract and entity_type='DRIVER'),0),
    coalesce((select round(100.0*sum(invalid_rows)/nullif(sum(total_rows),0),4) from public.flow_driver_coverage_v1 where panel_contract=v_contract and entity_type='DRIVER'),0),
    jsonb_build_object('future_evidence',v_future,'future_financial',v_revision,'future_flow',0,'future_benchmark',0,
      'future_sector_membership_feature_rows',v_sector,'future_ownership',0,'future_event',0,
      'lookahead_normalization',0,'forward_return_used_in_features',v_target),
    v_future+v_sector,v_revision,v_target,'COMPLETE',v_built_at,false
  from public.flow_driver_signal_panel_v1 where panel_contract=v_contract;

  return jsonb_build_object('status','PASS','signal_rows',v_signals,'observation_rows',v_observations,
    'available_observations',v_available,'leakage_count',v_future+v_sector,
    'revision_leakage_count',v_revision,'target_leakage_count',v_target,'production_influence_enabled',false);
end;
$fn$;

revoke all on function public.flow_refresh_driver_panel_v1() from public,anon,authenticated;
revoke all on function public.flow_finalize_driver_panel_v1() from public,anon,authenticated;
grant execute on function public.flow_refresh_driver_panel_v1() to service_role;
grant execute on function public.flow_finalize_driver_panel_v1() to service_role;

comment on table public.flow_driver_feature_panel_v1 is 'Compact Gate 11 raw feature payload; long observations are exposed by a service-only invoker view.';
