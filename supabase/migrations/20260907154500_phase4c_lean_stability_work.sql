-- Phase 4C lean work-table closure.
-- Supersedes the wide transient work layout after the full-window stability sort
-- exceeded temporary-disk capacity. This layout keeps only factor values, clean
-- forward returns, and regime keys. ALL-history MFE/MAE/alpha metrics remain in
-- the canonical direct-slice rows and are not duplicated here.

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
      c.clean_forward_return_5d_pct,c.clean_forward_return_20d_pct,c.clean_forward_return_60d_pct,
      c.clean_forward_return_120d_pct,c.clean_forward_return_250d_pct,
      null::integer as liquidity_bucket
    from public.flow_market_learning_panel_v4 p
    join public.flow_market_learning_labels_clean_v4c c
      on c.as_of_date=p.as_of_date and c.ticker=p.ticker and c.feature_contract=p.feature_contract
    where false
  $ddl$;
  execute 'alter table public.flow_phase4c_work_base_v4 enable row level security';
  execute 'revoke all on public.flow_phase4c_work_base_v4 from public,anon,authenticated';
  execute 'grant select,insert,delete,truncate on public.flow_phase4c_work_base_v4 to service_role';
  return jsonb_build_object('status','OK','work_table','flow_phase4c_work_base_v4','storage_policy','LEAN_TRANSIENT_UNLOGGED_DROP_AFTER_CLOSURE');
end;
$$;

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
    c.clean_forward_return_5d_pct,c.clean_forward_return_20d_pct,c.clean_forward_return_60d_pct,
    c.clean_forward_return_120d_pct,c.clean_forward_return_250d_pct,
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

create or replace function public.flow_refresh_factor_stability_window_work_v4(
  p_factor_name text,
  p_stability_window text
)
returns jsonb
language plpgsql
security invoker
set search_path=pg_catalog,public
set work_mem='24MB'
as $$
declare
  v_asof date;
  v_family text;
  v_kind text;
  v_semantics text;
  v_horizon integer;
  v_ret_col text;
  v_sql text;
  v_written integer:=0;
begin
  if p_stability_window not in ('EARLY','MIDDLE','RECENT') then
    raise exception 'Unsupported Phase4C stability window %',p_stability_window;
  end if;
  if to_regclass('public.flow_phase4c_work_base_v4') is null then
    raise exception 'Phase4C work table is not prepared';
  end if;
  select factor_family,factor_kind,factor_semantics
    into v_family,v_kind,v_semantics
  from public.flow_factor_catalog_v4 where factor_name=p_factor_name;
  if v_family is null then raise exception 'Unknown Phase4C factor %',p_factor_name; end if;
  select max(as_of_date) into v_asof
  from public.flow_market_memory_manifest_v4 where feature_contract='MARKET_MEMORY_V4_1';

  foreach v_horizon in array array[5,20,60,120,250]
  loop
    v_ret_col:=format('clean_forward_return_%sd_pct',v_horizon);
    delete from public.flow_factor_discovery_v4
    where discovery_as_of=v_asof and discovery_contract='FACTOR_DISCOVERY_V4_1'
      and factor_name=p_factor_name and horizon_days=v_horizon
      and stability_window=p_stability_window;

    v_sql:=format($q$
      with b as (
        select %1$I::double precision as factor_value,
               %2$I::double precision as clean_return
        from public.flow_phase4c_work_base_v4
        where stability_bucket=%3$L and %2$I is not null
      ), d as (
        select count(*)::integer as outcome_n,
               count(*) filter(where factor_value is not null)::integer as factor_n
        from b
      ), q as (
        select percentile_cont(0.10) within group(order by factor_value) as p10,
               percentile_cont(0.90) within group(order by factor_value) as p90
        from b where factor_value is not null
      ), tagged as (
        select b.*,
          case when %4$L='EVENT'
               then case when factor_value<=0 then -1 when factor_value>0 then 1 end
               else case when factor_value<=q.p10 then -1 when factor_value>=q.p90 then 1 end end as edge
        from b cross join q
        where factor_value is not null
      ), s as (
        select
          count(*)::integer as n,
          avg(clean_return) as mean_ret,
          percentile_cont(0.5) within group(order by clean_return) as median_ret,
          avg((clean_return>0)::int::double precision)*100.0 as positive_rate,
          count(*) filter(where edge=-1)::integer as bottom_n,
          count(*) filter(where edge=1)::integer as top_n,
          avg(clean_return) filter(where edge=-1) as bottom_mean,
          avg(clean_return) filter(where edge=1) as top_mean,
          stddev_samp(clean_return) filter(where edge=-1) as bottom_sd,
          stddev_samp(clean_return) filter(where edge=1) as top_sd
        from tagged
      )
      insert into public.flow_factor_discovery_v4(
        discovery_as_of,discovery_contract,factor_name,factor_family,factor_kind,factor_semantics,
        horizon_days,stability_window,outcome_universe_count,sample_count,missingness_pct,
        mean_forward_return_pct,median_forward_return_pct,positive_return_rate_pct,
        bottom_bin_count,top_bin_count,bottom_bin_mean_return_pct,top_bin_mean_return_pct,
        top_minus_bottom_return_pct,effect_z,p_value,nonlinear_shape,robustness_state,
        challenger_eligible,bin_stats,source_verified,provenance_state)
      select %5$L::date,'FACTOR_DISCOVERY_V4_1',%6$L,%7$L,%4$L,%8$L,
        %9$s,%3$L,d.outcome_n,s.n,
        case when d.outcome_n>0 then 100.0*(1.0-s.n::double precision/d.outcome_n) end,
        s.mean_ret,s.median_ret,s.positive_rate,
        s.bottom_n,s.top_n,s.bottom_mean,s.top_mean,s.top_mean-s.bottom_mean,
        case when s.bottom_n>1 and s.top_n>1 and coalesce(s.bottom_sd,0)>0 and coalesce(s.top_sd,0)>0
          then (s.top_mean-s.bottom_mean)/sqrt(s.bottom_sd*s.bottom_sd/s.bottom_n+s.top_sd*s.top_sd/s.top_n) end,
        case when s.bottom_n>1 and s.top_n>1 and coalesce(s.bottom_sd,0)>0 and coalesce(s.top_sd,0)>0
          then public.flow_normal_two_sided_p_v4((s.top_mean-s.bottom_mean)/sqrt(s.bottom_sd*s.bottom_sd/s.bottom_n+s.top_sd*s.top_sd/s.top_n)) end,
        case when %4$L='EVENT' then 'EVENT_VS_NO_EVENT' else 'STABILITY_EDGE_DECILES' end,
        case when s.n<1000 or coalesce(s.bottom_n,0)<100 or coalesce(s.top_n,0)<100 then 'INSUFFICIENT_SAMPLE' else 'PENDING_FDR_STABILITY' end,
        false,'[]'::jsonb,true,'LEAKAGE_SAFE_CLEAN_LABEL_LEAN_WORK_STABILITY'
      from d cross join s;
    $q$,p_factor_name,v_ret_col,p_stability_window,v_kind,v_asof::text,p_factor_name,v_family,v_semantics,v_horizon);
    execute v_sql;
    v_written:=v_written+1;
  end loop;
  return jsonb_build_object('status','OK','factor',p_factor_name,'stability_window',p_stability_window,'rows_written',v_written,'storage_policy','LEAN_TRANSIENT_WORK_TABLE');
end;
$$;
revoke all on function public.flow_refresh_factor_stability_window_work_v4(text,text) from public,anon,authenticated;
grant execute on function public.flow_refresh_factor_stability_window_work_v4(text,text) to service_role;

create or replace function public.flow_fill_factor_stability_placeholders_work_v4(p_factor_name text)
returns jsonb
language plpgsql
security invoker
set search_path=pg_catalog,public
as $$
declare
  v_asof date;
  v_family text;
  v_kind text;
  v_semantics text;
  v_rows integer;
begin
  select factor_family,factor_kind,factor_semantics into v_family,v_kind,v_semantics
  from public.flow_factor_catalog_v4 where factor_name=p_factor_name;
  if v_family is null then raise exception 'Unknown Phase4C factor %',p_factor_name; end if;
  select max(as_of_date) into v_asof from public.flow_market_memory_manifest_v4 where feature_contract='MARKET_MEMORY_V4_1';
  with u as (
    select stability_bucket as stability_window,h.horizon_days,
      count(*) filter(where h.clean_return is not null)::integer as outcome_n
    from public.flow_phase4c_work_base_v4 w
    cross join lateral(values
      (5,w.clean_forward_return_5d_pct::double precision),
      (20,w.clean_forward_return_20d_pct::double precision),
      (60,w.clean_forward_return_60d_pct::double precision),
      (120,w.clean_forward_return_120d_pct::double precision),
      (250,w.clean_forward_return_250d_pct::double precision)
    ) h(horizon_days,clean_return)
    group by 1,2
  )
  insert into public.flow_factor_discovery_v4(
    discovery_as_of,discovery_contract,factor_name,factor_family,factor_kind,factor_semantics,
    horizon_days,stability_window,outcome_universe_count,sample_count,missingness_pct,
    robustness_state,challenger_eligible,bin_stats,source_verified,provenance_state)
  select v_asof,'FACTOR_DISCOVERY_V4_1',p_factor_name,v_family,v_kind,v_semantics,
    u.horizon_days,u.stability_window,u.outcome_n,0,100.0,'INSUFFICIENT_SAMPLE',false,'[]'::jsonb,true,
    'GENUINE_EVIDENCE_ABSENT_OR_IMMATURE_NOT_FABRICATED'
  from u
  on conflict(discovery_as_of,discovery_contract,factor_name,horizon_days,stability_window) do update set
    outcome_universe_count=excluded.outcome_universe_count,sample_count=0,missingness_pct=100.0,
    robustness_state='INSUFFICIENT_SAMPLE',challenger_eligible=false,bin_stats='[]'::jsonb,
    source_verified=true,provenance_state='GENUINE_EVIDENCE_ABSENT_OR_IMMATURE_NOT_FABRICATED';
  get diagnostics v_rows=row_count;
  return jsonb_build_object('status','OK','factor',p_factor_name,'placeholder_rows_touched',v_rows);
end;
$$;
revoke all on function public.flow_fill_factor_stability_placeholders_work_v4(text) from public,anon,authenticated;
grant execute on function public.flow_fill_factor_stability_placeholders_work_v4(text) to service_role;

comment on function public.flow_refresh_factor_stability_window_work_v4(text,text) is
'Lean Phase4C stability calculation for one factor across all five horizons in one EARLY/MIDDLE/RECENT window. Uses edge deciles only; canonical ALL-history rows retain full MFE/MAE/alpha/bin diagnostics.';
