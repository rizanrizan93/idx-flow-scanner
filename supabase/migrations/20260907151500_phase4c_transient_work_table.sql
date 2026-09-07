-- Phase 4C transient work-table remediation.
-- Builds the expensive MARKET_MEMORY_V4_1 x clean-label join in three bounded
-- stability-window chunks, then reuses it for stability / interaction / regime work.
-- The work table is UNLOGGED, private, temporary-by-policy, and explicitly dropped
-- after Phase 4C closure. No duplicated market panel remains in final production state.

create or replace function public.flow_phase4c_work_reset_v4()
returns jsonb
language plpgsql
security invoker
set search_path=pg_catalog,public
as $$
begin
  execute 'drop table if exists public.flow_phase4c_work_base_v4';
  execute $ddl$
    create unlogged table public.flow_phase4c_work_base_v4 as
    select
      p.as_of_date,p.ticker,p.sector,p.broker_market_regime,p.volatility_bucket,p.traded_value,
      null::text as stability_bucket,
      p.return_1d_pct,p.return_5d_pct,p.return_20d_pct,p.return_60d_pct,
      p.volatility_range_pct,p.close_vs_20d_high_pct,p.close_vs_20d_low_pct,
      p.foreign_net_volume_pct,p.tradable_float_pct,p.market_turnover_share_pct,p.sector_turnover_share_pct,
      p.turnover_residual_z,p.volume_residual_z,p.frequency_residual_z,p.stock_residual_activity_z,
      p.market_value_z60,p.market_volume_z60,p.market_frequency_z60,p.top10_value_share_pct,
      p.activity_breadth_pct,p.market_activity_intensity_z,
      case when p.advanced_3abc_available then p.phase3a_score end as phase3a_score,
      case when p.advanced_3abc_available then p.phase3b_score end as phase3b_score,
      case when p.advanced_3abc_available then p.phase3c_score end as phase3c_score,
      case when p.advanced_3abc_available then p.advanced_broker_score end as advanced_broker_score,
      p.risk_event_20d_count,p.capital_action_90d_count,p.controller_ownership_pct,
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
    join public.flow_market_learning_labels_clean_v4c c
      on c.as_of_date=p.as_of_date and c.ticker=p.ticker and c.feature_contract=p.feature_contract
    where false
  $ddl$;
  execute 'alter table public.flow_phase4c_work_base_v4 enable row level security';
  execute 'revoke all on public.flow_phase4c_work_base_v4 from public,anon,authenticated';
  execute 'grant select,insert,delete,truncate on public.flow_phase4c_work_base_v4 to service_role';
  return jsonb_build_object('status','OK','work_table','flow_phase4c_work_base_v4','storage_policy','TRANSIENT_UNLOGGED_DROP_AFTER_CLOSURE');
end;
$$;
revoke all on function public.flow_phase4c_work_reset_v4() from public,anon,authenticated;
grant execute on function public.flow_phase4c_work_reset_v4() to service_role;

create or replace function public.flow_phase4c_work_load_window_v4(p_stability_window text)
returns jsonb
language plpgsql
security invoker
set search_path=pg_catalog,public
as $$
declare
  v_start date;
  v_end date;
  v_rows integer;
begin
  if p_stability_window not in ('EARLY','MIDDLE','RECENT') then
    raise exception 'Unsupported Phase4C work stability window %',p_stability_window;
  end if;
  if to_regclass('public.flow_phase4c_work_base_v4') is null then
    raise exception 'Phase4C work table is not prepared';
  end if;
  select start_date,end_date into v_start,v_end
  from public.flow_factor_stability_windows_v4
  where stability_window=p_stability_window;

  delete from public.flow_phase4c_work_base_v4 where stability_bucket=p_stability_window;

  insert into public.flow_phase4c_work_base_v4
  select
    p.as_of_date,p.ticker,p.sector,p.broker_market_regime,p.volatility_bucket,p.traded_value,
    p_stability_window,
    p.return_1d_pct,p.return_5d_pct,p.return_20d_pct,p.return_60d_pct,
    p.volatility_range_pct,p.close_vs_20d_high_pct,p.close_vs_20d_low_pct,
    p.foreign_net_volume_pct,p.tradable_float_pct,p.market_turnover_share_pct,p.sector_turnover_share_pct,
    p.turnover_residual_z,p.volume_residual_z,p.frequency_residual_z,p.stock_residual_activity_z,
    p.market_value_z60,p.market_volume_z60,p.market_frequency_z60,p.top10_value_share_pct,
    p.activity_breadth_pct,p.market_activity_intensity_z,
    case when p.advanced_3abc_available then p.phase3a_score end,
    case when p.advanced_3abc_available then p.phase3b_score end,
    case when p.advanced_3abc_available then p.phase3c_score end,
    case when p.advanced_3abc_available then p.advanced_broker_score end,
    p.risk_event_20d_count,p.capital_action_90d_count,p.controller_ownership_pct,
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
    ntile(5) over(partition by p.as_of_date order by p.traded_value nulls first)
  from public.flow_market_learning_panel_v4 p
  join public.flow_market_learning_labels_clean_v4c c
    on c.as_of_date=p.as_of_date and c.ticker=p.ticker and c.feature_contract=p.feature_contract
  where p.feature_contract='MARKET_MEMORY_V4_1'
    and p.source_verified
    and p.as_of_date between v_start and v_end;
  get diagnostics v_rows=row_count;
  analyze public.flow_phase4c_work_base_v4;
  return jsonb_build_object('status','OK','stability_window',p_stability_window,'rows_written',v_rows,'start_date',v_start,'end_date',v_end);
end;
$$;
revoke all on function public.flow_phase4c_work_load_window_v4(text) from public,anon,authenticated;
grant execute on function public.flow_phase4c_work_load_window_v4(text) to service_role;

create or replace function public.flow_refresh_factor_stability_work_v4(p_factor_name text)
returns jsonb
language plpgsql
security invoker
set search_path=pg_catalog,public
as $$
declare
  v_asof date;
  v_rows integer;
  v_all_rows integer;
begin
  if to_regclass('public.flow_phase4c_work_base_v4') is null then
    raise exception 'Phase4C work table is not prepared';
  end if;
  select max(as_of_date) into v_asof
  from public.flow_market_memory_manifest_v4 where feature_contract='MARKET_MEMORY_V4_1';

  drop view if exists pg_temp.flow_phase4c_base;
  create temp view flow_phase4c_base as select * from public.flow_phase4c_work_base_v4;

  drop table if exists pg_temp.flow_phase4c_factor_all_backup;
  create temp table flow_phase4c_factor_all_backup on commit drop as
  select * from public.flow_factor_discovery_v4
  where discovery_as_of=v_asof
    and discovery_contract='FACTOR_DISCOVERY_V4_1'
    and factor_name=p_factor_name
    and stability_window='ALL';
  select count(*) into v_all_rows from pg_temp.flow_phase4c_factor_all_backup;
  if v_all_rows<>5 then
    raise exception 'Expected five canonical ALL rows for %, got %',p_factor_name,v_all_rows;
  end if;

  v_rows:=public.flow_refresh_factor_discovery_one_v4(p_factor_name);

  delete from public.flow_factor_discovery_v4
  where discovery_as_of=v_asof
    and discovery_contract='FACTOR_DISCOVERY_V4_1'
    and factor_name=p_factor_name
    and stability_window='ALL';
  insert into public.flow_factor_discovery_v4
  select * from pg_temp.flow_phase4c_factor_all_backup;

  return jsonb_build_object('status','OK','factor',p_factor_name,'core_rows_written',v_rows,'stability_rows',v_rows-5,'storage_policy','TRANSIENT_WORK_TABLE_NO_PERSISTENT_PANEL');
end;
$$;
revoke all on function public.flow_refresh_factor_stability_work_v4(text) from public,anon,authenticated;
grant execute on function public.flow_refresh_factor_stability_work_v4(text) to service_role;

create or replace function public.flow_phase4c_work_drop_v4()
returns jsonb
language plpgsql
security invoker
set search_path=pg_catalog,public
as $$
begin
  execute 'drop table if exists public.flow_phase4c_work_base_v4';
  return jsonb_build_object('status','OK','work_table_dropped',true);
end;
$$;
revoke all on function public.flow_phase4c_work_drop_v4() from public,anon,authenticated;
grant execute on function public.flow_phase4c_work_drop_v4() to service_role;

comment on function public.flow_phase4c_work_reset_v4() is
'Creates the private transient UNLOGGED Phase4C work table. Runtime-only; must be dropped after closure.';
comment on function public.flow_phase4c_work_load_window_v4(text) is
'Loads one EARLY/MIDDLE/RECENT Phase4C work chunk under the database statement timeout, with genuine 3ABC masking.';
comment on function public.flow_refresh_factor_stability_work_v4(text) is
'Computes ALL/EARLY/MIDDLE/RECENT for one factor from the prejoined transient work table and restores canonical direct ALL-history rows.';
comment on function public.flow_phase4c_work_drop_v4() is
'Drops the transient Phase4C work table after factor/interaction/regime closure.';
