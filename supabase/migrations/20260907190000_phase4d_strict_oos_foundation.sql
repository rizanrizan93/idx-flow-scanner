-- Phase 4D: strict historical OOS challenger validation.
-- Discovery remains separate from production scoring. This migration adds a
-- purged expanding walk-forward replay over the pre-registered Phase 4C factor
-- and interaction universes. It does NOT change scanner weights or actions.

create table if not exists public.flow_phase4d_walkforward_folds_v4 (
  horizon_days integer not null,
  fold_no integer not null,
  train_start_date date not null,
  train_end_date date not null,
  test_start_date date not null,
  test_end_date date not null,
  train_sessions integer not null,
  test_sessions integer not null,
  purge_sessions integer not null,
  fold_contract text not null default 'PURGED_EXPANDING_WALKFORWARD_V4D_1',
  source_verified boolean not null default true,
  created_at timestamptz not null default now(),
  primary key(horizon_days,fold_no)
);

create table if not exists public.flow_phase4d_factor_oos_v4 (
  validation_as_of date not null,
  validation_contract text not null default 'STRICT_OOS_V4D_1',
  factor_name text not null,
  factor_family text not null,
  factor_kind text not null,
  horizon_days integer not null,
  fold_no integer not null,
  train_start_date date not null,
  train_end_date date not null,
  test_start_date date not null,
  test_end_date date not null,
  train_sample_count integer not null,
  train_bottom_count integer not null,
  train_top_count integer not null,
  train_bottom_mean_return_pct double precision,
  train_top_mean_return_pct double precision,
  train_effect_pct double precision,
  train_effect_z double precision,
  train_p_value double precision,
  train_fdr_q_value double precision,
  train_effect_threshold_pct double precision not null,
  train_selected boolean not null default false,
  threshold_low double precision,
  threshold_high double precision,
  oos_sample_count integer not null,
  oos_bottom_count integer not null,
  oos_top_count integer not null,
  oos_bottom_mean_return_pct double precision,
  oos_top_mean_return_pct double precision,
  oos_effect_pct double precision,
  oos_effect_z double precision,
  oos_p_value double precision,
  signed_oos_effect_pct double precision,
  direction_matches_train boolean,
  source_verified boolean not null default true,
  provenance_state text not null default 'PURGED_TRAIN_THRESHOLDS_APPLIED_TO_HELD_OUT_PERIOD',
  calculated_at timestamptz not null default now(),
  primary key(validation_as_of,validation_contract,factor_name,horizon_days,fold_no)
);

create table if not exists public.flow_phase4d_interaction_oos_v4 (
  validation_as_of date not null,
  validation_contract text not null default 'STRICT_OOS_V4D_1',
  interaction_name text not null,
  factor_a text not null,
  factor_b text not null,
  horizon_days integer not null,
  fold_no integer not null,
  train_start_date date not null,
  train_end_date date not null,
  test_start_date date not null,
  test_end_date date not null,
  train_sample_count integer not null,
  train_high_high_count integer not null,
  train_interaction_excess_pct double precision,
  train_effect_z double precision,
  train_p_value double precision,
  train_fdr_q_value double precision,
  train_effect_threshold_pct double precision not null,
  train_selected boolean not null default false,
  factor_a_threshold double precision,
  factor_b_threshold double precision,
  oos_sample_count integer not null,
  oos_high_high_count integer not null,
  oos_interaction_excess_pct double precision,
  oos_effect_z double precision,
  oos_p_value double precision,
  signed_oos_effect_pct double precision,
  direction_matches_train boolean,
  source_verified boolean not null default true,
  provenance_state text not null default 'PREREGISTERED_PURGED_INTERACTION_OOS_NO_CARTESIAN_SEARCH',
  calculated_at timestamptz not null default now(),
  primary key(validation_as_of,validation_contract,interaction_name,horizon_days,fold_no)
);

create table if not exists public.flow_phase4d_candidate_summary_v4 (
  validation_as_of date not null,
  validation_contract text not null default 'STRICT_OOS_V4D_1',
  entity_type text not null check(entity_type in ('FACTOR','INTERACTION')),
  entity_name text not null,
  horizon_days integer not null,
  phase4c_challenger boolean not null default false,
  phase4c_robust boolean not null default false,
  strict_oos_fold_count integer not null default 0,
  train_selected_folds integer not null default 0,
  oos_direction_match_folds integer not null default 0,
  oos_direction_agreement_pct double precision,
  mean_signed_oos_effect_pct double precision,
  min_signed_oos_effect_pct double precision,
  historical_oos_pass boolean not null default false,
  historical_state text not null,
  forward_shadow_required boolean not null default true,
  production_eligible boolean not null default false,
  source_verified boolean not null default true,
  provenance_state text not null default 'PHASE4D_STRICT_OOS_SUMMARY',
  calculated_at timestamptz not null default now(),
  primary key(validation_as_of,validation_contract,entity_type,entity_name,horizon_days)
);

create table if not exists public.flow_phase4d_snapshot_v4 (
  validation_as_of date primary key,
  validation_contract text not null default 'STRICT_OOS_V4D_1',
  phase4c_discovery_as_of date not null,
  factor_oos_rows integer not null,
  interaction_oos_rows integer not null,
  factor_challenger_rows integer not null,
  factor_historical_pass_rows integer not null,
  factor_historical_fail_rows integer not null,
  factor_insufficient_history_rows integer not null,
  robust_interaction_rows integer not null,
  interaction_historical_pass_rows integer not null,
  interaction_historical_fail_rows integer not null,
  interaction_insufficient_history_rows integer not null,
  production_scoring_changed boolean not null default false,
  phase4d_gate_state text not null,
  source_verified boolean not null default true,
  provenance_state text not null default 'PHASE4D_STRICT_OOS_SNAPSHOT',
  captured_at timestamptz not null default now()
);

alter table public.flow_phase4d_walkforward_folds_v4 enable row level security;
alter table public.flow_phase4d_factor_oos_v4 enable row level security;
alter table public.flow_phase4d_interaction_oos_v4 enable row level security;
alter table public.flow_phase4d_candidate_summary_v4 enable row level security;
alter table public.flow_phase4d_snapshot_v4 enable row level security;

revoke all on public.flow_phase4d_walkforward_folds_v4 from public,anon,authenticated;
revoke all on public.flow_phase4d_factor_oos_v4 from public,anon,authenticated;
revoke all on public.flow_phase4d_interaction_oos_v4 from public,anon,authenticated;
revoke all on public.flow_phase4d_candidate_summary_v4 from public,anon,authenticated;
revoke all on public.flow_phase4d_snapshot_v4 from public,anon,authenticated;
grant select,insert,update,delete on public.flow_phase4d_walkforward_folds_v4 to service_role;
grant select,insert,update,delete on public.flow_phase4d_factor_oos_v4 to service_role;
grant select,insert,update,delete on public.flow_phase4d_interaction_oos_v4 to service_role;
grant select,insert,update,delete on public.flow_phase4d_candidate_summary_v4 to service_role;
grant select,insert,update,delete on public.flow_phase4d_snapshot_v4 to service_role;

create or replace function public.flow_build_phase4d_folds_v4()
returns jsonb
language plpgsql
security invoker
set search_path=pg_catalog,public
as $$
declare
  v_h integer;
  v_ret_col text;
  v_sql text;
  v_rows integer:=0;
begin
  delete from public.flow_phase4d_walkforward_folds_v4;
  foreach v_h in array array[5,20,60,120]
  loop
    v_ret_col:=format('clean_forward_return_%sd_pct',v_h);
    v_sql:=format($q$
      with dates as (
        select as_of_date,row_number() over(order by as_of_date)::integer rn
        from public.flow_market_memory_manifest_v4
        where feature_contract='MARKET_MEMORY_V4_1'
      ), mature as (
        select max(d.rn)::integer max_rn
        from dates d
        where exists(
          select 1 from public.flow_market_learning_labels_clean_v4c c
          where c.as_of_date=d.as_of_date and c.%1$I is not null
        )
      ), eligible as (
        select d.as_of_date,d.rn,ntile(3) over(order by d.rn)::integer fold_no
        from dates d cross join mature m
        where d.rn between (60+%2$s+1) and m.max_rn
      ), f as (
        select fold_no,min(rn)::integer test_start_rn,max(rn)::integer test_end_rn,count(*)::integer test_sessions
        from eligible group by fold_no
      )
      insert into public.flow_phase4d_walkforward_folds_v4(
        horizon_days,fold_no,train_start_date,train_end_date,test_start_date,test_end_date,
        train_sessions,test_sessions,purge_sessions)
      select %2$s,f.fold_no,
        (select min(as_of_date) from dates),
        (select as_of_date from dates where rn=f.test_start_rn-%2$s-1),
        (select as_of_date from dates where rn=f.test_start_rn),
        (select as_of_date from dates where rn=f.test_end_rn),
        f.test_start_rn-%2$s-1,f.test_sessions,%2$s
      from f
      where f.test_start_rn-%2$s-1>=60;
    $q$,v_ret_col,v_h);
    execute v_sql;
    v_rows:=v_rows+coalesce((select count(*) from public.flow_phase4d_walkforward_folds_v4 where horizon_days=v_h),0);
  end loop;
  return jsonb_build_object('status','OK','fold_rows',v_rows,'fold_contract','PURGED_EXPANDING_WALKFORWARD_V4D_1');
end;
$$;

create or replace function public.flow_refresh_phase4d_factor_oos_v4(p_factor_name text,p_horizon_days integer)
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
  v_ret_col text;
  v_threshold double precision;
  r record;
  v_sql text;
  v_written integer:=0;
begin
  select factor_family,factor_kind into v_family,v_kind
  from public.flow_factor_catalog_v4 where factor_name=p_factor_name;
  if v_family is null then raise exception 'Unknown Phase4D factor %',p_factor_name; end if;
  if p_horizon_days not in (5,20,60,120) then raise exception 'Unsupported Phase4D horizon %',p_horizon_days; end if;
  select max(as_of_date) into v_asof from public.flow_market_memory_manifest_v4 where feature_contract='MARKET_MEMORY_V4_1';
  v_ret_col:=format('clean_forward_return_%sd_pct',p_horizon_days);
  v_threshold:=case p_horizon_days when 5 then 0.40 when 20 then 1.00 when 60 then 2.00 else 4.00 end;

  delete from public.flow_phase4d_factor_oos_v4
  where validation_as_of=v_asof and factor_name=p_factor_name and horizon_days=p_horizon_days;

  drop table if exists pg_temp.flow_phase4d_factor_base;
  v_sql:=format($q$
    create temp table flow_phase4d_factor_base on commit drop as
    select p.as_of_date,p.%1$I::double precision factor_value,c.%2$I::double precision ret
    from public.flow_phase4c_factor_source_v4 p
    join public.flow_market_learning_labels_clean_v4c c
      on c.as_of_date=p.as_of_date and c.ticker=p.ticker and c.feature_contract=p.feature_contract
    where p.feature_contract='MARKET_MEMORY_V4_1' and p.%1$I is not null and c.%2$I is not null
  $q$,p_factor_name,v_ret_col);
  execute v_sql;
  analyze pg_temp.flow_phase4d_factor_base;

  for r in select * from public.flow_phase4d_walkforward_folds_v4 where horizon_days=p_horizon_days order by fold_no
  loop
    v_sql:=format($q$
      with train as (
        select factor_value,ret from pg_temp.flow_phase4d_factor_base where as_of_date between %1$L::date and %2$L::date
      ), th as (
        select case when %3$L='EVENT' then 0::double precision else percentile_cont(.10) within group(order by factor_value) end low_th,
               case when %3$L='EVENT' then 0::double precision else percentile_cont(.90) within group(order by factor_value) end high_th
        from train
      ), tr as (
        select count(*)::integer n,
          count(*) filter(where case when %3$L='EVENT' then factor_value<=0 else factor_value<=low_th end)::integer bn,
          count(*) filter(where case when %3$L='EVENT' then factor_value>0 else factor_value>=high_th end)::integer tn,
          avg(ret) filter(where case when %3$L='EVENT' then factor_value<=0 else factor_value<=low_th end) bot,
          avg(ret) filter(where case when %3$L='EVENT' then factor_value>0 else factor_value>=high_th end) top,
          stddev_samp(ret) filter(where case when %3$L='EVENT' then factor_value<=0 else factor_value<=low_th end) bsd,
          stddev_samp(ret) filter(where case when %3$L='EVENT' then factor_value>0 else factor_value>=high_th end) tsd
        from train cross join th
      ), test as (
        select factor_value,ret from pg_temp.flow_phase4d_factor_base where as_of_date between %4$L::date and %5$L::date
      ), te as (
        select count(*)::integer n,
          count(*) filter(where case when %3$L='EVENT' then factor_value<=0 else factor_value<=low_th end)::integer bn,
          count(*) filter(where case when %3$L='EVENT' then factor_value>0 else factor_value>=high_th end)::integer tn,
          avg(ret) filter(where case when %3$L='EVENT' then factor_value<=0 else factor_value<=low_th end) bot,
          avg(ret) filter(where case when %3$L='EVENT' then factor_value>0 else factor_value>=high_th end) top,
          stddev_samp(ret) filter(where case when %3$L='EVENT' then factor_value<=0 else factor_value<=low_th end) bsd,
          stddev_samp(ret) filter(where case when %3$L='EVENT' then factor_value>0 else factor_value>=high_th end) tsd
        from test cross join th
      )
      insert into public.flow_phase4d_factor_oos_v4(
        validation_as_of,factor_name,factor_family,factor_kind,horizon_days,fold_no,
        train_start_date,train_end_date,test_start_date,test_end_date,
        train_sample_count,train_bottom_count,train_top_count,train_bottom_mean_return_pct,train_top_mean_return_pct,
        train_effect_pct,train_effect_z,train_p_value,train_effect_threshold_pct,threshold_low,threshold_high,
        oos_sample_count,oos_bottom_count,oos_top_count,oos_bottom_mean_return_pct,oos_top_mean_return_pct,
        oos_effect_pct,oos_effect_z,oos_p_value,signed_oos_effect_pct,direction_matches_train)
      select %6$L::date,%7$L,%8$L,%3$L,%9$s,%10$s,
        %1$L::date,%2$L::date,%4$L::date,%5$L::date,
        tr.n,tr.bn,tr.tn,tr.bot,tr.top,tr.top-tr.bot,
        case when tr.bn>1 and tr.tn>1 and coalesce(tr.bsd,0)>0 and coalesce(tr.tsd,0)>0
          then (tr.top-tr.bot)/sqrt(tr.bsd*tr.bsd/tr.bn+tr.tsd*tr.tsd/tr.tn) end,
        case when tr.bn>1 and tr.tn>1 and coalesce(tr.bsd,0)>0 and coalesce(tr.tsd,0)>0
          then public.flow_normal_two_sided_p_v4((tr.top-tr.bot)/sqrt(tr.bsd*tr.bsd/tr.bn+tr.tsd*tr.tsd/tr.tn)) end,
        %11$s,th.low_th,th.high_th,
        te.n,te.bn,te.tn,te.bot,te.top,te.top-te.bot,
        case when te.bn>1 and te.tn>1 and coalesce(te.bsd,0)>0 and coalesce(te.tsd,0)>0
          then (te.top-te.bot)/sqrt(te.bsd*te.bsd/te.bn+te.tsd*te.tsd/te.tn) end,
        case when te.bn>1 and te.tn>1 and coalesce(te.bsd,0)>0 and coalesce(te.tsd,0)>0
          then public.flow_normal_two_sided_p_v4((te.top-te.bot)/sqrt(te.bsd*te.bsd/te.bn+te.tsd*te.tsd/te.tn)) end,
        sign(coalesce(tr.top-tr.bot,0))*(te.top-te.bot),
        case when tr.top-tr.bot is null or te.top-te.bot is null then null else (tr.top-tr.bot)*(te.top-te.bot)>0 end
      from tr cross join te cross join th;
    $q$,r.train_start_date::text,r.train_end_date::text,v_kind,r.test_start_date::text,r.test_end_date::text,
      v_asof::text,p_factor_name,v_family,p_horizon_days,r.fold_no,v_threshold);
    execute v_sql;
    v_written:=v_written+1;
  end loop;
  return jsonb_build_object('status','OK','factor',p_factor_name,'horizon_days',p_horizon_days,'fold_rows',v_written,'validation_contract','STRICT_OOS_V4D_1');
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
  v_asof date;
  v_a text;
  v_b text;
  v_a_kind text;
  v_b_kind text;
  v_ret_col text;
  v_threshold double precision;
  r record;
  v_sql text;
  v_written integer:=0;
begin
  select factor_a,factor_b into v_a,v_b from public.flow_factor_interaction_catalog_v4 where interaction_name=p_interaction_name;
  if v_a is null then raise exception 'Unknown Phase4D interaction %',p_interaction_name; end if;
  if p_horizon_days not in (20,60,120) then raise exception 'Unsupported Phase4D interaction horizon %',p_horizon_days; end if;
  select factor_kind into v_a_kind from public.flow_factor_catalog_v4 where factor_name=v_a;
  select factor_kind into v_b_kind from public.flow_factor_catalog_v4 where factor_name=v_b;
  select max(as_of_date) into v_asof from public.flow_market_memory_manifest_v4 where feature_contract='MARKET_MEMORY_V4_1';
  v_ret_col:=format('clean_forward_return_%sd_pct',p_horizon_days);
  v_threshold:=case p_horizon_days when 20 then .75 when 60 then 1.50 else 2.50 end;
  delete from public.flow_phase4d_interaction_oos_v4
  where validation_as_of=v_asof and interaction_name=p_interaction_name and horizon_days=p_horizon_days;

  drop table if exists pg_temp.flow_phase4d_interaction_base;
  v_sql:=format($q$
    create temp table flow_phase4d_interaction_base on commit drop as
    select p.as_of_date,p.%1$I::double precision a,p.%2$I::double precision b,c.%3$I::double precision ret
    from public.flow_phase4c_factor_source_v4 p
    join public.flow_market_learning_labels_clean_v4c c
      on c.as_of_date=p.as_of_date and c.ticker=p.ticker and c.feature_contract=p.feature_contract
    where p.feature_contract='MARKET_MEMORY_V4_1' and p.%1$I is not null and p.%2$I is not null and c.%3$I is not null
  $q$,v_a,v_b,v_ret_col);
  execute v_sql;
  analyze pg_temp.flow_phase4d_interaction_base;

  for r in select * from public.flow_phase4d_walkforward_folds_v4 where horizon_days=p_horizon_days order by fold_no
  loop
    v_sql:=format($q$
      with train as (select a,b,ret from pg_temp.flow_phase4d_interaction_base where as_of_date between %1$L::date and %2$L::date),
      th as (
        select case when %3$L='EVENT' then 0::double precision else percentile_cont(.80) within group(order by a) end a80,
               case when %4$L='EVENT' then 0::double precision else percentile_cont(.80) within group(order by b) end b80 from train
      ), tr_tag as (
        select t.*,case when %3$L='EVENT' then a>0 else a>=a80 end ah,
          case when %4$L='EVENT' then b>0 else b>=b80 end bh from train t cross join th
      ), tr as (
        select count(*)::integer n,avg(ret) baseline,avg(ret) filter(where ah) a_high,avg(ret) filter(where bh) b_high,
          count(*) filter(where ah and bh)::integer hh_n,avg(ret) filter(where ah and bh) hh_mean,stddev_samp(ret) filter(where ah and bh) hh_sd,
          count(*) filter(where not(ah and bh))::integer rest_n,avg(ret) filter(where not(ah and bh)) rest_mean,stddev_samp(ret) filter(where not(ah and bh)) rest_sd
        from tr_tag
      ), test as (select a,b,ret from pg_temp.flow_phase4d_interaction_base where as_of_date between %5$L::date and %6$L::date),
      te_tag as (
        select t.*,case when %3$L='EVENT' then a>0 else a>=a80 end ah,
          case when %4$L='EVENT' then b>0 else b>=b80 end bh from test t cross join th
      ), te as (
        select count(*)::integer n,avg(ret) baseline,avg(ret) filter(where ah) a_high,avg(ret) filter(where bh) b_high,
          count(*) filter(where ah and bh)::integer hh_n,avg(ret) filter(where ah and bh) hh_mean,stddev_samp(ret) filter(where ah and bh) hh_sd,
          count(*) filter(where not(ah and bh))::integer rest_n,avg(ret) filter(where not(ah and bh)) rest_mean,stddev_samp(ret) filter(where not(ah and bh)) rest_sd
        from te_tag
      )
      insert into public.flow_phase4d_interaction_oos_v4(
        validation_as_of,interaction_name,factor_a,factor_b,horizon_days,fold_no,
        train_start_date,train_end_date,test_start_date,test_end_date,train_sample_count,train_high_high_count,
        train_interaction_excess_pct,train_effect_z,train_p_value,train_effect_threshold_pct,factor_a_threshold,factor_b_threshold,
        oos_sample_count,oos_high_high_count,oos_interaction_excess_pct,oos_effect_z,oos_p_value,signed_oos_effect_pct,direction_matches_train)
      select %7$L::date,%8$L,%9$L,%10$L,%11$s,%12$s,%1$L::date,%2$L::date,%5$L::date,%6$L::date,
        tr.n,tr.hh_n,tr.hh_mean-tr.a_high-tr.b_high+tr.baseline,
        case when tr.hh_n>1 and tr.rest_n>1 and coalesce(tr.hh_sd,0)>0 and coalesce(tr.rest_sd,0)>0
          then (tr.hh_mean-tr.rest_mean)/sqrt(tr.hh_sd*tr.hh_sd/tr.hh_n+tr.rest_sd*tr.rest_sd/tr.rest_n) end,
        case when tr.hh_n>1 and tr.rest_n>1 and coalesce(tr.hh_sd,0)>0 and coalesce(tr.rest_sd,0)>0
          then public.flow_normal_two_sided_p_v4((tr.hh_mean-tr.rest_mean)/sqrt(tr.hh_sd*tr.hh_sd/tr.hh_n+tr.rest_sd*tr.rest_sd/tr.rest_n)) end,
        %13$s,th.a80,th.b80,
        te.n,te.hh_n,te.hh_mean-te.a_high-te.b_high+te.baseline,
        case when te.hh_n>1 and te.rest_n>1 and coalesce(te.hh_sd,0)>0 and coalesce(te.rest_sd,0)>0
          then (te.hh_mean-te.rest_mean)/sqrt(te.hh_sd*te.hh_sd/te.hh_n+te.rest_sd*te.rest_sd/te.rest_n) end,
        case when te.hh_n>1 and te.rest_n>1 and coalesce(te.hh_sd,0)>0 and coalesce(te.rest_sd,0)>0
          then public.flow_normal_two_sided_p_v4((te.hh_mean-te.rest_mean)/sqrt(te.hh_sd*te.hh_sd/te.hh_n+te.rest_sd*te.rest_sd/te.rest_n)) end,
        sign(coalesce(tr.hh_mean-tr.a_high-tr.b_high+tr.baseline,0))*(te.hh_mean-te.a_high-te.b_high+te.baseline),
        case when tr.hh_mean-tr.a_high-tr.b_high+tr.baseline is null or te.hh_mean-te.a_high-te.b_high+te.baseline is null then null
          else (tr.hh_mean-tr.a_high-tr.b_high+tr.baseline)*(te.hh_mean-te.a_high-te.b_high+te.baseline)>0 end
      from tr cross join te cross join th;
    $q$,r.train_start_date::text,r.train_end_date::text,v_a_kind,v_b_kind,r.test_start_date::text,r.test_end_date::text,
      v_asof::text,p_interaction_name,v_a,v_b,p_horizon_days,r.fold_no,v_threshold);
    execute v_sql;
    v_written:=v_written+1;
  end loop;
  return jsonb_build_object('status','OK','interaction',p_interaction_name,'horizon_days',p_horizon_days,'fold_rows',v_written,'search_policy','PREREGISTERED_10_INTERACTIONS_NO_CARTESIAN');
end;
$$;

create or replace function public.flow_recompute_phase4d_oos_fdr_v4()
returns jsonb
language plpgsql
security invoker
set search_path=pg_catalog,public
as $$
declare v_asof date; v_f integer; v_i integer;
begin
  select max(as_of_date) into v_asof from public.flow_market_memory_manifest_v4 where feature_contract='MARKET_MEMORY_V4_1';
  with r as (
    select factor_name,horizon_days,fold_no,train_p_value,
      row_number() over(partition by horizon_days,fold_no order by train_p_value nulls last)::double precision rk,
      count(train_p_value) over(partition by horizon_days,fold_no)::double precision m
    from public.flow_phase4d_factor_oos_v4 where validation_as_of=v_asof
  )
  update public.flow_phase4d_factor_oos_v4 f set train_fdr_q_value=least(1.0,r.train_p_value*r.m/nullif(r.rk,0)),
    train_selected=(r.train_p_value is not null and least(1.0,r.train_p_value*r.m/nullif(r.rk,0))<=.10
      and abs(coalesce(f.train_effect_pct,0))>=f.train_effect_threshold_pct
      and f.train_sample_count>=1000 and f.train_bottom_count>=100 and f.train_top_count>=100)
  from r where f.validation_as_of=v_asof and f.factor_name=r.factor_name and f.horizon_days=r.horizon_days and f.fold_no=r.fold_no;

  with r as (
    select interaction_name,horizon_days,fold_no,train_p_value,
      row_number() over(partition by horizon_days,fold_no order by train_p_value nulls last)::double precision rk,
      count(train_p_value) over(partition by horizon_days,fold_no)::double precision m
    from public.flow_phase4d_interaction_oos_v4 where validation_as_of=v_asof
  )
  update public.flow_phase4d_interaction_oos_v4 x set train_fdr_q_value=least(1.0,r.train_p_value*r.m/nullif(r.rk,0)),
    train_selected=(r.train_p_value is not null and least(1.0,r.train_p_value*r.m/nullif(r.rk,0))<=.10
      and abs(coalesce(x.train_interaction_excess_pct,0))>=x.train_effect_threshold_pct
      and x.train_sample_count>=1000 and x.train_high_high_count>=100)
  from r where x.validation_as_of=v_asof and x.interaction_name=r.interaction_name and x.horizon_days=r.horizon_days and x.fold_no=r.fold_no;

  select count(*) into v_f from public.flow_phase4d_factor_oos_v4 where validation_as_of=v_asof;
  select count(*) into v_i from public.flow_phase4d_interaction_oos_v4 where validation_as_of=v_asof;
  return jsonb_build_object('status','OK','validation_as_of',v_asof,'factor_rows',v_f,'interaction_rows',v_i);
end;
$$;

create or replace function public.flow_finalize_phase4d_historical_v4()
returns jsonb
language plpgsql
security invoker
set search_path=pg_catalog,public
as $$
declare v_asof date; v_c_asof date; v_rows integer;
begin
  select max(as_of_date) into v_asof from public.flow_market_memory_manifest_v4 where feature_contract='MARKET_MEMORY_V4_1';
  select max(discovery_as_of) into v_c_asof from public.flow_factor_discovery_snapshot_v4 where phase4c_gate_state='PHASE4C_READY';
  delete from public.flow_phase4d_candidate_summary_v4 where validation_as_of=v_asof;

  insert into public.flow_phase4d_candidate_summary_v4(
    validation_as_of,entity_type,entity_name,horizon_days,phase4c_challenger,phase4c_robust,
    strict_oos_fold_count,train_selected_folds,oos_direction_match_folds,oos_direction_agreement_pct,
    mean_signed_oos_effect_pct,min_signed_oos_effect_pct,historical_oos_pass,historical_state,
    forward_shadow_required,production_eligible)
  select v_asof,'FACTOR',c.factor_name,c.horizon_days,c.challenger_eligible,(c.robustness_state='ROBUST_DISCOVERY_SIGNAL'),
    count(o.fold_no)::integer,count(*) filter(where o.train_selected)::integer,
    count(*) filter(where o.direction_matches_train)::integer,
    avg(case when o.direction_matches_train is not null then o.direction_matches_train::int::double precision end)*100.0,
    avg(o.signed_oos_effect_pct),min(o.signed_oos_effect_pct),
    case when count(o.fold_no)>=3 and count(*) filter(where o.train_selected)>=2
      and count(*) filter(where o.direction_matches_train)>=2
      and avg(o.signed_oos_effect_pct)>=case c.horizon_days when 5 then .20 when 20 then .50 when 60 then 1.00 else 2.00 end
      and min(o.signed_oos_effect_pct)>=-case c.horizon_days when 5 then .40 when 20 then 1.00 when 60 then 2.00 else 4.00 end
      then true else false end,
    case when count(o.fold_no)=0 then 'INSUFFICIENT_STRICT_OOS_HISTORY'
      when c.challenger_eligible and count(o.fold_no)>=3 and count(*) filter(where o.train_selected)>=2
        and count(*) filter(where o.direction_matches_train)>=2
        and avg(o.signed_oos_effect_pct)>=case c.horizon_days when 5 then .20 when 20 then .50 when 60 then 1.00 else 2.00 end
        and min(o.signed_oos_effect_pct)>=-case c.horizon_days when 5 then .40 when 20 then 1.00 when 60 then 2.00 else 4.00 end
        then 'HISTORICAL_OOS_PASS'
      when c.challenger_eligible then 'HISTORICAL_OOS_FAIL'
      else 'PREREGISTERED_CONTROL' end,
    c.challenger_eligible,false
  from public.flow_factor_discovery_v4 c
  left join public.flow_phase4d_factor_oos_v4 o on o.validation_as_of=v_asof and o.factor_name=c.factor_name and o.horizon_days=c.horizon_days
  where c.discovery_as_of=v_c_asof and c.stability_window='ALL'
  group by c.factor_name,c.horizon_days,c.challenger_eligible,c.robustness_state;

  insert into public.flow_phase4d_candidate_summary_v4(
    validation_as_of,entity_type,entity_name,horizon_days,phase4c_challenger,phase4c_robust,
    strict_oos_fold_count,train_selected_folds,oos_direction_match_folds,oos_direction_agreement_pct,
    mean_signed_oos_effect_pct,min_signed_oos_effect_pct,historical_oos_pass,historical_state,
    forward_shadow_required,production_eligible)
  select v_asof,'INTERACTION',c.interaction_name,c.horizon_days,(c.robustness_state='ROBUST_DISCOVERY_SIGNAL'),(c.robustness_state='ROBUST_DISCOVERY_SIGNAL'),
    count(o.fold_no)::integer,count(*) filter(where o.train_selected)::integer,
    count(*) filter(where o.direction_matches_train)::integer,
    avg(case when o.direction_matches_train is not null then o.direction_matches_train::int::double precision end)*100.0,
    avg(o.signed_oos_effect_pct),min(o.signed_oos_effect_pct),
    case when count(o.fold_no)>=3 and count(*) filter(where o.train_selected)>=2
      and count(*) filter(where o.direction_matches_train)>=2
      and avg(o.signed_oos_effect_pct)>=case c.horizon_days when 20 then .375 when 60 then .75 else 1.25 end
      and min(o.signed_oos_effect_pct)>=-case c.horizon_days when 20 then .75 when 60 then 1.50 else 2.50 end
      then true else false end,
    case when count(o.fold_no)=0 then 'INSUFFICIENT_STRICT_OOS_HISTORY'
      when c.robustness_state='ROBUST_DISCOVERY_SIGNAL' and count(o.fold_no)>=3 and count(*) filter(where o.train_selected)>=2
        and count(*) filter(where o.direction_matches_train)>=2
        and avg(o.signed_oos_effect_pct)>=case c.horizon_days when 20 then .375 when 60 then .75 else 1.25 end
        and min(o.signed_oos_effect_pct)>=-case c.horizon_days when 20 then .75 when 60 then 1.50 else 2.50 end
        then 'HISTORICAL_OOS_PASS'
      when c.robustness_state='ROBUST_DISCOVERY_SIGNAL' then 'HISTORICAL_OOS_FAIL'
      else 'PREREGISTERED_CONTROL' end,
    (c.robustness_state='ROBUST_DISCOVERY_SIGNAL'),false
  from public.flow_factor_interactions_v4 c
  left join public.flow_phase4d_interaction_oos_v4 o on o.validation_as_of=v_asof and o.interaction_name=c.interaction_name and o.horizon_days=c.horizon_days
  where c.discovery_as_of=v_c_asof and c.stability_window='ALL'
  group by c.interaction_name,c.horizon_days,c.robustness_state;

  delete from public.flow_phase4d_snapshot_v4 where validation_as_of=v_asof;
  insert into public.flow_phase4d_snapshot_v4(
    validation_as_of,phase4c_discovery_as_of,factor_oos_rows,interaction_oos_rows,factor_challenger_rows,
    factor_historical_pass_rows,factor_historical_fail_rows,factor_insufficient_history_rows,
    robust_interaction_rows,interaction_historical_pass_rows,interaction_historical_fail_rows,interaction_insufficient_history_rows,
    production_scoring_changed,phase4d_gate_state)
  select v_asof,v_c_asof,
    (select count(*) from public.flow_phase4d_factor_oos_v4 where validation_as_of=v_asof),
    (select count(*) from public.flow_phase4d_interaction_oos_v4 where validation_as_of=v_asof),
    count(*) filter(where entity_type='FACTOR' and phase4c_challenger),
    count(*) filter(where entity_type='FACTOR' and phase4c_challenger and historical_state='HISTORICAL_OOS_PASS'),
    count(*) filter(where entity_type='FACTOR' and phase4c_challenger and historical_state='HISTORICAL_OOS_FAIL'),
    count(*) filter(where entity_type='FACTOR' and phase4c_challenger and historical_state='INSUFFICIENT_STRICT_OOS_HISTORY'),
    count(*) filter(where entity_type='INTERACTION' and phase4c_robust),
    count(*) filter(where entity_type='INTERACTION' and phase4c_robust and historical_state='HISTORICAL_OOS_PASS'),
    count(*) filter(where entity_type='INTERACTION' and phase4c_robust and historical_state='HISTORICAL_OOS_FAIL'),
    count(*) filter(where entity_type='INTERACTION' and phase4c_robust and historical_state='INSUFFICIENT_STRICT_OOS_HISTORY'),
    false,
    case when (select count(*) from public.flow_phase4d_factor_oos_v4 where validation_as_of=v_asof)=252
      and (select count(*) from public.flow_phase4d_interaction_oos_v4 where validation_as_of=v_asof)=60
      then 'PHASE4D_HISTORICAL_OOS_READY' else 'PHASE4D_HISTORICAL_OOS_INCOMPLETE' end
  from public.flow_phase4d_candidate_summary_v4 where validation_as_of=v_asof;

  select count(*) into v_rows from public.flow_phase4d_candidate_summary_v4 where validation_as_of=v_asof;
  return jsonb_build_object('status','OK','validation_as_of',v_asof,'summary_rows',v_rows,
    'phase4d_gate_state',(select phase4d_gate_state from public.flow_phase4d_snapshot_v4 where validation_as_of=v_asof),
    'production_scoring_changed',false);
end;
$$;

create or replace view public.flow_phase4d_quality_summary
with (security_invoker=true) as
select * from public.flow_phase4d_snapshot_v4 where validation_as_of=(select max(validation_as_of) from public.flow_phase4d_snapshot_v4);
revoke all on public.flow_phase4d_quality_summary from public,anon,authenticated;
grant select on public.flow_phase4d_quality_summary to service_role;

revoke all on function public.flow_build_phase4d_folds_v4() from public,anon,authenticated;
revoke all on function public.flow_refresh_phase4d_factor_oos_v4(text,integer) from public,anon,authenticated;
revoke all on function public.flow_refresh_phase4d_interaction_oos_v4(text,integer) from public,anon,authenticated;
revoke all on function public.flow_recompute_phase4d_oos_fdr_v4() from public,anon,authenticated;
revoke all on function public.flow_finalize_phase4d_historical_v4() from public,anon,authenticated;
grant execute on function public.flow_build_phase4d_folds_v4() to service_role;
grant execute on function public.flow_refresh_phase4d_factor_oos_v4(text,integer) to service_role;
grant execute on function public.flow_refresh_phase4d_interaction_oos_v4(text,integer) to service_role;
grant execute on function public.flow_recompute_phase4d_oos_fdr_v4() to service_role;
grant execute on function public.flow_finalize_phase4d_historical_v4() to service_role;

comment on table public.flow_phase4d_factor_oos_v4 is 'Strict purged expanding walk-forward results across the full pre-registered Phase4C factor universe. Not production scoring.';
comment on table public.flow_phase4d_interaction_oos_v4 is 'Strict purged OOS replay for the 10 pre-registered interactions only. No Cartesian interaction search.';
comment on table public.flow_phase4d_candidate_summary_v4 is 'Historical OOS promotion screen. production_eligible remains false until untouched forward shadow evidence is sufficient.';
