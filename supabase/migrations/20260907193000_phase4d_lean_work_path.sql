-- Phase 4D performance closure: reuse the proven lean transient Phase 4C work table
-- instead of rejoining MARKET_MEMORY_V4_1 to the clean-label view for every candidate.
-- The work table is runtime-only and must be dropped after Phase 4D historical replay.

create or replace function public.flow_refresh_phase4d_factor_oos_v4(p_factor_name text,p_horizon_days integer)
returns jsonb
language plpgsql
security invoker
set search_path=pg_catalog,public
set work_mem='24MB'
as $$
declare
  v_asof date; v_family text; v_kind text; v_ret_col text; v_threshold double precision;
  r record; v_sql text; v_written integer:=0;
begin
  if to_regclass('public.flow_phase4c_work_base_v4') is null then
    raise exception 'Phase4D requires lean transient work table flow_phase4c_work_base_v4';
  end if;
  select factor_family,factor_kind into v_family,v_kind from public.flow_factor_catalog_v4 where factor_name=p_factor_name;
  if v_family is null then raise exception 'Unknown Phase4D factor %',p_factor_name; end if;
  if p_horizon_days not in (5,20,60,120) then raise exception 'Unsupported Phase4D horizon %',p_horizon_days; end if;
  select max(as_of_date) into v_asof from public.flow_market_memory_manifest_v4 where feature_contract='MARKET_MEMORY_V4_1';
  v_ret_col:=format('clean_forward_return_%sd_pct',p_horizon_days);
  v_threshold:=case p_horizon_days when 5 then .40 when 20 then 1.00 when 60 then 2.00 else 4.00 end;
  delete from public.flow_phase4d_factor_oos_v4 where validation_as_of=v_asof and factor_name=p_factor_name and horizon_days=p_horizon_days;

  drop table if exists pg_temp.flow_phase4d_factor_base;
  v_sql:=format('create temp table flow_phase4d_factor_base on commit drop as select as_of_date,%1$I::double precision factor_value,%2$I::double precision ret from public.flow_phase4c_work_base_v4 where %1$I is not null and %2$I is not null',p_factor_name,v_ret_col);
  execute v_sql;
  analyze pg_temp.flow_phase4d_factor_base;

  for r in select * from public.flow_phase4d_walkforward_folds_v4 where horizon_days=p_horizon_days order by fold_no loop
    v_sql:=format($q$
      with train as (select factor_value,ret from pg_temp.flow_phase4d_factor_base where as_of_date between %1$L::date and %2$L::date),
      th as (select case when %3$L='EVENT' then 0::double precision else percentile_cont(.10) within group(order by factor_value) end low_th,
                    case when %3$L='EVENT' then 0::double precision else percentile_cont(.90) within group(order by factor_value) end high_th from train),
      tr as (select count(*)::integer n,
          count(*) filter(where case when %3$L='EVENT' then factor_value<=0 else factor_value<=low_th end)::integer bn,
          count(*) filter(where case when %3$L='EVENT' then factor_value>0 else factor_value>=high_th end)::integer tn,
          avg(ret) filter(where case when %3$L='EVENT' then factor_value<=0 else factor_value<=low_th end) bot,
          avg(ret) filter(where case when %3$L='EVENT' then factor_value>0 else factor_value>=high_th end) top,
          stddev_samp(ret) filter(where case when %3$L='EVENT' then factor_value<=0 else factor_value<=low_th end) bsd,
          stddev_samp(ret) filter(where case when %3$L='EVENT' then factor_value>0 else factor_value>=high_th end) tsd from train cross join th),
      test as (select factor_value,ret from pg_temp.flow_phase4d_factor_base where as_of_date between %4$L::date and %5$L::date),
      te as (select count(*)::integer n,
          count(*) filter(where case when %3$L='EVENT' then factor_value<=0 else factor_value<=low_th end)::integer bn,
          count(*) filter(where case when %3$L='EVENT' then factor_value>0 else factor_value>=high_th end)::integer tn,
          avg(ret) filter(where case when %3$L='EVENT' then factor_value<=0 else factor_value<=low_th end) bot,
          avg(ret) filter(where case when %3$L='EVENT' then factor_value>0 else factor_value>=high_th end) top,
          stddev_samp(ret) filter(where case when %3$L='EVENT' then factor_value<=0 else factor_value<=low_th end) bsd,
          stddev_samp(ret) filter(where case when %3$L='EVENT' then factor_value>0 else factor_value>=high_th end) tsd from test cross join th)
      insert into public.flow_phase4d_factor_oos_v4(validation_as_of,factor_name,factor_family,factor_kind,horizon_days,fold_no,
        train_start_date,train_end_date,test_start_date,test_end_date,train_sample_count,train_bottom_count,train_top_count,
        train_bottom_mean_return_pct,train_top_mean_return_pct,train_effect_pct,train_effect_z,train_p_value,train_effect_threshold_pct,
        threshold_low,threshold_high,oos_sample_count,oos_bottom_count,oos_top_count,oos_bottom_mean_return_pct,oos_top_mean_return_pct,
        oos_effect_pct,oos_effect_z,oos_p_value,signed_oos_effect_pct,direction_matches_train)
      select %6$L::date,%7$L,%8$L,%3$L,%9$s,%10$s,%1$L::date,%2$L::date,%4$L::date,%5$L::date,
        tr.n,tr.bn,tr.tn,tr.bot,tr.top,tr.top-tr.bot,
        case when tr.bn>1 and tr.tn>1 and coalesce(tr.bsd,0)>0 and coalesce(tr.tsd,0)>0 then (tr.top-tr.bot)/sqrt(tr.bsd*tr.bsd/tr.bn+tr.tsd*tr.tsd/tr.tn) end,
        case when tr.bn>1 and tr.tn>1 and coalesce(tr.bsd,0)>0 and coalesce(tr.tsd,0)>0 then public.flow_normal_two_sided_p_v4((tr.top-tr.bot)/sqrt(tr.bsd*tr.bsd/tr.bn+tr.tsd*tr.tsd/tr.tn)) end,
        %11$s,th.low_th,th.high_th,te.n,te.bn,te.tn,te.bot,te.top,te.top-te.bot,
        case when te.bn>1 and te.tn>1 and coalesce(te.bsd,0)>0 and coalesce(te.tsd,0)>0 then (te.top-te.bot)/sqrt(te.bsd*te.bsd/te.bn+te.tsd*te.tsd/te.tn) end,
        case when te.bn>1 and te.tn>1 and coalesce(te.bsd,0)>0 and coalesce(te.tsd,0)>0 then public.flow_normal_two_sided_p_v4((te.top-te.bot)/sqrt(te.bsd*te.bsd/te.bn+te.tsd*te.tsd/te.tn)) end,
        sign(coalesce(tr.top-tr.bot,0))*(te.top-te.bot),case when tr.top-tr.bot is null or te.top-te.bot is null then null else (tr.top-tr.bot)*(te.top-te.bot)>0 end
      from tr cross join te cross join th
    $q$,r.train_start_date::text,r.train_end_date::text,v_kind,r.test_start_date::text,r.test_end_date::text,v_asof::text,p_factor_name,v_family,p_horizon_days,r.fold_no,v_threshold);
    execute v_sql; v_written:=v_written+1;
  end loop;
  return jsonb_build_object('status','OK','factor',p_factor_name,'horizon_days',p_horizon_days,'fold_rows',v_written,'storage_policy','LEAN_TRANSIENT_WORK_TABLE');
end;
$$;

create or replace function public.flow_refresh_phase4d_interaction_oos_v4(p_interaction_name text,p_horizon_days integer)
returns jsonb
language plpgsql
security invoker
set search_path=pg_catalog,public
set work_mem='24MB'
as $$
declare
  v_asof date; v_a text; v_b text; v_a_kind text; v_b_kind text; v_ret_col text; v_threshold double precision;
  r record; v_sql text; v_written integer:=0;
begin
  if to_regclass('public.flow_phase4c_work_base_v4') is null then raise exception 'Phase4D requires lean transient work table flow_phase4c_work_base_v4'; end if;
  select factor_a,factor_b into v_a,v_b from public.flow_factor_interaction_catalog_v4 where interaction_name=p_interaction_name;
  if v_a is null then raise exception 'Unknown Phase4D interaction %',p_interaction_name; end if;
  if p_horizon_days not in (20,60,120) then raise exception 'Unsupported Phase4D interaction horizon %',p_horizon_days; end if;
  select factor_kind into v_a_kind from public.flow_factor_catalog_v4 where factor_name=v_a;
  select factor_kind into v_b_kind from public.flow_factor_catalog_v4 where factor_name=v_b;
  select max(as_of_date) into v_asof from public.flow_market_memory_manifest_v4 where feature_contract='MARKET_MEMORY_V4_1';
  v_ret_col:=format('clean_forward_return_%sd_pct',p_horizon_days);
  v_threshold:=case p_horizon_days when 20 then .75 when 60 then 1.50 else 2.50 end;
  delete from public.flow_phase4d_interaction_oos_v4 where validation_as_of=v_asof and interaction_name=p_interaction_name and horizon_days=p_horizon_days;

  drop table if exists pg_temp.flow_phase4d_interaction_base;
  v_sql:=format('create temp table flow_phase4d_interaction_base on commit drop as select as_of_date,%1$I::double precision a,%2$I::double precision b,%3$I::double precision ret from public.flow_phase4c_work_base_v4 where %1$I is not null and %2$I is not null and %3$I is not null',v_a,v_b,v_ret_col);
  execute v_sql; analyze pg_temp.flow_phase4d_interaction_base;

  for r in select * from public.flow_phase4d_walkforward_folds_v4 where horizon_days=p_horizon_days order by fold_no loop
    v_sql:=format($q$
      with train as (select a,b,ret from pg_temp.flow_phase4d_interaction_base where as_of_date between %1$L::date and %2$L::date),
      th as (select case when %3$L='EVENT' then 0::double precision else percentile_cont(.80) within group(order by a) end a80,
                    case when %4$L='EVENT' then 0::double precision else percentile_cont(.80) within group(order by b) end b80 from train),
      tr_tag as (select t.*,case when %3$L='EVENT' then a>0 else a>=a80 end ah,case when %4$L='EVENT' then b>0 else b>=b80 end bh from train t cross join th),
      tr as (select count(*)::integer n,avg(ret) baseline,avg(ret) filter(where ah) a_high,avg(ret) filter(where bh) b_high,count(*) filter(where ah and bh)::integer hh_n,
          avg(ret) filter(where ah and bh) hh_mean,stddev_samp(ret) filter(where ah and bh) hh_sd,count(*) filter(where not(ah and bh))::integer rest_n,
          avg(ret) filter(where not(ah and bh)) rest_mean,stddev_samp(ret) filter(where not(ah and bh)) rest_sd from tr_tag),
      test as (select a,b,ret from pg_temp.flow_phase4d_interaction_base where as_of_date between %5$L::date and %6$L::date),
      te_tag as (select t.*,case when %3$L='EVENT' then a>0 else a>=a80 end ah,case when %4$L='EVENT' then b>0 else b>=b80 end bh from test t cross join th),
      te as (select count(*)::integer n,avg(ret) baseline,avg(ret) filter(where ah) a_high,avg(ret) filter(where bh) b_high,count(*) filter(where ah and bh)::integer hh_n,
          avg(ret) filter(where ah and bh) hh_mean,stddev_samp(ret) filter(where ah and bh) hh_sd,count(*) filter(where not(ah and bh))::integer rest_n,
          avg(ret) filter(where not(ah and bh)) rest_mean,stddev_samp(ret) filter(where not(ah and bh)) rest_sd from te_tag)
      insert into public.flow_phase4d_interaction_oos_v4(validation_as_of,interaction_name,factor_a,factor_b,horizon_days,fold_no,
        train_start_date,train_end_date,test_start_date,test_end_date,train_sample_count,train_high_high_count,train_interaction_excess_pct,
        train_effect_z,train_p_value,train_effect_threshold_pct,factor_a_threshold,factor_b_threshold,oos_sample_count,oos_high_high_count,
        oos_interaction_excess_pct,oos_effect_z,oos_p_value,signed_oos_effect_pct,direction_matches_train)
      select %7$L::date,%8$L,%9$L,%10$L,%11$s,%12$s,%1$L::date,%2$L::date,%5$L::date,%6$L::date,tr.n,tr.hh_n,tr.hh_mean-tr.a_high-tr.b_high+tr.baseline,
        case when tr.hh_n>1 and tr.rest_n>1 and coalesce(tr.hh_sd,0)>0 and coalesce(tr.rest_sd,0)>0 then (tr.hh_mean-tr.rest_mean)/sqrt(tr.hh_sd*tr.hh_sd/tr.hh_n+tr.rest_sd*tr.rest_sd/tr.rest_n) end,
        case when tr.hh_n>1 and tr.rest_n>1 and coalesce(tr.hh_sd,0)>0 and coalesce(tr.rest_sd,0)>0 then public.flow_normal_two_sided_p_v4((tr.hh_mean-tr.rest_mean)/sqrt(tr.hh_sd*tr.hh_sd/tr.hh_n+tr.rest_sd*tr.rest_sd/tr.rest_n)) end,
        %13$s,th.a80,th.b80,te.n,te.hh_n,te.hh_mean-te.a_high-te.b_high+te.baseline,
        case when te.hh_n>1 and te.rest_n>1 and coalesce(te.hh_sd,0)>0 and coalesce(te.rest_sd,0)>0 then (te.hh_mean-te.rest_mean)/sqrt(te.hh_sd*te.hh_sd/te.hh_n+te.rest_sd*te.rest_sd/te.rest_n) end,
        case when te.hh_n>1 and te.rest_n>1 and coalesce(te.hh_sd,0)>0 and coalesce(te.rest_sd,0)>0 then public.flow_normal_two_sided_p_v4((te.hh_mean-te.rest_mean)/sqrt(te.hh_sd*te.hh_sd/te.hh_n+te.rest_sd*te.rest_sd/te.rest_n)) end,
        sign(coalesce(tr.hh_mean-tr.a_high-tr.b_high+tr.baseline,0))*(te.hh_mean-te.a_high-te.b_high+te.baseline),
        case when tr.hh_mean-tr.a_high-tr.b_high+tr.baseline is null or te.hh_mean-te.a_high-te.b_high+te.baseline is null then null else (tr.hh_mean-tr.a_high-tr.b_high+tr.baseline)*(te.hh_mean-te.a_high-te.b_high+te.baseline)>0 end
      from tr cross join te cross join th
    $q$,r.train_start_date::text,r.train_end_date::text,v_a_kind,v_b_kind,r.test_start_date::text,r.test_end_date::text,v_asof::text,p_interaction_name,v_a,v_b,p_horizon_days,r.fold_no,v_threshold);
    execute v_sql; v_written:=v_written+1;
  end loop;
  return jsonb_build_object('status','OK','interaction',p_interaction_name,'horizon_days',p_horizon_days,'fold_rows',v_written,'storage_policy','LEAN_TRANSIENT_WORK_TABLE');
end;
$$;

revoke all on function public.flow_refresh_phase4d_factor_oos_v4(text,integer) from public,anon,authenticated;
revoke all on function public.flow_refresh_phase4d_interaction_oos_v4(text,integer) from public,anon,authenticated;
grant execute on function public.flow_refresh_phase4d_factor_oos_v4(text,integer) to service_role;
grant execute on function public.flow_refresh_phase4d_interaction_oos_v4(text,integer) to service_role;
