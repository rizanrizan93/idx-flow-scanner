-- Phase 4C direct interaction slices.
-- Pre-registered interactions only; no Cartesian search. One interaction x horizon x
-- stability window per statement, so the 251k market panel is never materialized.

create or replace function public.flow_refresh_interaction_slice_v4(
  p_interaction_name text,
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
  v_a text;
  v_b text;
  v_a_kind text;
  v_b_kind text;
  v_start date;
  v_end date;
  v_ret text;
  v_winner text;
  v_winner_expr text;
  v_sql text;
  v_rows integer;
begin
  select factor_a,factor_b into v_a,v_b
  from public.flow_factor_interaction_catalog_v4
  where interaction_name=p_interaction_name;
  if v_a is null then raise exception 'Unknown Phase4C interaction %',p_interaction_name; end if;
  if p_horizon_days not in (20,60,120) then raise exception 'Unsupported Phase4C interaction horizon %',p_horizon_days; end if;
  select factor_kind into v_a_kind from public.flow_factor_catalog_v4 where factor_name=v_a;
  select factor_kind into v_b_kind from public.flow_factor_catalog_v4 where factor_name=v_b;
  select start_date,end_date into v_start,v_end
  from public.flow_factor_stability_windows_v4 where stability_window=p_stability_window;
  if v_start is null then raise exception 'Unknown Phase4C stability window %',p_stability_window; end if;
  select max(as_of_date) into v_asof from public.flow_market_memory_manifest_v4 where feature_contract='MARKET_MEMORY_V4_1';

  v_ret:=format('clean_forward_return_%sd_pct',p_horizon_days);
  v_winner:=case p_horizon_days when 20 then 'clean_hit_up_10pct_20d' when 60 then 'clean_hit_up_20pct_60d' else 'clean_hit_up_50pct_120d' end;
  v_winner_expr:=format('c.%I',v_winner);

  delete from public.flow_factor_interactions_v4
  where discovery_as_of=v_asof and discovery_contract='FACTOR_DISCOVERY_V4_1'
    and interaction_name=p_interaction_name and horizon_days=p_horizon_days and stability_window=p_stability_window;

  v_sql:=format($q$
    with base as (
      select p.%1$I::double precision as a,p.%2$I::double precision as b,
             c.%3$I::double precision as ret,%4$s as winner
      from public.flow_market_learning_panel_v4 p
      join public.flow_market_learning_labels_clean_v4c c
        on c.as_of_date=p.as_of_date and c.ticker=p.ticker and c.feature_contract=p.feature_contract
      where p.feature_contract='MARKET_MEMORY_V4_1'
        and p.as_of_date between %5$L::date and %6$L::date
        and p.%1$I is not null and p.%2$I is not null and c.%3$I is not null
    ), th as (
      select case when %7$L='EVENT' then 0::double precision else percentile_cont(0.8) within group(order by a) end as a80,
             case when %8$L='EVENT' then 0::double precision else percentile_cont(0.8) within group(order by b) end as b80
      from base
    ), tagged as (
      select x.*,
             case when %7$L='EVENT' then x.a>0 else x.a>=t.a80 end as ah,
             case when %8$L='EVENT' then x.b>0 else x.b>=t.b80 end as bh
      from base x cross join th t
    ), ag as (
      select count(*)::integer as n,avg(ret) as baseline,
             avg(ret) filter(where ah) as a_high,avg(ret) filter(where bh) as b_high,
             count(*) filter(where ah and bh)::integer as hh_n,
             avg(ret) filter(where ah and bh) as hh_mean,stddev_samp(ret) filter(where ah and bh) as hh_sd,
             count(*) filter(where not(ah and bh))::integer as rest_n,
             avg(ret) filter(where not(ah and bh)) as rest_mean,stddev_samp(ret) filter(where not(ah and bh)) as rest_sd,
             avg(case when ah and bh and winner is not null then winner::int::double precision end)*100.0 as hh_target
      from tagged
    )
    insert into public.flow_factor_interactions_v4(
      discovery_as_of,discovery_contract,interaction_name,factor_a,factor_b,horizon_days,stability_window,
      sample_count,high_high_count,baseline_mean_return_pct,factor_a_high_mean_return_pct,factor_b_high_mean_return_pct,
      high_high_mean_return_pct,interaction_excess_return_pct,high_high_clean_target_rate_pct,effect_z,p_value,
      robustness_state,source_verified,provenance_state)
    select %9$L::date,'FACTOR_DISCOVERY_V4_1',%10$L,%11$L,%12$L,%13$s,%14$L,
      n,hh_n,baseline,a_high,b_high,hh_mean,hh_mean-a_high-b_high+baseline,hh_target,
      case when hh_n>1 and rest_n>1 and coalesce(hh_sd,0)>0 and coalesce(rest_sd,0)>0
        then (hh_mean-rest_mean)/sqrt(hh_sd*hh_sd/hh_n+rest_sd*rest_sd/rest_n) end,
      case when hh_n>1 and rest_n>1 and coalesce(hh_sd,0)>0 and coalesce(rest_sd,0)>0
        then public.flow_normal_two_sided_p_v4((hh_mean-rest_mean)/sqrt(hh_sd*hh_sd/hh_n+rest_sd*rest_sd/rest_n)) end,
      case when n<1000 or hh_n<100 then 'INSUFFICIENT_SAMPLE' else 'PENDING_FDR_STABILITY' end,
      true,case when n=0 then 'GENUINE_EVIDENCE_ABSENT_OR_IMMATURE_NOT_FABRICATED' else 'BOUNDED_PREREGISTERED_DIRECT_INTERACTION' end
    from ag;
  $q$,v_a,v_b,v_ret,v_winner_expr,v_start::text,v_end::text,v_a_kind,v_b_kind,
      v_asof::text,p_interaction_name,v_a,v_b,p_horizon_days,p_stability_window);
  execute v_sql;
  get diagnostics v_rows=row_count;
  return jsonb_build_object('status','OK','interaction',p_interaction_name,'horizon_days',p_horizon_days,
    'stability_window',p_stability_window,'rows_written',v_rows,
    'search_policy','PREREGISTERED_10_INTERACTIONS_NO_CARTESIAN','storage_policy','DIRECT_AGGREGATE_NO_PANEL_MATERIALIZATION');
end;
$$;
revoke all on function public.flow_refresh_interaction_slice_v4(text,integer,text) from public,anon,authenticated;
grant execute on function public.flow_refresh_interaction_slice_v4(text,integer,text) to service_role;
