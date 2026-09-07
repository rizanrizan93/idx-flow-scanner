-- Phase 4C direct factor-slice remediation.
-- Avoids materializing the 251k-row panel. Each invocation evaluates exactly one
-- factor x horizon x stability window directly from MARKET_MEMORY_V4_1 + clean labels.

create or replace view public.flow_factor_stability_windows_v4
with (security_invoker=true) as
with d as (
  select as_of_date,ntile(3) over(order by as_of_date) as bucket
  from public.flow_market_memory_manifest_v4
  where feature_contract='MARKET_MEMORY_V4_1'
), bounds as (
  select bucket,min(as_of_date) as start_date,max(as_of_date) as end_date,count(*)::integer as session_count
  from d group by bucket
), allb as (
  select 0 as bucket,min(as_of_date) as start_date,max(as_of_date) as end_date,count(*)::integer as session_count
  from d
)
select 'ALL'::text as stability_window,start_date,end_date,session_count from allb
union all
select case bucket when 1 then 'EARLY' when 2 then 'MIDDLE' else 'RECENT' end,
       start_date,end_date,session_count
from bounds;
revoke all on public.flow_factor_stability_windows_v4 from public,anon,authenticated;
grant select on public.flow_factor_stability_windows_v4 to service_role;

create or replace function public.flow_refresh_factor_slice_v4(
  p_factor_name text,
  p_horizon_days integer,
  p_stability_window text
)
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
  v_start date;
  v_end date;
  v_ret text;
  v_mfe text;
  v_mae text;
  v_ihsg text;
  v_sector text;
  v_winner text;
  v_loser text;
  v_multi text;
  v_sql text;
  v_rows integer;
begin
  select factor_family,factor_kind,factor_semantics
    into v_family,v_kind,v_semantics
  from public.flow_factor_catalog_v4
  where factor_name=p_factor_name;
  if v_family is null then raise exception 'Unknown Phase4C factor %',p_factor_name; end if;
  if p_horizon_days not in (5,20,60,120,250) then raise exception 'Unsupported Phase4C horizon %',p_horizon_days; end if;
  select start_date,end_date into v_start,v_end
  from public.flow_factor_stability_windows_v4
  where stability_window=p_stability_window;
  if v_start is null then raise exception 'Unknown Phase4C stability window %',p_stability_window; end if;

  select max(as_of_date) into v_asof
  from public.flow_market_memory_manifest_v4
  where feature_contract='MARKET_MEMORY_V4_1';

  v_ret:=format('clean_forward_return_%sd_pct',p_horizon_days);
  v_mfe:=format('clean_mfe_%sd_pct',p_horizon_days);
  v_mae:=format('clean_mae_%sd_pct',p_horizon_days);
  v_ihsg:=format('clean_alpha_vs_ihsg_%sd_pct',p_horizon_days);
  v_sector:=format('clean_alpha_vs_sector_%sd_pct',p_horizon_days);
  v_winner:=case p_horizon_days when 20 then 'clean_hit_up_10pct_20d' when 60 then 'clean_hit_up_20pct_60d' when 120 then 'clean_hit_up_50pct_120d' when 250 then 'clean_hit_up_100pct_250d' else null end;
  v_loser:=case p_horizon_days when 20 then 'clean_hit_down_10pct_20d' when 60 then 'clean_hit_down_20pct_60d' when 120 then 'clean_hit_down_30pct_120d' else null end;
  v_multi:=case when p_horizon_days=250 then 'clean_close_multibagger_250d' else null end;

  delete from public.flow_factor_discovery_v4
  where discovery_as_of=v_asof and discovery_contract='FACTOR_DISCOVERY_V4_1'
    and factor_name=p_factor_name and horizon_days=p_horizon_days and stability_window=p_stability_window;

  v_sql:=format($q$
    with base as (
      select p.%1$I::double precision as factor_value,
             c.%2$I::double precision as clean_return,
             c.%3$I::double precision as mfe,
             c.%4$I::double precision as mae,
             c.%5$I::double precision as ihsg_alpha,
             c.%6$I::double precision as sector_alpha,
             %7$s as winner,%8$s as loser,%9$s as multi
      from public.flow_market_learning_panel_v4 p
      join public.flow_market_learning_labels_clean_v4c c
        on c.as_of_date=p.as_of_date and c.ticker=p.ticker and c.feature_contract=p.feature_contract
      where p.feature_contract='MARKET_MEMORY_V4_1'
        and p.as_of_date between %10$L::date and %11$L::date
    ), denom as (
      select count(*) filter(where clean_return is not null)::integer as outcome_n,
             count(*) filter(where clean_return is not null and factor_value is not null)::integer as factor_n
      from base
    ), ranked as (
      select *,
        case when %12$L='EVENT' then case when factor_value>0 then 2 else 1 end
             else ntile(10) over(order by factor_value) end as decile,
        case when %12$L='EVENT' then case when factor_value>0 then 2 else 1 end
             else ntile(5) over(order by factor_value) end as quintile
      from base
      where clean_return is not null and factor_value is not null
    ), dbins as (
      select decile as bin,count(*)::integer as n,min(factor_value) as factor_min,max(factor_value) as factor_max,
             avg(clean_return) as mean_ret,stddev_samp(clean_return) as sd_ret,
             percentile_cont(0.5) within group(order by clean_return) as median_ret,
             avg((clean_return>0)::int::double precision)*100.0 as positive_rate
      from ranked group by decile
    ), qbins as (
      select quintile as bin,count(*)::integer as n,min(factor_value) as factor_min,max(factor_value) as factor_max,
             avg(clean_return) as mean_ret,
             percentile_cont(0.5) within group(order by clean_return) as median_ret,
             avg((clean_return>0)::int::double precision)*100.0 as positive_rate
      from ranked group by quintile
    ), dlimits as (
      select min(bin) as min_bin,max(bin) as max_bin from dbins
    ), shape as (
      select corr(d.bin::double precision,d.mean_ret) as mono,
             max(d.n) filter(where d.bin=l.min_bin)::integer as bottom_n,
             max(d.n) filter(where d.bin=l.max_bin)::integer as top_n,
             max(d.mean_ret) filter(where d.bin=l.min_bin) as bottom_mean,
             max(d.mean_ret) filter(where d.bin=l.max_bin) as top_mean,
             max(d.sd_ret) filter(where d.bin=l.min_bin) as bottom_sd,
             max(d.sd_ret) filter(where d.bin=l.max_bin) as top_sd,
             avg(d.mean_ret) filter(where d.bin between 4 and 7) as mid_mean,
             avg(d.mean_ret) filter(where d.bin<=2) as low_mean,
             avg(d.mean_ret) filter(where d.bin>=greatest(l.max_bin-1,2)) as high_mean,
             max(d.mean_ret) filter(where d.bin=l.max_bin-1) as penultimate_mean
      from dbins d cross join dlimits l
    ), overall as (
      select count(*)::integer as n,avg(clean_return) as mean_ret,
             percentile_cont(0.5) within group(order by clean_return) as median_ret,
             avg((clean_return>0)::int::double precision)*100.0 as positive_rate,
             avg(case when winner is null then null else winner::int::double precision end)*100.0 as winner_rate,
             avg(case when loser is null then null else loser::int::double precision end)*100.0 as loser_rate,
             avg(case when multi is null then null else multi::int::double precision end)*100.0 as multi_rate,
             avg(mfe) as mean_mfe,avg(mae) as mean_mae,avg(ihsg_alpha) as mean_ihsg_alpha,avg(sector_alpha) as mean_sector_alpha
      from ranked
    ), js as (
      select
        coalesce((select jsonb_agg(jsonb_build_object('bin',bin,'n',n,'factor_min',factor_min,'factor_max',factor_max,
          'mean_return_pct',mean_ret,'median_return_pct',median_ret,'positive_rate_pct',positive_rate) order by bin) from dbins),'[]'::jsonb) as deciles,
        coalesce((select jsonb_agg(jsonb_build_object('bin',bin,'n',n,'factor_min',factor_min,'factor_max',factor_max,
          'mean_return_pct',mean_ret,'median_return_pct',median_ret,'positive_rate_pct',positive_rate) order by bin) from qbins),'[]'::jsonb) as quintiles
    )
    insert into public.flow_factor_discovery_v4(
      discovery_as_of,discovery_contract,factor_name,factor_family,factor_kind,factor_semantics,horizon_days,stability_window,
      outcome_universe_count,sample_count,missingness_pct,mean_forward_return_pct,median_forward_return_pct,positive_return_rate_pct,
      clean_target_rate_pct,clean_loser_rate_pct,clean_multibagger_rate_pct,mean_mfe_pct,mean_mae_pct,mean_ihsg_alpha_pct,mean_sector_alpha_pct,
      bottom_bin_count,top_bin_count,bottom_bin_mean_return_pct,top_bin_mean_return_pct,top_minus_bottom_return_pct,effect_z,p_value,
      monotonicity_corr,nonlinear_shape,robustness_state,challenger_eligible,bin_stats,source_verified,provenance_state)
    select %13$L::date,'FACTOR_DISCOVERY_V4_1',%14$L,%15$L,%12$L,%16$L,%17$s,%18$L,
      d.outcome_n,o.n,case when d.outcome_n>0 then 100.0*(1.0-o.n::double precision/d.outcome_n) end,
      o.mean_ret,o.median_ret,o.positive_rate,o.winner_rate,o.loser_rate,o.multi_rate,o.mean_mfe,o.mean_mae,o.mean_ihsg_alpha,o.mean_sector_alpha,
      s.bottom_n,s.top_n,s.bottom_mean,s.top_mean,s.top_mean-s.bottom_mean,
      case when s.bottom_n>1 and s.top_n>1 and coalesce(s.bottom_sd,0)>0 and coalesce(s.top_sd,0)>0
        then (s.top_mean-s.bottom_mean)/sqrt(s.bottom_sd*s.bottom_sd/s.bottom_n+s.top_sd*s.top_sd/s.top_n) end,
      case when s.bottom_n>1 and s.top_n>1 and coalesce(s.bottom_sd,0)>0 and coalesce(s.top_sd,0)>0
        then public.flow_normal_two_sided_p_v4((s.top_mean-s.bottom_mean)/sqrt(s.bottom_sd*s.bottom_sd/s.bottom_n+s.top_sd*s.top_sd/s.top_n)) end,
      s.mono,
      case
        when %12$L='EVENT' then 'EVENT_VS_NO_EVENT'
        when s.mono>=0.70 then 'MONOTONIC_UP'
        when s.mono<=-0.70 then 'MONOTONIC_DOWN'
        when s.mid_mean>greatest(coalesce(s.low_mean,-1e9),coalesce(s.high_mean,-1e9))+0.25 then 'INVERTED_U'
        when s.mid_mean<least(coalesce(s.low_mean,1e9),coalesce(s.high_mean,1e9))-0.25 then 'U_SHAPE'
        when s.top_mean<coalesce(s.penultimate_mean,s.top_mean)-0.25 then 'TOP_BIN_CHASE_REVERSAL'
        else 'NON_MONOTONIC' end,
      case when o.n<1000 or coalesce(s.bottom_n,0)<100 or coalesce(s.top_n,0)<100 then 'INSUFFICIENT_SAMPLE' else 'PENDING_FDR_STABILITY' end,
      false,jsonb_build_object('deciles',j.deciles,'quintiles',j.quintiles),true,
      case when o.n=0 then 'GENUINE_EVIDENCE_ABSENT_OR_IMMATURE_NOT_FABRICATED' else 'LEAKAGE_SAFE_CLEAN_LABEL_DIRECT_AGGREGATE' end
    from denom d cross join overall o cross join shape s cross join js j;
  $q$,
    p_factor_name,v_ret,v_mfe,v_mae,v_ihsg,v_sector,
    coalesce(format('c.%I',v_winner),'null::boolean'),
    coalesce(format('c.%I',v_loser),'null::boolean'),
    coalesce(format('c.%I',v_multi),'null::boolean'),
    v_start::text,v_end::text,v_kind,v_asof::text,p_factor_name,v_family,v_semantics,p_horizon_days,p_stability_window
  );
  execute v_sql;
  get diagnostics v_rows=row_count;
  return jsonb_build_object('status','OK','factor',p_factor_name,'horizon_days',p_horizon_days,
    'stability_window',p_stability_window,'rows_written',v_rows,'storage_policy','DIRECT_AGGREGATE_NO_PANEL_MATERIALIZATION');
end;
$$;
revoke all on function public.flow_refresh_factor_slice_v4(text,integer,text) from public,anon,authenticated;
grant execute on function public.flow_refresh_factor_slice_v4(text,integer,text) to service_role;

comment on function public.flow_refresh_factor_slice_v4(text,integer,text) is
'Phase4C one-factor/one-horizon/one-window direct aggregate. Computes deciles and quintiles with clean corporate-action-guarded outcomes and never materializes the market panel.';