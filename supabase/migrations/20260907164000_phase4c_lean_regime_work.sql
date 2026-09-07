-- Phase 4C lean regime conditioning from the transient prejoined work table.
-- Applies only the four pre-registered regime dimensions.

create or replace function public.flow_refresh_regime_factor_work_v4(
  p_factor_name text,
  p_horizon_days integer
)
returns jsonb
language plpgsql
security invoker
set search_path=pg_catalog,public
set work_mem='24MB'
as $$
declare
  v_asof date;
  v_kind text;
  v_ret_col text;
  v_regime_type text;
  v_regime_expr text;
  v_classification text;
  v_all_effect double precision;
  v_sql text;
  v_rows integer;
  v_total integer:=0;
begin
  if p_horizon_days not in (5,20,60,120,250) then
    raise exception 'Unsupported Phase4C regime horizon %',p_horizon_days;
  end if;
  if to_regclass('public.flow_phase4c_work_base_v4') is null then
    raise exception 'Phase4C work table is not prepared';
  end if;
  select factor_kind into v_kind from public.flow_factor_catalog_v4 where factor_name=p_factor_name;
  if v_kind is null then raise exception 'Unknown Phase4C factor %',p_factor_name; end if;
  select max(as_of_date) into v_asof
  from public.flow_market_memory_manifest_v4 where feature_contract='MARKET_MEMORY_V4_1';
  select top_minus_bottom_return_pct into v_all_effect
  from public.flow_factor_discovery_v4
  where discovery_as_of=v_asof and factor_name=p_factor_name
    and horizon_days=p_horizon_days and stability_window='ALL';
  v_ret_col:=format('clean_forward_return_%sd_pct',p_horizon_days);

  foreach v_regime_type in array array['MARKET_REGIME','SECTOR','VOLATILITY_BUCKET','LIQUIDITY_BUCKET']
  loop
    v_regime_expr:=case v_regime_type
      when 'MARKET_REGIME' then 'coalesce(broker_market_regime,''UNKNOWN'')'
      when 'SECTOR' then 'coalesce(sector,''UNKNOWN'')'
      when 'VOLATILITY_BUCKET' then 'coalesce(volatility_bucket::text,''UNKNOWN'')'
      else 'case when liquidity_bucket is null then ''UNKNOWN'' else ''LIQ_''||liquidity_bucket::text end'
    end;
    v_classification:=case v_regime_type
      when 'SECTOR' then 'CURRENT_REGISTRY_CLASSIFICATION_NOT_HISTORICAL'
      when 'LIQUIDITY_BUCKET' then 'AS_OF_DERIVED_LIQUIDITY_QUINTILE'
      else 'AS_OF_OR_DERIVED_REGIME'
    end;

    delete from public.flow_factor_regime_effects_v4
    where discovery_as_of=v_asof and discovery_contract='FACTOR_DISCOVERY_V4_1'
      and factor_name=p_factor_name and horizon_days=p_horizon_days
      and regime_type=v_regime_type;

    v_sql:=format($q$
      with base as (
        select %1$I::double precision as factor_value,
               %2$I::double precision as ret,
               %3$s as regime_value
        from public.flow_phase4c_work_base_v4
        where %1$I is not null and %2$I is not null
      ), ranked as (
        select *,case when %4$L='EVENT'
          then case when factor_value>0 then 5 else 1 end
          else ntile(5) over(partition by regime_value order by factor_value) end as q
        from base where regime_value<>'UNKNOWN'
      ), ag as (
        select regime_value,count(*)::integer as n,
          count(*) filter(where q=1)::integer as low_n,
          count(*) filter(where q=5)::integer as high_n,
          avg(ret) filter(where q=1) as low_mean,
          avg(ret) filter(where q=5) as high_mean,
          stddev_samp(ret) filter(where q=1) as low_sd,
          stddev_samp(ret) filter(where q=5) as high_sd
        from ranked group by regime_value
      )
      insert into public.flow_factor_regime_effects_v4(
        discovery_as_of,discovery_contract,factor_name,horizon_days,regime_type,regime_value,
        sample_count,bottom_quintile_count,top_quintile_count,bottom_mean_return_pct,
        top_mean_return_pct,top_minus_bottom_return_pct,top_clean_target_rate_pct,
        effect_z,p_value,direction_matches_all,classification_state,source_verified,provenance_state)
      select %5$L::date,'FACTOR_DISCOVERY_V4_1',%6$L,%7$s,%8$L,regime_value,
        n,low_n,high_n,low_mean,high_mean,high_mean-low_mean,null::double precision,
        case when low_n>1 and high_n>1 and coalesce(low_sd,0)>0 and coalesce(high_sd,0)>0
          then (high_mean-low_mean)/sqrt(low_sd*low_sd/low_n+high_sd*high_sd/high_n) end,
        case when low_n>1 and high_n>1 and coalesce(low_sd,0)>0 and coalesce(high_sd,0)>0
          then public.flow_normal_two_sided_p_v4((high_mean-low_mean)/sqrt(low_sd*low_sd/low_n+high_sd*high_sd/high_n)) end,
        case when %9$s>=0 then high_mean-low_mean>=0 else high_mean-low_mean<0 end,
        %10$L,true,'LEAN_WORK_REGIME_CONDITIONING_NO_RAW_REJOIN'
      from ag where n>=200;
    $q$,p_factor_name,v_ret_col,v_regime_expr,v_kind,v_asof::text,p_factor_name,
      p_horizon_days,v_regime_type,coalesce(v_all_effect,0),v_classification);
    execute v_sql;
    get diagnostics v_rows=row_count;
    v_total:=v_total+v_rows;
  end loop;

  return jsonb_build_object('status','OK','factor',p_factor_name,'horizon_days',p_horizon_days,
    'regime_types',4,'rows_written',v_total,
    'sector_semantics','CURRENT_REGISTRY_CLASSIFICATION_NOT_HISTORICAL',
    'storage_policy','LEAN_TRANSIENT_WORK_TABLE');
end;
$$;

revoke all on function public.flow_refresh_regime_factor_work_v4(text,integer) from public,anon,authenticated;
grant execute on function public.flow_refresh_regime_factor_work_v4(text,integer) to service_role;

comment on function public.flow_refresh_regime_factor_work_v4(text,integer) is
'Phase4C regime conditioning for one factor/horizon across MARKET_REGIME, SECTOR, VOLATILITY_BUCKET, LIQUIDITY_BUCKET using the transient lean work table. Sector labels are current-registry classifications, not historical classifications.';
