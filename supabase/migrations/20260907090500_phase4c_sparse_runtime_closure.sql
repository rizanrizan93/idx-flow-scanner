-- Phase 4C runtime closure.
-- Sparse genuine evidence must be represented as INSUFFICIENT_SAMPLE, never silently
-- disappear and never be backfilled/fabricated. Also make stability math and the
-- 5D regime target path null-safe.

create or replace function public.flow_fill_factor_placeholders_v4(p_factor_name text)
returns integer
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
  if to_regclass('pg_temp.flow_phase4c_base') is null then
    raise exception 'Phase4C temp base is not prepared';
  end if;
  select factor_family,factor_kind,factor_semantics into v_family,v_kind,v_semantics
  from public.flow_factor_catalog_v4 where factor_name=p_factor_name;
  if v_family is null then raise exception 'Unknown Phase4C factor %',p_factor_name; end if;
  select max(as_of_date) into v_asof from public.flow_market_memory_manifest_v4
  where feature_contract='MARKET_MEMORY_V4_1';

  with base as (
    select w.stability_window,h.horizon_days,h.clean_return
    from pg_temp.flow_phase4c_base b
    cross join lateral(values('ALL'::text),(b.stability_bucket::text)) w(stability_window)
    cross join lateral(values
      (5,b.clean_forward_return_5d_pct::double precision),
      (20,b.clean_forward_return_20d_pct::double precision),
      (60,b.clean_forward_return_60d_pct::double precision),
      (120,b.clean_forward_return_120d_pct::double precision),
      (250,b.clean_forward_return_250d_pct::double precision)
    ) h(horizon_days,clean_return)
  ), d as (
    select stability_window,horizon_days,count(*) filter(where clean_return is not null)::integer as outcome_n
    from base group by 1,2
  )
  insert into public.flow_factor_discovery_v4(
    discovery_as_of,discovery_contract,factor_name,factor_family,factor_kind,factor_semantics,
    horizon_days,stability_window,outcome_universe_count,sample_count,missingness_pct,
    robustness_state,challenger_eligible,bin_stats,source_verified,provenance_state)
  select v_asof,'FACTOR_DISCOVERY_V4_1',p_factor_name,v_family,v_kind,v_semantics,
    h.horizon_days,w.stability_window,coalesce(d.outcome_n,0),0,100.0,
    'INSUFFICIENT_SAMPLE',false,'[]'::jsonb,true,'GENUINE_EVIDENCE_ABSENT_OR_IMMATURE_NOT_FABRICATED'
  from (values(5),(20),(60),(120),(250)) h(horizon_days)
  cross join (values('ALL'::text),('EARLY'),('MIDDLE'),('RECENT')) w(stability_window)
  left join d on d.horizon_days=h.horizon_days and d.stability_window=w.stability_window
  on conflict(discovery_as_of,discovery_contract,factor_name,horizon_days,stability_window) do nothing;
  get diagnostics v_rows=row_count;
  return v_rows;
end;
$$;
revoke all on function public.flow_fill_factor_placeholders_v4(text) from public,anon,authenticated;
grant execute on function public.flow_fill_factor_placeholders_v4(text) to service_role;

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
  v_base:=public.flow_prepare_phase4c_temp_v4();
  for r in select factor_name from public.flow_factor_catalog_v4 where factor_family=p_factor_family order by factor_name loop
    v_rows:=v_rows+public.flow_refresh_factor_discovery_one_v4(r.factor_name);
    v_placeholders:=v_placeholders+public.flow_fill_factor_placeholders_v4(r.factor_name);
    v_factor_count:=v_factor_count+1;
  end loop;
  perform public.flow_recompute_phase4c_fdr_v4();
  return jsonb_build_object('status','OK','family',p_factor_family,'base_rows',v_base,
    'factors',v_factor_count,'measured_rows',v_rows,'insufficient_placeholders',v_placeholders);
end;
$$;
revoke all on function public.flow_refresh_factor_family_v4(text) from public,anon,authenticated;
grant execute on function public.flow_refresh_factor_family_v4(text) to service_role;

create or replace function public.flow_recompute_phase4c_fdr_v4()
returns jsonb
language plpgsql
security invoker
set search_path=pg_catalog,public
as $$
declare v_asof date; v_factor_rows integer; v_interaction_rows integer;
begin
  select max(as_of_date) into v_asof from public.flow_market_memory_manifest_v4 where feature_contract='MARKET_MEMORY_V4_1';
  with ranked as (
    select discovery_as_of,discovery_contract,factor_name,horizon_days,stability_window,p_value,
      row_number() over(partition by discovery_as_of,discovery_contract,horizon_days,stability_window order by p_value nulls last,factor_name) as r,
      count(p_value) over(partition by discovery_as_of,discovery_contract,horizon_days,stability_window) as m
    from public.flow_factor_discovery_v4 where discovery_as_of=v_asof
  ), raw as (
    select *,least(1.0,p_value*m/nullif(r,0)) as raw_q from ranked where p_value is not null
  ), adj as (
    select *,least(1.0,min(raw_q) over(partition by discovery_as_of,discovery_contract,horizon_days,stability_window order by r desc rows between unbounded preceding and current row)) as q
    from raw
  )
  update public.flow_factor_discovery_v4 f set fdr_q_value=a.q
  from adj a where f.discovery_as_of=a.discovery_as_of and f.discovery_contract=a.discovery_contract
    and f.factor_name=a.factor_name and f.horizon_days=a.horizon_days and f.stability_window=a.stability_window;

  update public.flow_factor_discovery_v4 f
  set robustness_state=case
    when f.sample_count<1000 or coalesce(f.bottom_bin_count,0)<100 or coalesce(f.top_bin_count,0)<100 then 'INSUFFICIENT_SAMPLE'
    when f.fdr_q_value<=0.10 and abs(f.top_minus_bottom_return_pct)>=case f.horizon_days when 5 then 0.40 when 20 then 1.00 when 60 then 2.00 when 120 then 4.00 else 8.00 end then 'SCREENED_EFFECT'
    else 'NO_ROBUST_EFFECT' end
  where f.discovery_as_of=v_asof;

  with w as (
    select factor_name,horizon_days,
      count(*) filter(where stability_window<>'ALL' and robustness_state<>'INSUFFICIENT_SAMPLE')::integer as valid_windows,
      count(*) filter(where stability_window<>'ALL' and robustness_state<>'INSUFFICIENT_SAMPLE' and top_minus_bottom_return_pct>0)::integer as pos_windows,
      count(*) filter(where stability_window<>'ALL' and robustness_state<>'INSUFFICIENT_SAMPLE' and top_minus_bottom_return_pct<0)::integer as neg_windows
    from public.flow_factor_discovery_v4 where discovery_as_of=v_asof group by 1,2
  )
  update public.flow_factor_discovery_v4 f set
    stability_windows=w.valid_windows,
    stability_sign_agreement_pct=case when w.valid_windows>0 then 100.0*greatest(w.pos_windows,w.neg_windows)/nullif(w.valid_windows,0) end,
    robustness_state=case
      when f.robustness_state='SCREENED_EFFECT' and w.valid_windows>=2
        and 100.0*greatest(w.pos_windows,w.neg_windows)/nullif(w.valid_windows,0)>=66.6667 then 'ROBUST_DISCOVERY_SIGNAL'
      when f.robustness_state='SCREENED_EFFECT' then 'INSUFFICIENT_STABILITY'
      else f.robustness_state end
  from w where f.discovery_as_of=v_asof and f.stability_window='ALL' and f.factor_name=w.factor_name and f.horizon_days=w.horizon_days;

  with ranked as (
    select discovery_as_of,discovery_contract,interaction_name,horizon_days,stability_window,p_value,
      row_number() over(partition by discovery_as_of,discovery_contract,horizon_days,stability_window order by p_value nulls last,interaction_name) as r,
      count(p_value) over(partition by discovery_as_of,discovery_contract,horizon_days,stability_window) as m
    from public.flow_factor_interactions_v4 where discovery_as_of=v_asof
  ), raw as (
    select *,least(1.0,p_value*m/nullif(r,0)) as raw_q from ranked where p_value is not null
  ), adj as (
    select *,least(1.0,min(raw_q) over(partition by discovery_as_of,discovery_contract,horizon_days,stability_window order by r desc rows between unbounded preceding and current row)) as q
    from raw
  )
  update public.flow_factor_interactions_v4 i set fdr_q_value=a.q
  from adj a where i.discovery_as_of=a.discovery_as_of and i.discovery_contract=a.discovery_contract
    and i.interaction_name=a.interaction_name and i.horizon_days=a.horizon_days and i.stability_window=a.stability_window;

  update public.flow_factor_interactions_v4 i set robustness_state=case
    when i.sample_count<1000 or i.high_high_count<100 then 'INSUFFICIENT_SAMPLE'
    when i.fdr_q_value<=0.10 and abs(i.interaction_excess_return_pct)>=case i.horizon_days when 20 then 0.75 when 60 then 1.50 else 2.50 end then 'SCREENED_EFFECT'
    else 'NO_ROBUST_EFFECT' end
  where i.discovery_as_of=v_asof;

  with w as (
    select interaction_name,horizon_days,
      count(*) filter(where stability_window<>'ALL' and robustness_state<>'INSUFFICIENT_SAMPLE')::integer as valid_windows,
      count(*) filter(where stability_window<>'ALL' and robustness_state<>'INSUFFICIENT_SAMPLE' and interaction_excess_return_pct>0)::integer as pos_windows,
      count(*) filter(where stability_window<>'ALL' and robustness_state<>'INSUFFICIENT_SAMPLE' and interaction_excess_return_pct<0)::integer as neg_windows
    from public.flow_factor_interactions_v4 where discovery_as_of=v_asof group by 1,2
  )
  update public.flow_factor_interactions_v4 i set
    stability_windows=w.valid_windows,
    stability_sign_agreement_pct=case when w.valid_windows>0 then 100.0*greatest(w.pos_windows,w.neg_windows)/nullif(w.valid_windows,0) end,
    robustness_state=case
      when i.robustness_state='SCREENED_EFFECT' and w.valid_windows>=2
        and 100.0*greatest(w.pos_windows,w.neg_windows)/nullif(w.valid_windows,0)>=66.6667 then 'ROBUST_DISCOVERY_SIGNAL'
      when i.robustness_state='SCREENED_EFFECT' then 'INSUFFICIENT_STABILITY'
      else i.robustness_state end
  from w where i.discovery_as_of=v_asof and i.stability_window='ALL' and i.interaction_name=w.interaction_name and i.horizon_days=w.horizon_days;

  select count(*) into v_factor_rows from public.flow_factor_discovery_v4 where discovery_as_of=v_asof;
  select count(*) into v_interaction_rows from public.flow_factor_interactions_v4 where discovery_as_of=v_asof;
  return jsonb_build_object('status','OK','as_of_date',v_asof,'factor_rows',v_factor_rows,'interaction_rows',v_interaction_rows);
end;
$$;
revoke all on function public.flow_recompute_phase4c_fdr_v4() from public,anon,authenticated;
grant execute on function public.flow_recompute_phase4c_fdr_v4() to service_role;

alter function public.flow_refresh_interactions_v4() rename to flow_refresh_interactions_core_v4;
revoke all on function public.flow_refresh_interactions_core_v4() from public,anon,authenticated;
grant execute on function public.flow_refresh_interactions_core_v4() to service_role;

create or replace function public.flow_fill_interaction_placeholders_v4()
returns integer
language plpgsql
security invoker
set search_path=pg_catalog,public
as $$
declare v_asof date; v_rows integer;
begin
  select max(as_of_date) into v_asof from public.flow_market_memory_manifest_v4 where feature_contract='MARKET_MEMORY_V4_1';
  insert into public.flow_factor_interactions_v4(
    discovery_as_of,discovery_contract,interaction_name,factor_a,factor_b,horizon_days,stability_window,
    sample_count,high_high_count,robustness_state,source_verified,provenance_state)
  select v_asof,'FACTOR_DISCOVERY_V4_1',c.interaction_name,c.factor_a,c.factor_b,h.horizon_days,w.stability_window,
    0,0,'INSUFFICIENT_SAMPLE',true,'GENUINE_INTERACTION_EVIDENCE_ABSENT_OR_IMMATURE_NOT_FABRICATED'
  from public.flow_factor_interaction_catalog_v4 c
  cross join (values(20),(60),(120)) h(horizon_days)
  cross join (values('ALL'::text),('EARLY'),('MIDDLE'),('RECENT')) w(stability_window)
  on conflict(discovery_as_of,discovery_contract,interaction_name,horizon_days,stability_window) do nothing;
  get diagnostics v_rows=row_count;
  return v_rows;
end;
$$;
revoke all on function public.flow_fill_interaction_placeholders_v4() from public,anon,authenticated;
grant execute on function public.flow_fill_interaction_placeholders_v4() to service_role;

create or replace function public.flow_refresh_interactions_v4()
returns jsonb
language plpgsql
security invoker
set search_path=pg_catalog,public
as $$
declare v_core jsonb; v_placeholders integer; v_fdr jsonb; v_asof date; v_rows integer;
begin
  v_core:=public.flow_refresh_interactions_core_v4();
  v_placeholders:=public.flow_fill_interaction_placeholders_v4();
  v_fdr:=public.flow_recompute_phase4c_fdr_v4();
  select max(as_of_date) into v_asof from public.flow_market_memory_manifest_v4 where feature_contract='MARKET_MEMORY_V4_1';
  select count(*) into v_rows from public.flow_factor_interactions_v4 where discovery_as_of=v_asof;
  return jsonb_build_object('status','OK','as_of_date',v_asof,'core',v_core,
    'insufficient_placeholders',v_placeholders,'result_rows',v_rows,'fdr',v_fdr);
end;
$$;
revoke all on function public.flow_refresh_interactions_v4() from public,anon,authenticated;
grant execute on function public.flow_refresh_interactions_v4() to service_role;

alter function public.flow_refresh_regime_effects_v4() rename to flow_refresh_regime_effects_legacy_v4;
revoke all on function public.flow_refresh_regime_effects_legacy_v4() from public,anon,authenticated;
grant execute on function public.flow_refresh_regime_effects_legacy_v4() to service_role;

create or replace function public.flow_refresh_regime_effects_v4()
returns jsonb
language plpgsql
security invoker
set search_path=pg_catalog,public
as $$
declare
  c record; rg text; v_asof date; v_base integer; v_sql text; v_rows integer:=0; v_n integer;
  v_regime_expr text; v_ret_col text; v_target_col text; v_target_expr text;
begin
  v_base:=public.flow_prepare_phase4c_temp_v4();
  select max(as_of_date) into v_asof from public.flow_market_memory_manifest_v4 where feature_contract='MARKET_MEMORY_V4_1';
  delete from public.flow_factor_regime_effects_v4 where discovery_as_of=v_asof and discovery_contract='FACTOR_DISCOVERY_V4_1';
  update public.flow_factor_discovery_v4 set regime_group_count=0,regime_sign_agreement_pct=null,challenger_eligible=false
  where discovery_as_of=v_asof and stability_window='ALL';

  for c in
    with ranked as (
      select f.*,row_number() over(partition by horizon_days order by abs(top_minus_bottom_return_pct) desc nulls last,factor_name) as rn
      from public.flow_factor_discovery_v4 f
      where discovery_as_of=v_asof and stability_window='ALL' and horizon_days in (5,20,60,120)
        and robustness_state='ROBUST_DISCOVERY_SIGNAL'
    ) select * from ranked where rn<=4
  loop
    v_ret_col:=case c.horizon_days when 5 then 'clean_forward_return_5d_pct' when 20 then 'clean_forward_return_20d_pct'
      when 60 then 'clean_forward_return_60d_pct' else 'clean_forward_return_120d_pct' end;
    v_target_col:=case c.horizon_days when 20 then 'clean_hit_up_10pct_20d' when 60 then 'clean_hit_up_20pct_60d'
      when 120 then 'clean_hit_up_50pct_120d' else null end;
    v_target_expr:=case when v_target_col is null then 'null::boolean' else format('%I',v_target_col) end;

    foreach rg in array array['MARKET_REGIME','SECTOR','VOLATILITY_BUCKET','LIQUIDITY_BUCKET'] loop
      v_regime_expr:=case rg
        when 'MARKET_REGIME' then 'coalesce(broker_market_regime,''UNKNOWN'')'
        when 'SECTOR' then 'coalesce(sector,''UNKNOWN'')'
        when 'VOLATILITY_BUCKET' then 'coalesce(volatility_bucket::text,''UNKNOWN'')'
        else '''LIQ_''||liquidity_bucket::text' end;
      v_sql:=format($q$
        with base as (
          select %1$I::double precision as factor_value,%2$I::double precision as ret,%3$s as regime_value,%4$s as winner
          from pg_temp.flow_phase4c_base
          where %1$I is not null and %2$I is not null
        ), ranked as (
          select *,ntile(5) over(partition by regime_value order by factor_value) as q
          from base where regime_value<>'UNKNOWN'
        ), ag as (
          select regime_value,count(*)::integer as n,
            count(*) filter(where q=1)::integer as low_n,count(*) filter(where q=5)::integer as high_n,
            avg(ret) filter(where q=1) as low_mean,avg(ret) filter(where q=5) as high_mean,
            stddev_samp(ret) filter(where q=1) as low_sd,stddev_samp(ret) filter(where q=5) as high_sd,
            avg(case when q=5 and winner is not null then winner::int::double precision end)*100.0 as high_target
          from ranked group by regime_value
        )
        insert into public.flow_factor_regime_effects_v4(discovery_as_of,factor_name,horizon_days,regime_type,regime_value,
          sample_count,bottom_quintile_count,top_quintile_count,bottom_mean_return_pct,top_mean_return_pct,top_minus_bottom_return_pct,
          top_clean_target_rate_pct,effect_z,p_value,direction_matches_all,classification_state)
        select %5$L::date,%6$L,%7$s,%8$L,regime_value,n,low_n,high_n,low_mean,high_mean,high_mean-low_mean,high_target,
          case when low_n>1 and high_n>1 and coalesce(low_sd,0)>0 and coalesce(high_sd,0)>0
            then (high_mean-low_mean)/sqrt(low_sd*low_sd/low_n+high_sd*high_sd/high_n) end,
          case when low_n>1 and high_n>1 and coalesce(low_sd,0)>0 and coalesce(high_sd,0)>0
            then public.flow_normal_two_sided_p_v4((high_mean-low_mean)/sqrt(low_sd*low_sd/low_n+high_sd*high_sd/high_n)) end,
          case when %9$s>=0 then high_mean-low_mean>=0 else high_mean-low_mean<0 end,
          case when %8$L='SECTOR' then 'CURRENT_REGISTRY_CLASSIFICATION_NOT_HISTORICAL' else 'AS_OF_OR_DERIVED_REGIME' end
        from ag where n>=200;
      $q$,c.factor_name,v_ret_col,v_regime_expr,v_target_expr,v_asof::text,c.factor_name,c.horizon_days,rg,coalesce(c.top_minus_bottom_return_pct,0));
      execute v_sql;
      get diagnostics v_n=row_count;
      v_rows:=v_rows+v_n;
    end loop;
  end loop;

  with s as (
    select r.factor_name,r.horizon_days,
      count(*) filter(where sample_count>=200 and bottom_quintile_count>=40 and top_quintile_count>=40)::integer as groups,
      avg(case when direction_matches_all then 1.0 else 0.0 end)
        filter(where sample_count>=200 and bottom_quintile_count>=40 and top_quintile_count>=40)*100.0 as agreement
    from public.flow_factor_regime_effects_v4 r where r.discovery_as_of=v_asof group by 1,2
  )
  update public.flow_factor_discovery_v4 f set regime_group_count=s.groups,regime_sign_agreement_pct=s.agreement,
    challenger_eligible=(f.robustness_state='ROBUST_DISCOVERY_SIGNAL' and s.groups>=6 and s.agreement>=60.0)
  from s where f.discovery_as_of=v_asof and f.stability_window='ALL' and f.factor_name=s.factor_name and f.horizon_days=s.horizon_days;

  return jsonb_build_object('status','OK','as_of_date',v_asof,'base_rows',v_base,'regime_rows',v_rows,
    'sector_semantics','CURRENT_REGISTRY_CLASSIFICATION_NOT_HISTORICAL');
end;
$$;
revoke all on function public.flow_refresh_regime_effects_v4() from public,anon,authenticated;
grant execute on function public.flow_refresh_regime_effects_v4() to service_role;

comment on function public.flow_fill_factor_placeholders_v4(text) is
'Phase4C sparse-history closure: records zero-sample factor/horizon/windows explicitly as insufficient; never fabricates historical advanced evidence.';
comment on function public.flow_refresh_interactions_v4() is
'Phase4C complete bounded interaction refresh. Missing genuine histories become zero-sample INSUFFICIENT_SAMPLE rows.';
