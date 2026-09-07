-- Phase 4C direct regime conditioning.
-- Evaluates one factor x horizon x regime dimension directly from canonical views.
-- Sector remains current-registry classification, explicitly not historical.

create or replace function public.flow_refresh_regime_slice_v4(
  p_factor_name text,
  p_horizon_days integer,
  p_regime_type text
)
returns jsonb
language plpgsql
security invoker
set search_path=pg_catalog,public
as $$
declare
  v_asof date;
  v_kind text;
  v_ret text;
  v_winner text;
  v_winner_expr text;
  v_regime_expr text;
  v_all_effect double precision;
  v_sql text;
  v_rows integer;
begin
  select factor_kind into v_kind from public.flow_factor_catalog_v4 where factor_name=p_factor_name;
  if v_kind is null then raise exception 'Unknown Phase4C factor %',p_factor_name; end if;
  if p_horizon_days not in (5,20,60,120,250) then raise exception 'Unsupported Phase4C regime horizon %',p_horizon_days; end if;
  if p_regime_type not in ('MARKET_REGIME','SECTOR','VOLATILITY_BUCKET','LIQUIDITY_BUCKET') then
    raise exception 'Unsupported Phase4C regime type %',p_regime_type;
  end if;
  select max(as_of_date) into v_asof from public.flow_market_memory_manifest_v4 where feature_contract='MARKET_MEMORY_V4_1';
  select top_minus_bottom_return_pct into v_all_effect
  from public.flow_factor_discovery_v4
  where discovery_as_of=v_asof and factor_name=p_factor_name and horizon_days=p_horizon_days and stability_window='ALL';

  v_ret:=format('clean_forward_return_%sd_pct',p_horizon_days);
  v_winner:=case p_horizon_days when 20 then 'clean_hit_up_10pct_20d' when 60 then 'clean_hit_up_20pct_60d'
    when 120 then 'clean_hit_up_50pct_120d' when 250 then 'clean_hit_up_100pct_250d' else null end;
  v_winner_expr:=case when v_winner is null then 'null::boolean' else format('c.%I',v_winner) end;
  v_regime_expr:=case p_regime_type
    when 'MARKET_REGIME' then 'coalesce(p.broker_market_regime,''UNKNOWN'')'
    when 'SECTOR' then 'coalesce(p.sector,''UNKNOWN'')'
    when 'VOLATILITY_BUCKET' then 'coalesce(p.volatility_bucket::text,''UNKNOWN'')'
    else 'null::text' end;

  delete from public.flow_factor_regime_effects_v4
  where discovery_as_of=v_asof and discovery_contract='FACTOR_DISCOVERY_V4_1'
    and factor_name=p_factor_name and horizon_days=p_horizon_days and regime_type=p_regime_type;

  if p_regime_type='LIQUIDITY_BUCKET' then
    v_sql:=format($q$
      with raw as (
        select p.%1$I::double precision as factor_value,p.traded_value::double precision as traded_value,
               c.%2$I::double precision as ret,%3$s as winner
        from public.flow_market_learning_panel_v4 p
        join public.flow_market_learning_labels_clean_v4c c
          on c.as_of_date=p.as_of_date and c.ticker=p.ticker and c.feature_contract=p.feature_contract
        where p.feature_contract='MARKET_MEMORY_V4_1' and p.%1$I is not null and c.%2$I is not null and p.traded_value is not null
      ), liquid as (
        select *, 'LIQ_'||ntile(5) over(order by traded_value)::text as regime_value from raw
      ), ranked as (
        select *,case when %4$L='EVENT' then case when factor_value>0 then 5 else 1 end
                      else ntile(5) over(partition by regime_value order by factor_value) end as q
        from liquid
      ), ag as (
        select regime_value,count(*)::integer as n,
          count(*) filter(where q=1)::integer as low_n,count(*) filter(where q=5)::integer as high_n,
          avg(ret) filter(where q=1) as low_mean,avg(ret) filter(where q=5) as high_mean,
          stddev_samp(ret) filter(where q=1) as low_sd,stddev_samp(ret) filter(where q=5) as high_sd,
          avg(case when q=5 and winner is not null then winner::int::double precision end)*100.0 as high_target
        from ranked group by regime_value
      )
      insert into public.flow_factor_regime_effects_v4(discovery_as_of,discovery_contract,factor_name,horizon_days,regime_type,regime_value,
        sample_count,bottom_quintile_count,top_quintile_count,bottom_mean_return_pct,top_mean_return_pct,top_minus_bottom_return_pct,
        top_clean_target_rate_pct,effect_z,p_value,direction_matches_all,classification_state,source_verified,provenance_state)
      select %5$L::date,'FACTOR_DISCOVERY_V4_1',%6$L,%7$s,'LIQUIDITY_BUCKET',regime_value,n,low_n,high_n,low_mean,high_mean,high_mean-low_mean,high_target,
        case when low_n>1 and high_n>1 and coalesce(low_sd,0)>0 and coalesce(high_sd,0)>0
          then (high_mean-low_mean)/sqrt(low_sd*low_sd/low_n+high_sd*high_sd/high_n) end,
        case when low_n>1 and high_n>1 and coalesce(low_sd,0)>0 and coalesce(high_sd,0)>0
          then public.flow_normal_two_sided_p_v4((high_mean-low_mean)/sqrt(low_sd*low_sd/low_n+high_sd*high_sd/high_n)) end,
        case when %8$s>=0 then high_mean-low_mean>=0 else high_mean-low_mean<0 end,
        'AS_OF_DERIVED_LIQUIDITY_QUINTILE',true,'DIRECT_REGIME_CONDITIONING_NO_PANEL_MATERIALIZATION'
      from ag where n>=200;
    $q$,p_factor_name,v_ret,v_winner_expr,v_kind,v_asof::text,p_factor_name,p_horizon_days,coalesce(v_all_effect,0));
  else
    v_sql:=format($q$
      with base as (
        select p.%1$I::double precision as factor_value,c.%2$I::double precision as ret,%3$s as winner,%4$s as regime_value
        from public.flow_market_learning_panel_v4 p
        join public.flow_market_learning_labels_clean_v4c c
          on c.as_of_date=p.as_of_date and c.ticker=p.ticker and c.feature_contract=p.feature_contract
        where p.feature_contract='MARKET_MEMORY_V4_1' and p.%1$I is not null and c.%2$I is not null
      ), ranked as (
        select *,case when %5$L='EVENT' then case when factor_value>0 then 5 else 1 end
                      else ntile(5) over(partition by regime_value order by factor_value) end as q
        from base where regime_value<>'UNKNOWN'
      ), ag as (
        select regime_value,count(*)::integer as n,
          count(*) filter(where q=1)::integer as low_n,count(*) filter(where q=5)::integer as high_n,
          avg(ret) filter(where q=1) as low_mean,avg(ret) filter(where q=5) as high_mean,
          stddev_samp(ret) filter(where q=1) as low_sd,stddev_samp(ret) filter(where q=5) as high_sd,
          avg(case when q=5 and winner is not null then winner::int::double precision end)*100.0 as high_target
        from ranked group by regime_value
      )
      insert into public.flow_factor_regime_effects_v4(discovery_as_of,discovery_contract,factor_name,horizon_days,regime_type,regime_value,
        sample_count,bottom_quintile_count,top_quintile_count,bottom_mean_return_pct,top_mean_return_pct,top_minus_bottom_return_pct,
        top_clean_target_rate_pct,effect_z,p_value,direction_matches_all,classification_state,source_verified,provenance_state)
      select %6$L::date,'FACTOR_DISCOVERY_V4_1',%7$L,%8$s,%9$L,regime_value,n,low_n,high_n,low_mean,high_mean,high_mean-low_mean,high_target,
        case when low_n>1 and high_n>1 and coalesce(low_sd,0)>0 and coalesce(high_sd,0)>0
          then (high_mean-low_mean)/sqrt(low_sd*low_sd/low_n+high_sd*high_sd/high_n) end,
        case when low_n>1 and high_n>1 and coalesce(low_sd,0)>0 and coalesce(high_sd,0)>0
          then public.flow_normal_two_sided_p_v4((high_mean-low_mean)/sqrt(low_sd*low_sd/low_n+high_sd*high_sd/high_n)) end,
        case when %10$s>=0 then high_mean-low_mean>=0 else high_mean-low_mean<0 end,
        case when %9$L='SECTOR' then 'CURRENT_REGISTRY_CLASSIFICATION_NOT_HISTORICAL' else 'AS_OF_OR_DERIVED_REGIME' end,
        true,'DIRECT_REGIME_CONDITIONING_NO_PANEL_MATERIALIZATION'
      from ag where n>=200;
    $q$,p_factor_name,v_ret,v_winner_expr,v_regime_expr,v_kind,v_asof::text,p_factor_name,p_horizon_days,p_regime_type,coalesce(v_all_effect,0));
  end if;
  execute v_sql;
  get diagnostics v_rows=row_count;
  return jsonb_build_object('status','OK','factor',p_factor_name,'horizon_days',p_horizon_days,'regime_type',p_regime_type,
    'rows_written',v_rows,'sector_semantics','CURRENT_REGISTRY_CLASSIFICATION_NOT_HISTORICAL',
    'storage_policy','DIRECT_AGGREGATE_NO_PANEL_MATERIALIZATION');
end;
$$;
revoke all on function public.flow_refresh_regime_slice_v4(text,integer,text) from public,anon,authenticated;
grant execute on function public.flow_refresh_regime_slice_v4(text,integer,text) to service_role;

create or replace function public.flow_finalize_regime_eligibility_v4()
returns jsonb
language plpgsql
security invoker
set search_path=pg_catalog,public
as $$
declare v_asof date; v_rows integer;
begin
  select max(as_of_date) into v_asof from public.flow_market_memory_manifest_v4 where feature_contract='MARKET_MEMORY_V4_1';
  update public.flow_factor_discovery_v4 set regime_group_count=0,regime_sign_agreement_pct=null,challenger_eligible=false
  where discovery_as_of=v_asof and stability_window='ALL';
  with s as (
    select factor_name,horizon_days,
      count(*) filter(where sample_count>=200 and bottom_quintile_count>=40 and top_quintile_count>=40)::integer as groups,
      avg(case when direction_matches_all then 1.0 else 0.0 end)
        filter(where sample_count>=200 and bottom_quintile_count>=40 and top_quintile_count>=40)*100.0 as agreement
    from public.flow_factor_regime_effects_v4 where discovery_as_of=v_asof group by 1,2
  )
  update public.flow_factor_discovery_v4 f set regime_group_count=s.groups,regime_sign_agreement_pct=s.agreement,
    challenger_eligible=(f.robustness_state='ROBUST_DISCOVERY_SIGNAL' and s.groups>=6 and s.agreement>=60.0)
  from s where f.discovery_as_of=v_asof and f.stability_window='ALL' and f.factor_name=s.factor_name and f.horizon_days=s.horizon_days;
  select count(*) into v_rows from public.flow_factor_discovery_v4 where discovery_as_of=v_asof and stability_window='ALL' and challenger_eligible;
  return jsonb_build_object('status','OK','as_of_date',v_asof,'challenger_factor_rows',v_rows,
    'sector_semantics','CURRENT_REGISTRY_CLASSIFICATION_NOT_HISTORICAL');
end;
$$;
revoke all on function public.flow_finalize_regime_eligibility_v4() from public,anon,authenticated;
grant execute on function public.flow_finalize_regime_eligibility_v4() to service_role;
