-- Phase 4C lean bounded interaction work path.
-- Computes only the 10 pre-registered interactions from the transient lean work table.
-- No Cartesian interaction search is permitted.

create or replace function public.flow_refresh_interaction_window_work_v4(
  p_interaction_name text,
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
  v_a text;
  v_b text;
  v_a_kind text;
  v_b_kind text;
  v_horizon integer;
  v_ret_col text;
  v_filter text;
  v_sql text;
  v_written integer:=0;
begin
  if p_stability_window not in ('ALL','EARLY','MIDDLE','RECENT') then
    raise exception 'Unsupported Phase4C interaction stability window %',p_stability_window;
  end if;
  if to_regclass('public.flow_phase4c_work_base_v4') is null then
    raise exception 'Phase4C work table is not prepared';
  end if;
  select factor_a,factor_b into v_a,v_b
  from public.flow_factor_interaction_catalog_v4 where interaction_name=p_interaction_name;
  if v_a is null then raise exception 'Unknown Phase4C interaction %',p_interaction_name; end if;
  select factor_kind into v_a_kind from public.flow_factor_catalog_v4 where factor_name=v_a;
  select factor_kind into v_b_kind from public.flow_factor_catalog_v4 where factor_name=v_b;
  select max(as_of_date) into v_asof
  from public.flow_market_memory_manifest_v4 where feature_contract='MARKET_MEMORY_V4_1';
  v_filter:=case when p_stability_window='ALL' then 'true'
    else format('stability_bucket=%L',p_stability_window) end;

  foreach v_horizon in array array[20,60,120]
  loop
    v_ret_col:=format('clean_forward_return_%sd_pct',v_horizon);
    delete from public.flow_factor_interactions_v4
    where discovery_as_of=v_asof and discovery_contract='FACTOR_DISCOVERY_V4_1'
      and interaction_name=p_interaction_name and horizon_days=v_horizon
      and stability_window=p_stability_window;

    v_sql:=format($q$
      with base as (
        select %1$I::double precision as a,
               %2$I::double precision as b,
               %3$I::double precision as ret
        from public.flow_phase4c_work_base_v4
        where %4$s and %1$I is not null and %2$I is not null and %3$I is not null
      ), th as (
        select case when %5$L='EVENT' then 0::double precision
                    else percentile_cont(0.8) within group(order by a) end as a80,
               case when %6$L='EVENT' then 0::double precision
                    else percentile_cont(0.8) within group(order by b) end as b80
        from base
      ), tagged as (
        select x.*,
          case when %5$L='EVENT' then x.a>0 else x.a>=t.a80 end as ah,
          case when %6$L='EVENT' then x.b>0 else x.b>=t.b80 end as bh
        from base x cross join th t
      ), ag as (
        select count(*)::integer as n,
          avg(ret) as baseline,
          avg(ret) filter(where ah) as a_high,
          avg(ret) filter(where bh) as b_high,
          count(*) filter(where ah and bh)::integer as hh_n,
          avg(ret) filter(where ah and bh) as hh_mean,
          stddev_samp(ret) filter(where ah and bh) as hh_sd,
          count(*) filter(where not(ah and bh))::integer as rest_n,
          avg(ret) filter(where not(ah and bh)) as rest_mean,
          stddev_samp(ret) filter(where not(ah and bh)) as rest_sd
        from tagged
      )
      insert into public.flow_factor_interactions_v4(
        discovery_as_of,discovery_contract,interaction_name,factor_a,factor_b,
        horizon_days,stability_window,sample_count,high_high_count,
        baseline_mean_return_pct,factor_a_high_mean_return_pct,factor_b_high_mean_return_pct,
        high_high_mean_return_pct,interaction_excess_return_pct,high_high_clean_target_rate_pct,
        effect_z,p_value,robustness_state,source_verified,provenance_state)
      select %7$L::date,'FACTOR_DISCOVERY_V4_1',%8$L,%9$L,%10$L,
        %11$s,%12$L,n,hh_n,baseline,a_high,b_high,hh_mean,
        hh_mean-a_high-b_high+baseline,null::double precision,
        case when hh_n>1 and rest_n>1 and coalesce(hh_sd,0)>0 and coalesce(rest_sd,0)>0
          then (hh_mean-rest_mean)/sqrt(hh_sd*hh_sd/hh_n+rest_sd*rest_sd/rest_n) end,
        case when hh_n>1 and rest_n>1 and coalesce(hh_sd,0)>0 and coalesce(rest_sd,0)>0
          then public.flow_normal_two_sided_p_v4((hh_mean-rest_mean)/sqrt(hh_sd*hh_sd/hh_n+rest_sd*rest_sd/rest_n)) end,
        case when n<1000 or hh_n<100 then 'INSUFFICIENT_SAMPLE' else 'PENDING_FDR_STABILITY' end,
        true,case when n=0 then 'GENUINE_EVIDENCE_ABSENT_OR_IMMATURE_NOT_FABRICATED'
                  else 'BOUNDED_PREREGISTERED_LEAN_WORK_INTERACTION' end
      from ag;
    $q$,v_a,v_b,v_ret_col,v_filter,v_a_kind,v_b_kind,v_asof::text,
      p_interaction_name,v_a,v_b,v_horizon,p_stability_window);
    execute v_sql;
    v_written:=v_written+1;
  end loop;
  return jsonb_build_object('status','OK','interaction',p_interaction_name,
    'stability_window',p_stability_window,'rows_written',v_written,
    'search_policy','PREREGISTERED_10_INTERACTIONS_NO_CARTESIAN',
    'storage_policy','LEAN_TRANSIENT_WORK_TABLE');
end;
$$;

revoke all on function public.flow_refresh_interaction_window_work_v4(text,text) from public,anon,authenticated;
grant execute on function public.flow_refresh_interaction_window_work_v4(text,text) to service_role;

comment on function public.flow_refresh_interaction_window_work_v4(text,text) is
'Phase4C bounded interaction discovery for one pre-registered interaction across 20/60/120D within ALL/EARLY/MIDDLE/RECENT. Event factors use >0; continuous factors use 80th percentile. No Cartesian search.';
