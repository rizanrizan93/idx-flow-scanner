-- Phase 4C performance remediation after canonical runtime timeout.
-- The original all-feature temp reconstruction forced every expensive as-of evidence
-- branch at once. This family-pruned path keeps the same MARKET_MEMORY_V4_1 and clean
-- label contracts, but only evaluates panel columns required by the requested family.
-- It does not persist or duplicate the 251k-row market panel.

create or replace function public.flow_prepare_phase4c_temp_family_v4(p_factor_family text)
returns integer
language plpgsql
security invoker
set search_path=pg_catalog,public
as $$
declare
  v_features text;
  v_sql text;
  v_rows integer;
begin
  if p_factor_family='PRICE_MOMENTUM' then
    v_features := $f$
      p.return_1d_pct,p.return_5d_pct,p.return_20d_pct,p.return_60d_pct,
      p.volatility_range_pct,p.close_vs_20d_high_pct,p.close_vs_20d_low_pct,
      null::numeric as foreign_net_volume_pct,null::numeric as tradable_float_pct,
      null::numeric as market_turnover_share_pct,null::numeric as sector_turnover_share_pct,
      null::numeric as turnover_residual_z,null::numeric as volume_residual_z,
      null::numeric as frequency_residual_z,null::numeric as stock_residual_activity_z,
      null::numeric as market_value_z60,null::numeric as market_volume_z60,
      null::numeric as market_frequency_z60,null::numeric as top10_value_share_pct,
      null::numeric as activity_breadth_pct,null::numeric as market_activity_intensity_z,
      null::numeric as phase3a_score,null::numeric as phase3b_score,null::numeric as phase3c_score,
      null::numeric as advanced_broker_score,null::integer as risk_event_20d_count,
      null::integer as capital_action_90d_count,null::numeric as controller_ownership_pct
    $f$;
  elsif p_factor_family='FLOW_LIQUIDITY' then
    v_features := $f$
      null::numeric as return_1d_pct,null::numeric as return_5d_pct,null::numeric as return_20d_pct,
      null::numeric as return_60d_pct,null::numeric as volatility_range_pct,
      null::numeric as close_vs_20d_high_pct,null::numeric as close_vs_20d_low_pct,
      p.foreign_net_volume_pct,p.tradable_float_pct,p.market_turnover_share_pct,p.sector_turnover_share_pct,
      p.turnover_residual_z,p.volume_residual_z,p.frequency_residual_z,p.stock_residual_activity_z,
      null::numeric as market_value_z60,null::numeric as market_volume_z60,
      null::numeric as market_frequency_z60,null::numeric as top10_value_share_pct,
      null::numeric as activity_breadth_pct,null::numeric as market_activity_intensity_z,
      null::numeric as phase3a_score,null::numeric as phase3b_score,null::numeric as phase3c_score,
      null::numeric as advanced_broker_score,null::integer as risk_event_20d_count,
      null::integer as capital_action_90d_count,null::numeric as controller_ownership_pct
    $f$;
  elsif p_factor_family='MARKET_REGIME' then
    v_features := $f$
      null::numeric as return_1d_pct,null::numeric as return_5d_pct,null::numeric as return_20d_pct,
      null::numeric as return_60d_pct,null::numeric as volatility_range_pct,
      null::numeric as close_vs_20d_high_pct,null::numeric as close_vs_20d_low_pct,
      null::numeric as foreign_net_volume_pct,null::numeric as tradable_float_pct,
      null::numeric as market_turnover_share_pct,null::numeric as sector_turnover_share_pct,
      null::numeric as turnover_residual_z,null::numeric as volume_residual_z,
      null::numeric as frequency_residual_z,null::numeric as stock_residual_activity_z,
      p.market_value_z60,p.market_volume_z60,p.market_frequency_z60,p.top10_value_share_pct,
      p.activity_breadth_pct,p.market_activity_intensity_z,
      null::numeric as phase3a_score,null::numeric as phase3b_score,null::numeric as phase3c_score,
      null::numeric as advanced_broker_score,null::integer as risk_event_20d_count,
      null::integer as capital_action_90d_count,null::numeric as controller_ownership_pct
    $f$;
  elsif p_factor_family='ADVANCED_BROKER' then
    v_features := $f$
      null::numeric as return_1d_pct,null::numeric as return_5d_pct,null::numeric as return_20d_pct,
      null::numeric as return_60d_pct,null::numeric as volatility_range_pct,
      null::numeric as close_vs_20d_high_pct,null::numeric as close_vs_20d_low_pct,
      null::numeric as foreign_net_volume_pct,null::numeric as tradable_float_pct,
      null::numeric as market_turnover_share_pct,null::numeric as sector_turnover_share_pct,
      null::numeric as turnover_residual_z,null::numeric as volume_residual_z,
      null::numeric as frequency_residual_z,null::numeric as stock_residual_activity_z,
      null::numeric as market_value_z60,null::numeric as market_volume_z60,
      null::numeric as market_frequency_z60,null::numeric as top10_value_share_pct,
      null::numeric as activity_breadth_pct,null::numeric as market_activity_intensity_z,
      p.phase3a_score,p.phase3b_score,p.phase3c_score,p.advanced_broker_score,
      null::integer as risk_event_20d_count,null::integer as capital_action_90d_count,
      null::numeric as controller_ownership_pct
    $f$;
  elsif p_factor_family='RISK_ACTION' then
    v_features := $f$
      null::numeric as return_1d_pct,null::numeric as return_5d_pct,null::numeric as return_20d_pct,
      null::numeric as return_60d_pct,null::numeric as volatility_range_pct,
      null::numeric as close_vs_20d_high_pct,null::numeric as close_vs_20d_low_pct,
      null::numeric as foreign_net_volume_pct,null::numeric as tradable_float_pct,
      null::numeric as market_turnover_share_pct,null::numeric as sector_turnover_share_pct,
      null::numeric as turnover_residual_z,null::numeric as volume_residual_z,
      null::numeric as frequency_residual_z,null::numeric as stock_residual_activity_z,
      null::numeric as market_value_z60,null::numeric as market_volume_z60,
      null::numeric as market_frequency_z60,null::numeric as top10_value_share_pct,
      null::numeric as activity_breadth_pct,null::numeric as market_activity_intensity_z,
      null::numeric as phase3a_score,null::numeric as phase3b_score,null::numeric as phase3c_score,
      null::numeric as advanced_broker_score,p.risk_event_20d_count,p.capital_action_90d_count,
      null::numeric as controller_ownership_pct
    $f$;
  elsif p_factor_family='OWNERSHIP' then
    v_features := $f$
      null::numeric as return_1d_pct,null::numeric as return_5d_pct,null::numeric as return_20d_pct,
      null::numeric as return_60d_pct,null::numeric as volatility_range_pct,
      null::numeric as close_vs_20d_high_pct,null::numeric as close_vs_20d_low_pct,
      null::numeric as foreign_net_volume_pct,null::numeric as tradable_float_pct,
      null::numeric as market_turnover_share_pct,null::numeric as sector_turnover_share_pct,
      null::numeric as turnover_residual_z,null::numeric as volume_residual_z,
      null::numeric as frequency_residual_z,null::numeric as stock_residual_activity_z,
      null::numeric as market_value_z60,null::numeric as market_volume_z60,
      null::numeric as market_frequency_z60,null::numeric as top10_value_share_pct,
      null::numeric as activity_breadth_pct,null::numeric as market_activity_intensity_z,
      null::numeric as phase3a_score,null::numeric as phase3b_score,null::numeric as phase3c_score,
      null::numeric as advanced_broker_score,null::integer as risk_event_20d_count,
      null::integer as capital_action_90d_count,p.controller_ownership_pct
    $f$;
  else
    raise exception 'Unknown Phase4C factor family %',p_factor_family;
  end if;

  drop table if exists pg_temp.flow_phase4c_base;
  v_sql := format($q$
    create temp table flow_phase4c_base on commit drop as
    with dm as (
      select as_of_date,
        case ntile(3) over(order by as_of_date)
          when 1 then 'EARLY' when 2 then 'MIDDLE' else 'RECENT' end as stability_bucket
      from public.flow_market_memory_manifest_v4
      where feature_contract='MARKET_MEMORY_V4_1'
    )
    select
      p.as_of_date,p.ticker,
      null::text as sector,null::text as broker_market_regime,null::integer as volatility_bucket,
      null::numeric as traded_value,dm.stability_bucket,
      %1$s,
      c.clean_forward_return_5d_pct,c.clean_mfe_5d_pct,c.clean_mae_5d_pct,
      c.clean_alpha_vs_ihsg_5d_pct,c.clean_alpha_vs_sector_5d_pct,
      c.clean_forward_return_20d_pct,c.clean_mfe_20d_pct,c.clean_mae_20d_pct,
      c.clean_alpha_vs_ihsg_20d_pct,c.clean_alpha_vs_sector_20d_pct,
      c.clean_forward_return_60d_pct,c.clean_mfe_60d_pct,c.clean_mae_60d_pct,
      c.clean_alpha_vs_ihsg_60d_pct,c.clean_alpha_vs_sector_60d_pct,
      c.clean_forward_return_120d_pct,c.clean_mfe_120d_pct,c.clean_mae_120d_pct,
      c.clean_alpha_vs_ihsg_120d_pct,c.clean_alpha_vs_sector_120d_pct,
      c.clean_forward_return_250d_pct,c.clean_mfe_250d_pct,c.clean_mae_250d_pct,
      c.clean_alpha_vs_ihsg_250d_pct,c.clean_alpha_vs_sector_250d_pct,
      c.clean_hit_up_10pct_20d,c.clean_hit_down_10pct_20d,
      c.clean_hit_up_20pct_60d,c.clean_hit_down_20pct_60d,
      c.clean_hit_up_50pct_120d,c.clean_hit_down_30pct_120d,
      c.clean_hit_up_100pct_250d,c.clean_close_multibagger_250d,
      null::integer as liquidity_bucket
    from public.flow_market_learning_panel_v4 p
    join dm on dm.as_of_date=p.as_of_date
    join public.flow_market_learning_labels_clean_v4c c
      on c.as_of_date=p.as_of_date and c.ticker=p.ticker and c.feature_contract=p.feature_contract
    where p.feature_contract='MARKET_MEMORY_V4_1'
  $q$,v_features);
  execute v_sql;
  get diagnostics v_rows=row_count;
  analyze pg_temp.flow_phase4c_base;
  return v_rows;
end;
$$;
revoke all on function public.flow_prepare_phase4c_temp_family_v4(text) from public,anon,authenticated;
grant execute on function public.flow_prepare_phase4c_temp_family_v4(text) to service_role;

create or replace function public.flow_refresh_factor_family_v4(p_factor_family text)
returns jsonb
language plpgsql
security invoker
set search_path=pg_catalog,public
as $$
declare r record; v_base integer; v_factor_count integer:=0; v_rows integer:=0; v_placeholders integer:=0;
begin
  if not exists(select 1 from public.flow_factor_catalog_v4 where factor_family=p_factor_family) then
    raise exception 'Unknown Phase4C factor family %',p_factor_family;
  end if;
  v_base:=public.flow_prepare_phase4c_temp_family_v4(p_factor_family);
  for r in select factor_name from public.flow_factor_catalog_v4 where factor_family=p_factor_family order by factor_name loop
    v_rows:=v_rows+public.flow_refresh_factor_discovery_one_v4(r.factor_name);
    v_placeholders:=v_placeholders+public.flow_fill_factor_placeholders_v4(r.factor_name);
    v_factor_count:=v_factor_count+1;
  end loop;
  perform public.flow_recompute_phase4c_fdr_v4();
  return jsonb_build_object('status','OK','family',p_factor_family,'base_rows',v_base,
    'factors',v_factor_count,'measured_rows',v_rows,'insufficient_placeholders',v_placeholders,
    'storage_policy','TEMP_FAMILY_PRUNED_NO_PERSISTENT_PANEL_DUPLICATION');
end;
$$;
revoke all on function public.flow_refresh_factor_family_v4(text) from public,anon,authenticated;
grant execute on function public.flow_refresh_factor_family_v4(text) to service_role;

comment on function public.flow_prepare_phase4c_temp_family_v4(text) is
'Phase4C family-pruned temp reconstruction over MARKET_MEMORY_V4_1 plus clean labels. Avoids forcing unrelated slow/advanced evidence branches and persists no market panel.';
