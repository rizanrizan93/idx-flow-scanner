-- Phase 4D untouched forward-shadow framework.
-- Freeze cutoff and thresholds before any post-cutoff outcomes are observed.
-- This remains discovery/shadow only and does NOT change production scoring.

create table if not exists public.flow_phase4d_shadow_factor_thresholds_v4 (
  freeze_cutoff_date date not null,
  factor_name text not null,
  factor_kind text not null,
  p10 double precision,
  p80 double precision,
  p90 double precision,
  source_count integer not null,
  source_min_date date,
  source_max_date date,
  threshold_contract text not null default 'PRE_CUTOFF_FEATURE_ONLY_THRESHOLDS_V4D_1',
  source_verified boolean not null default true,
  frozen_at timestamptz not null default now(),
  primary key(freeze_cutoff_date,factor_name)
);

create table if not exists public.flow_phase4d_shadow_registry_v4 (
  freeze_cutoff_date date not null,
  shadow_contract text not null default 'UNTOUCHED_FORWARD_SHADOW_V4D_1',
  entity_type text not null check(entity_type in ('FACTOR','INTERACTION')),
  entity_name text not null,
  horizon_days integer not null,
  historical_state text not null,
  shadow_track_state text not null check(shadow_track_state in ('ACTIVE_HISTORICAL_PASS','ACTIVE_PROVISIONAL_120D')),
  factor_a text,
  factor_b text,
  factor_kind text,
  factor_a_kind text,
  factor_b_kind text,
  threshold_low double precision,
  threshold_high double precision,
  factor_a_threshold double precision,
  factor_b_threshold double precision,
  direction_sign smallint not null check(direction_sign in (-1,1)),
  direction_source text not null default 'PHASE4C_ALL_DISCOVERY_SIGN_PRE_CUTOFF',
  threshold_source_min_date date,
  threshold_source_max_date date not null,
  source_verified boolean not null default true,
  frozen_at timestamptz not null default now(),
  primary key(freeze_cutoff_date,entity_type,entity_name,horizon_days)
);

create table if not exists public.flow_phase4d_shadow_observations_v4 (
  as_of_date date not null,
  freeze_cutoff_date date not null,
  shadow_contract text not null default 'UNTOUCHED_FORWARD_SHADOW_V4D_1',
  entity_type text not null,
  entity_name text not null,
  horizon_days integer not null,
  source_feature_contract text not null default 'MARKET_MEMORY_V4_1',
  source_row_count integer not null,
  cohort_1_count integer not null default 0,
  cohort_2_count integer not null default 0,
  cohort_3_count integer not null default 0,
  cohort_4_count integer not null default 0,
  cohort_schema text not null,
  cohort_payload jsonb not null,
  payload_hash text not null,
  capture_state text not null default 'CAPTURED_FROZEN_COHORT',
  source_verified boolean not null default true,
  captured_at timestamptz not null default now(),
  primary key(as_of_date,freeze_cutoff_date,entity_type,entity_name,horizon_days)
);

create table if not exists public.flow_phase4d_shadow_evaluations_v4 (
  as_of_date date not null,
  freeze_cutoff_date date not null,
  shadow_contract text not null default 'UNTOUCHED_FORWARD_SHADOW_V4D_1',
  entity_type text not null,
  entity_name text not null,
  horizon_days integer not null,
  clean_outcome_count integer not null,
  clean_coverage_pct double precision,
  cohort_1_clean_count integer not null default 0,
  cohort_2_clean_count integer not null default 0,
  cohort_3_clean_count integer not null default 0,
  cohort_4_clean_count integer not null default 0,
  cohort_1_mean_return_pct double precision,
  cohort_2_mean_return_pct double precision,
  cohort_3_mean_return_pct double precision,
  cohort_4_mean_return_pct double precision,
  realized_effect_pct double precision,
  signed_effect_pct double precision,
  direction_match boolean,
  evaluation_state text not null,
  source_verified boolean not null default true,
  provenance_state text not null default 'CLEAN_CORPORATE_ACTION_GUARDED_FORWARD_OUTCOME',
  evaluated_at timestamptz not null default now(),
  primary key(as_of_date,freeze_cutoff_date,entity_type,entity_name,horizon_days)
);

create table if not exists public.flow_phase4d_shadow_candidate_state_v4 (
  freeze_cutoff_date date not null,
  entity_type text not null,
  entity_name text not null,
  horizon_days integer not null,
  historical_state text not null,
  captured_sessions integer not null default 0,
  matured_sessions integer not null default 0,
  valid_sessions integer not null default 0,
  required_valid_sessions integer not null,
  direction_match_sessions integer not null default 0,
  direction_agreement_pct double precision,
  mean_signed_effect_pct double precision,
  min_signed_effect_pct double precision,
  forward_shadow_pass boolean not null default false,
  forward_shadow_state text not null,
  promotion_ready boolean not null default false,
  production_eligible boolean not null default false,
  last_observation_date date,
  last_evaluation_date date,
  source_verified boolean not null default true,
  provenance_state text not null default 'PHASE4D_UNTOUCHED_FORWARD_SHADOW_STATE',
  calculated_at timestamptz not null default now(),
  primary key(freeze_cutoff_date,entity_type,entity_name,horizon_days)
);

create table if not exists public.flow_phase4d_shadow_snapshot_v4 (
  freeze_cutoff_date date primary key,
  shadow_contract text not null default 'UNTOUCHED_FORWARD_SHADOW_V4D_1',
  active_candidate_rows integer not null,
  historical_pass_rows integer not null,
  provisional_120d_rows integer not null,
  observation_rows integer not null,
  evaluation_rows integer not null,
  shadow_pass_rows integer not null,
  shadow_fail_rows integer not null,
  promotion_ready_rows integer not null,
  latest_observation_date date,
  latest_evaluation_date date,
  production_scoring_changed boolean not null default false,
  phase4d_shadow_gate_state text not null,
  source_verified boolean not null default true,
  provenance_state text not null default 'PHASE4D_UNTOUCHED_FORWARD_SHADOW_SNAPSHOT',
  captured_at timestamptz not null default now()
);

alter table public.flow_phase4d_shadow_factor_thresholds_v4 enable row level security;
alter table public.flow_phase4d_shadow_registry_v4 enable row level security;
alter table public.flow_phase4d_shadow_observations_v4 enable row level security;
alter table public.flow_phase4d_shadow_evaluations_v4 enable row level security;
alter table public.flow_phase4d_shadow_candidate_state_v4 enable row level security;
alter table public.flow_phase4d_shadow_snapshot_v4 enable row level security;

revoke all on public.flow_phase4d_shadow_factor_thresholds_v4 from public,anon,authenticated;
revoke all on public.flow_phase4d_shadow_registry_v4 from public,anon,authenticated;
revoke all on public.flow_phase4d_shadow_observations_v4 from public,anon,authenticated;
revoke all on public.flow_phase4d_shadow_evaluations_v4 from public,anon,authenticated;
revoke all on public.flow_phase4d_shadow_candidate_state_v4 from public,anon,authenticated;
revoke all on public.flow_phase4d_shadow_snapshot_v4 from public,anon,authenticated;

grant select,insert,update,delete on public.flow_phase4d_shadow_factor_thresholds_v4 to service_role;
grant select,insert,update,delete on public.flow_phase4d_shadow_registry_v4 to service_role;
grant select,insert,update,delete on public.flow_phase4d_shadow_observations_v4 to service_role;
grant select,insert,update,delete on public.flow_phase4d_shadow_evaluations_v4 to service_role;
grant select,insert,update,delete on public.flow_phase4d_shadow_candidate_state_v4 to service_role;
grant select,insert,update,delete on public.flow_phase4d_shadow_snapshot_v4 to service_role;

create or replace function public.flow_freeze_phase4d_shadow_factor_threshold_v4(p_factor_name text,p_cutoff date)
returns jsonb
language plpgsql
security invoker
set search_path=pg_catalog,public
set work_mem='24MB'
as $$
declare
  v_kind text;
  v_n integer;
  v_min date;
  v_max date;
  v_p10 double precision;
  v_p80 double precision;
  v_p90 double precision;
  v_sql text;
begin
  if exists(select 1 from public.flow_phase4d_shadow_factor_thresholds_v4 where freeze_cutoff_date=p_cutoff and factor_name=p_factor_name) then
    return jsonb_build_object('status','ALREADY_FROZEN','factor',p_factor_name,'cutoff',p_cutoff);
  end if;
  select factor_kind into v_kind from public.flow_factor_catalog_v4 where factor_name=p_factor_name;
  if v_kind is null then raise exception 'Unknown Phase4D shadow factor %',p_factor_name; end if;
  v_sql:=format($q$
    select count(*)::integer,min(as_of_date),max(as_of_date),
      case when %1$L='EVENT' then 0::double precision else percentile_cont(.10) within group(order by %2$I::double precision) end,
      case when %1$L='EVENT' then 0::double precision else percentile_cont(.80) within group(order by %2$I::double precision) end,
      case when %1$L='EVENT' then 0::double precision else percentile_cont(.90) within group(order by %2$I::double precision) end
    from public.flow_phase4c_factor_source_v4
    where feature_contract='MARKET_MEMORY_V4_1' and as_of_date<=%3$L::date and %2$I is not null
  $q$,v_kind,p_factor_name,p_cutoff::text);
  execute v_sql into v_n,v_min,v_max,v_p10,v_p80,v_p90;
  if coalesce(v_n,0)=0 or v_max is null or v_max>p_cutoff then raise exception 'Invalid pre-cutoff threshold source for %',p_factor_name; end if;
  insert into public.flow_phase4d_shadow_factor_thresholds_v4(
    freeze_cutoff_date,factor_name,factor_kind,p10,p80,p90,source_count,source_min_date,source_max_date)
  values(p_cutoff,p_factor_name,v_kind,v_p10,v_p80,v_p90,v_n,v_min,v_max)
  on conflict do nothing;
  return jsonb_build_object('status','OK','factor',p_factor_name,'cutoff',p_cutoff,'source_count',v_n,'source_max_date',v_max);
end;
$$;

create or replace function public.flow_freeze_phase4d_shadow_registry_v4(p_cutoff date)
returns jsonb
language plpgsql
security invoker
set search_path=pg_catalog,public
as $$
declare
  v_expected integer;
  v_have integer;
begin
  if not exists(select 1 from public.flow_phase4d_snapshot_v4 where validation_as_of=p_cutoff and phase4d_gate_state='PHASE4D_HISTORICAL_OOS_READY' and not production_scoring_changed and source_verified) then
    raise exception 'Phase4D historical OOS gate not ready at cutoff %',p_cutoff;
  end if;

  with active as (
    select * from public.flow_phase4d_candidate_summary_v4
    where validation_as_of=p_cutoff
      and ((entity_type='FACTOR' and phase4c_challenger) or (entity_type='INTERACTION' and phase4c_robust))
      and historical_state in ('HISTORICAL_OOS_PASS','INSUFFICIENT_STRICT_OOS_HISTORY')
  ), needed as (
    select entity_name factor_name from active where entity_type='FACTOR'
    union
    select c.factor_a from active a join public.flow_factor_interaction_catalog_v4 c on c.interaction_name=a.entity_name where a.entity_type='INTERACTION'
    union
    select c.factor_b from active a join public.flow_factor_interaction_catalog_v4 c on c.interaction_name=a.entity_name where a.entity_type='INTERACTION'
  )
  select count(*),count(t.factor_name) into v_expected,v_have
  from needed n left join public.flow_phase4d_shadow_factor_thresholds_v4 t on t.freeze_cutoff_date=p_cutoff and t.factor_name=n.factor_name;
  if v_expected<>v_have then raise exception 'Frozen threshold cache incomplete at cutoff %: expected %, have %',p_cutoff,v_expected,v_have; end if;

  insert into public.flow_phase4d_shadow_registry_v4(
    freeze_cutoff_date,entity_type,entity_name,horizon_days,historical_state,shadow_track_state,
    factor_a,factor_kind,threshold_low,threshold_high,direction_sign,threshold_source_min_date,threshold_source_max_date)
  select p_cutoff,'FACTOR',s.entity_name,s.horizon_days,s.historical_state,
    case when s.historical_state='HISTORICAL_OOS_PASS' then 'ACTIVE_HISTORICAL_PASS' else 'ACTIVE_PROVISIONAL_120D' end,
    s.entity_name,t.factor_kind,t.p10,t.p90,
    case when d.top_minus_bottom_return_pct>0 then 1 else -1 end,
    t.source_min_date,t.source_max_date
  from public.flow_phase4d_candidate_summary_v4 s
  join public.flow_phase4d_shadow_factor_thresholds_v4 t on t.freeze_cutoff_date=p_cutoff and t.factor_name=s.entity_name
  join public.flow_factor_discovery_v4 d on d.discovery_as_of=p_cutoff and d.stability_window='ALL' and d.factor_name=s.entity_name and d.horizon_days=s.horizon_days
  where s.validation_as_of=p_cutoff and s.entity_type='FACTOR' and s.phase4c_challenger
    and s.historical_state in ('HISTORICAL_OOS_PASS','INSUFFICIENT_STRICT_OOS_HISTORY')
    and d.top_minus_bottom_return_pct is not null and d.top_minus_bottom_return_pct<>0
  on conflict do nothing;

  insert into public.flow_phase4d_shadow_registry_v4(
    freeze_cutoff_date,entity_type,entity_name,horizon_days,historical_state,shadow_track_state,
    factor_a,factor_b,factor_a_kind,factor_b_kind,factor_a_threshold,factor_b_threshold,
    direction_sign,threshold_source_min_date,threshold_source_max_date)
  select p_cutoff,'INTERACTION',s.entity_name,s.horizon_days,s.historical_state,
    case when s.historical_state='HISTORICAL_OOS_PASS' then 'ACTIVE_HISTORICAL_PASS' else 'ACTIVE_PROVISIONAL_120D' end,
    c.factor_a,c.factor_b,ta.factor_kind,tb.factor_kind,
    case when ta.factor_kind='EVENT' then 0 else ta.p80 end,
    case when tb.factor_kind='EVENT' then 0 else tb.p80 end,
    case when d.interaction_excess_return_pct>0 then 1 else -1 end,
    least(ta.source_min_date,tb.source_min_date),least(ta.source_max_date,tb.source_max_date)
  from public.flow_phase4d_candidate_summary_v4 s
  join public.flow_factor_interaction_catalog_v4 c on c.interaction_name=s.entity_name
  join public.flow_phase4d_shadow_factor_thresholds_v4 ta on ta.freeze_cutoff_date=p_cutoff and ta.factor_name=c.factor_a
  join public.flow_phase4d_shadow_factor_thresholds_v4 tb on tb.freeze_cutoff_date=p_cutoff and tb.factor_name=c.factor_b
  join public.flow_factor_interactions_v4 d on d.discovery_as_of=p_cutoff and d.stability_window='ALL' and d.interaction_name=s.entity_name and d.horizon_days=s.horizon_days
  where s.validation_as_of=p_cutoff and s.entity_type='INTERACTION' and s.phase4c_robust
    and s.historical_state in ('HISTORICAL_OOS_PASS','INSUFFICIENT_STRICT_OOS_HISTORY')
    and d.interaction_excess_return_pct is not null and d.interaction_excess_return_pct<>0
  on conflict do nothing;

  select count(*) into v_have from public.flow_phase4d_shadow_registry_v4 where freeze_cutoff_date=p_cutoff;
  select count(*) into v_expected from public.flow_phase4d_candidate_summary_v4
  where validation_as_of=p_cutoff
    and ((entity_type='FACTOR' and phase4c_challenger) or (entity_type='INTERACTION' and phase4c_robust))
    and historical_state in ('HISTORICAL_OOS_PASS','INSUFFICIENT_STRICT_OOS_HISTORY');
  if v_have<>v_expected then raise exception 'Shadow registry freeze incomplete at cutoff %: expected %, have %',p_cutoff,v_expected,v_have; end if;
  return jsonb_build_object('status','OK','cutoff',p_cutoff,'registry_rows',v_have,'shadow_contract','UNTOUCHED_FORWARD_SHADOW_V4D_1');
end;
$$;

create or replace function public.flow_capture_phase4d_shadow_v4(p_as_of_date date)
returns jsonb
language plpgsql
security invoker
set search_path=pg_catalog,public
set work_mem='24MB'
as $$
declare
  r record;
  v_payload jsonb;
  v_n integer;
  v_c1 integer;
  v_c2 integer;
  v_c3 integer;
  v_c4 integer;
  v_sql text;
  v_written integer:=0;
begin
  for r in select * from public.flow_phase4d_shadow_registry_v4 order by entity_type,entity_name,horizon_days
  loop
    if p_as_of_date<=r.freeze_cutoff_date then continue; end if;
    if not exists(select 1 from public.flow_market_memory_manifest_v4 m where m.as_of_date=p_as_of_date and m.feature_contract='MARKET_MEMORY_V4_1' and m.source_verified and m.stock_rows>=900 and m.residual_rows>=900) then
      continue;
    end if;
    if exists(select 1 from public.flow_phase4d_shadow_observations_v4 o where o.as_of_date=p_as_of_date and o.freeze_cutoff_date=r.freeze_cutoff_date and o.entity_type=r.entity_type and o.entity_name=r.entity_name and o.horizon_days=r.horizon_days) then
      continue;
    end if;

    if r.entity_type='FACTOR' then
      v_sql:=format($q$
        select count(*)::integer,
          count(*) filter(where case when %1$L='EVENT' then %2$I<=0 else %2$I<=%3$s end)::integer,
          count(*) filter(where case when %1$L='EVENT' then %2$I>0 else %2$I>=%4$s end)::integer,
          jsonb_build_object(
            'bottom',coalesce(jsonb_agg(ticker order by ticker) filter(where case when %1$L='EVENT' then %2$I<=0 else %2$I<=%3$s end),'[]'::jsonb),
            'top',coalesce(jsonb_agg(ticker order by ticker) filter(where case when %1$L='EVENT' then %2$I>0 else %2$I>=%4$s end),'[]'::jsonb))
        from public.flow_phase4c_factor_source_v4
        where as_of_date=%5$L::date and feature_contract='MARKET_MEMORY_V4_1' and %2$I is not null
      $q$,r.factor_kind,r.factor_a,coalesce(r.threshold_low,0),coalesce(r.threshold_high,0),p_as_of_date::text);
      execute v_sql into v_n,v_c1,v_c2,v_payload;
      v_c3:=0; v_c4:=0;
    else
      v_sql:=format($q$
        with s as (
          select ticker,
            case when %1$L='EVENT' then %2$I>0 else %2$I>=%3$s end ah,
            case when %4$L='EVENT' then %5$I>0 else %5$I>=%6$s end bh
          from public.flow_phase4c_factor_source_v4
          where as_of_date=%7$L::date and feature_contract='MARKET_MEMORY_V4_1' and %2$I is not null and %5$I is not null
        )
        select count(*)::integer,count(*) filter(where ah)::integer,count(*) filter(where bh)::integer,count(*) filter(where ah and bh)::integer,
          jsonb_build_object(
            'all',coalesce(jsonb_agg(ticker order by ticker),'[]'::jsonb),
            'a_high',coalesce(jsonb_agg(ticker order by ticker) filter(where ah),'[]'::jsonb),
            'b_high',coalesce(jsonb_agg(ticker order by ticker) filter(where bh),'[]'::jsonb),
            'hh',coalesce(jsonb_agg(ticker order by ticker) filter(where ah and bh),'[]'::jsonb))
        from s
      $q$,r.factor_a_kind,r.factor_a,coalesce(r.factor_a_threshold,0),r.factor_b_kind,r.factor_b,coalesce(r.factor_b_threshold,0),p_as_of_date::text);
      execute v_sql into v_n,v_c1,v_c2,v_c3,v_payload;
      v_c4:=v_n;
    end if;

    insert into public.flow_phase4d_shadow_observations_v4(
      as_of_date,freeze_cutoff_date,entity_type,entity_name,horizon_days,source_row_count,
      cohort_1_count,cohort_2_count,cohort_3_count,cohort_4_count,cohort_schema,cohort_payload,payload_hash)
    values(p_as_of_date,r.freeze_cutoff_date,r.entity_type,r.entity_name,r.horizon_days,coalesce(v_n,0),
      coalesce(v_c1,0),coalesce(v_c2,0),coalesce(v_c3,0),coalesce(v_c4,0),
      case when r.entity_type='FACTOR' then 'BOTTOM_TOP' else 'A_HIGH_B_HIGH_HH_ALL' end,
      coalesce(v_payload,'{}'::jsonb),encode(public.digest(coalesce(v_payload,'{}'::jsonb)::text,'sha256'),'hex'))
    on conflict do nothing;
    v_written:=v_written+1;
  end loop;
  return jsonb_build_object('status','OK','as_of_date',p_as_of_date,'observations_written',v_written);
end;
$$;

create or replace function public.flow_evaluate_phase4d_shadow_v4()
returns jsonb
language plpgsql
security invoker
set search_path=pg_catalog,public
set work_mem='24MB'
as $$
declare
  o record;
  r record;
  v_ret_col text;
  v_sql text;
  v_total integer;
  v_c1 integer; v_c2 integer; v_c3 integer; v_c4 integer;
  v_m1 double precision; v_m2 double precision; v_m3 double precision; v_m4 double precision;
  v_effect double precision;
  v_written integer:=0;
  v_state text;
begin
  for o in
    select x.* from public.flow_phase4d_shadow_observations_v4 x
    where not exists(select 1 from public.flow_phase4d_shadow_evaluations_v4 e where e.as_of_date=x.as_of_date and e.freeze_cutoff_date=x.freeze_cutoff_date and e.entity_type=x.entity_type and e.entity_name=x.entity_name and e.horizon_days=x.horizon_days)
    order by x.as_of_date,x.entity_type,x.entity_name,x.horizon_days
  loop
    select * into r from public.flow_phase4d_shadow_registry_v4
    where freeze_cutoff_date=o.freeze_cutoff_date and entity_type=o.entity_type and entity_name=o.entity_name and horizon_days=o.horizon_days;
    v_ret_col:=format('clean_forward_return_%sd_pct',o.horizon_days);
    if o.entity_type='FACTOR' then
      v_sql:=format($q$
        with ret as (select ticker,%1$I::double precision v from public.flow_market_learning_labels_clean_v4c where as_of_date=%2$L::date and %1$I is not null),
        b as (select jsonb_array_elements_text(%3$L::jsonb->'bottom') ticker),
        t as (select jsonb_array_elements_text(%3$L::jsonb->'top') ticker)
        select (select count(*) from ret)::integer,
          (select count(*) from ret join b using(ticker))::integer,
          (select count(*) from ret join t using(ticker))::integer,
          (select avg(v) from ret join b using(ticker)),
          (select avg(v) from ret join t using(ticker))
      $q$,v_ret_col,o.as_of_date::text,o.cohort_payload::text);
      execute v_sql into v_total,v_c1,v_c2,v_m1,v_m2;
      if coalesce(v_total,0)=0 then continue; end if;
      v_c3:=0; v_c4:=0; v_m3:=null; v_m4:=null;
      v_effect:=v_m2-v_m1;
      v_state:=case when coalesce(v_c1,0)>=5 and coalesce(v_c2,0)>=5 and (100.0*v_total/nullif(o.source_row_count,0))>=50 then 'MATURE_EVALUATED' else 'MATURE_LOW_COVERAGE' end;
    else
      v_sql:=format($q$
        with ret as (select ticker,%1$I::double precision v from public.flow_market_learning_labels_clean_v4c where as_of_date=%2$L::date and %1$I is not null),
        a as (select jsonb_array_elements_text(%3$L::jsonb->'a_high') ticker),
        b as (select jsonb_array_elements_text(%3$L::jsonb->'b_high') ticker),
        h as (select jsonb_array_elements_text(%3$L::jsonb->'hh') ticker),
        z as (select jsonb_array_elements_text(%3$L::jsonb->'all') ticker)
        select (select count(*) from ret join z using(ticker))::integer,
          (select count(*) from ret join a using(ticker))::integer,
          (select count(*) from ret join b using(ticker))::integer,
          (select count(*) from ret join h using(ticker))::integer,
          (select avg(v) from ret join a using(ticker)),
          (select avg(v) from ret join b using(ticker)),
          (select avg(v) from ret join h using(ticker)),
          (select avg(v) from ret join z using(ticker))
      $q$,v_ret_col,o.as_of_date::text,o.cohort_payload::text);
      execute v_sql into v_total,v_c1,v_c2,v_c3,v_m1,v_m2,v_m3,v_m4;
      if coalesce(v_total,0)=0 then continue; end if;
      v_c4:=v_total;
      v_effect:=v_m3-v_m1-v_m2+v_m4;
      v_state:=case when coalesce(v_c3,0)>=5 and coalesce(v_total,0)>=50 and (100.0*v_total/nullif(o.source_row_count,0))>=50 then 'MATURE_EVALUATED' else 'MATURE_LOW_COVERAGE' end;
    end if;

    insert into public.flow_phase4d_shadow_evaluations_v4(
      as_of_date,freeze_cutoff_date,entity_type,entity_name,horizon_days,clean_outcome_count,clean_coverage_pct,
      cohort_1_clean_count,cohort_2_clean_count,cohort_3_clean_count,cohort_4_clean_count,
      cohort_1_mean_return_pct,cohort_2_mean_return_pct,cohort_3_mean_return_pct,cohort_4_mean_return_pct,
      realized_effect_pct,signed_effect_pct,direction_match,evaluation_state)
    values(o.as_of_date,o.freeze_cutoff_date,o.entity_type,o.entity_name,o.horizon_days,v_total,
      100.0*v_total/nullif(o.source_row_count,0),coalesce(v_c1,0),coalesce(v_c2,0),coalesce(v_c3,0),coalesce(v_c4,0),
      v_m1,v_m2,v_m3,v_m4,v_effect,r.direction_sign*v_effect,case when v_effect is null then null else r.direction_sign*v_effect>0 end,v_state)
    on conflict do nothing;
    v_written:=v_written+1;
  end loop;
  return jsonb_build_object('status','OK','evaluations_written',v_written);
end;
$$;

create or replace function public.flow_finalize_phase4d_shadow_v4()
returns jsonb
language plpgsql
security invoker
set search_path=pg_catalog,public
as $$
declare
  v_cutoff date;
  v_rows integer;
begin
  select max(freeze_cutoff_date) into v_cutoff from public.flow_phase4d_shadow_registry_v4;
  if v_cutoff is null then return jsonb_build_object('status','NO_FROZEN_REGISTRY'); end if;
  delete from public.flow_phase4d_shadow_candidate_state_v4 where freeze_cutoff_date=v_cutoff;

  insert into public.flow_phase4d_shadow_candidate_state_v4(
    freeze_cutoff_date,entity_type,entity_name,horizon_days,historical_state,captured_sessions,matured_sessions,valid_sessions,
    required_valid_sessions,direction_match_sessions,direction_agreement_pct,mean_signed_effect_pct,min_signed_effect_pct,
    forward_shadow_pass,forward_shadow_state,promotion_ready,production_eligible,last_observation_date,last_evaluation_date)
  select r.freeze_cutoff_date,r.entity_type,r.entity_name,r.horizon_days,r.historical_state,
    count(distinct o.as_of_date)::integer,count(distinct e.as_of_date)::integer,
    count(distinct e.as_of_date) filter(where e.evaluation_state='MATURE_EVALUATED')::integer,
    case when r.horizon_days=5 then 20 when r.horizon_days=20 then 15 when r.horizon_days=60 then 10 else 12 end,
    count(distinct e.as_of_date) filter(where e.evaluation_state='MATURE_EVALUATED' and e.direction_match)::integer,
    100.0*count(distinct e.as_of_date) filter(where e.evaluation_state='MATURE_EVALUATED' and e.direction_match)/nullif(count(distinct e.as_of_date) filter(where e.evaluation_state='MATURE_EVALUATED'),0),
    avg(e.signed_effect_pct) filter(where e.evaluation_state='MATURE_EVALUATED'),
    min(e.signed_effect_pct) filter(where e.evaluation_state='MATURE_EVALUATED'),
    case when count(distinct e.as_of_date) filter(where e.evaluation_state='MATURE_EVALUATED') >= case when r.horizon_days=5 then 20 when r.horizon_days=20 then 15 when r.horizon_days=60 then 10 else 12 end
      and 100.0*count(distinct e.as_of_date) filter(where e.evaluation_state='MATURE_EVALUATED' and e.direction_match)/nullif(count(distinct e.as_of_date) filter(where e.evaluation_state='MATURE_EVALUATED'),0) >=60
      and avg(e.signed_effect_pct) filter(where e.evaluation_state='MATURE_EVALUATED') >= case when r.entity_type='FACTOR' then case r.horizon_days when 5 then .20 when 20 then .50 when 60 then 1.00 else 2.00 end else case r.horizon_days when 20 then .375 when 60 then .75 else 1.25 end end
      and min(e.signed_effect_pct) filter(where e.evaluation_state='MATURE_EVALUATED') >= -case when r.entity_type='FACTOR' then case r.horizon_days when 5 then .40 when 20 then 1.00 when 60 then 2.00 else 4.00 end else case r.horizon_days when 20 then .75 when 60 then 1.50 else 2.50 end end
      then true else false end,
    case
      when count(distinct o.as_of_date)=0 then 'AWAITING_FIRST_CAPTURE'
      when count(distinct e.as_of_date) filter(where e.evaluation_state='MATURE_EVALUATED')=0 then 'AWAITING_MATURITY'
      when count(distinct e.as_of_date) filter(where e.evaluation_state='MATURE_EVALUATED') < case when r.horizon_days=5 then 20 when r.horizon_days=20 then 15 when r.horizon_days=60 then 10 else 12 end then 'ACCUMULATING'
      when 100.0*count(distinct e.as_of_date) filter(where e.evaluation_state='MATURE_EVALUATED' and e.direction_match)/nullif(count(distinct e.as_of_date) filter(where e.evaluation_state='MATURE_EVALUATED'),0) >=60
        and avg(e.signed_effect_pct) filter(where e.evaluation_state='MATURE_EVALUATED') >= case when r.entity_type='FACTOR' then case r.horizon_days when 5 then .20 when 20 then .50 when 60 then 1.00 else 2.00 end else case r.horizon_days when 20 then .375 when 60 then .75 else 1.25 end end
        and min(e.signed_effect_pct) filter(where e.evaluation_state='MATURE_EVALUATED') >= -case when r.entity_type='FACTOR' then case r.horizon_days when 5 then .40 when 20 then 1.00 when 60 then 2.00 else 4.00 end else case r.horizon_days when 20 then .75 when 60 then 1.50 else 2.50 end end
        then 'FORWARD_SHADOW_PASS'
      else 'FORWARD_SHADOW_FAIL' end,
    case when r.historical_state='HISTORICAL_OOS_PASS'
      and count(distinct e.as_of_date) filter(where e.evaluation_state='MATURE_EVALUATED') >= case when r.horizon_days=5 then 20 when r.horizon_days=20 then 15 when r.horizon_days=60 then 10 else 12 end
      and 100.0*count(distinct e.as_of_date) filter(where e.evaluation_state='MATURE_EVALUATED' and e.direction_match)/nullif(count(distinct e.as_of_date) filter(where e.evaluation_state='MATURE_EVALUATED'),0) >=60
      and avg(e.signed_effect_pct) filter(where e.evaluation_state='MATURE_EVALUATED') >= case when r.entity_type='FACTOR' then case r.horizon_days when 5 then .20 when 20 then .50 when 60 then 1.00 else 2.00 end else case r.horizon_days when 20 then .375 when 60 then .75 else 1.25 end end
      and min(e.signed_effect_pct) filter(where e.evaluation_state='MATURE_EVALUATED') >= -case when r.entity_type='FACTOR' then case r.horizon_days when 5 then .40 when 20 then 1.00 when 60 then 2.00 else 4.00 end else case r.horizon_days when 20 then .75 when 60 then 1.50 else 2.50 end end
      then true else false end,
    false,max(o.as_of_date),max(e.as_of_date)
  from public.flow_phase4d_shadow_registry_v4 r
  left join public.flow_phase4d_shadow_observations_v4 o on o.freeze_cutoff_date=r.freeze_cutoff_date and o.entity_type=r.entity_type and o.entity_name=r.entity_name and o.horizon_days=r.horizon_days
  left join public.flow_phase4d_shadow_evaluations_v4 e on e.freeze_cutoff_date=r.freeze_cutoff_date and e.entity_type=r.entity_type and e.entity_name=r.entity_name and e.horizon_days=r.horizon_days and e.as_of_date=o.as_of_date
  where r.freeze_cutoff_date=v_cutoff
  group by r.freeze_cutoff_date,r.entity_type,r.entity_name,r.horizon_days,r.historical_state;

  delete from public.flow_phase4d_shadow_snapshot_v4 where freeze_cutoff_date=v_cutoff;
  insert into public.flow_phase4d_shadow_snapshot_v4(
    freeze_cutoff_date,active_candidate_rows,historical_pass_rows,provisional_120d_rows,observation_rows,evaluation_rows,
    shadow_pass_rows,shadow_fail_rows,promotion_ready_rows,latest_observation_date,latest_evaluation_date,production_scoring_changed,phase4d_shadow_gate_state)
  select v_cutoff,count(*),count(*) filter(where historical_state='HISTORICAL_OOS_PASS'),count(*) filter(where historical_state='INSUFFICIENT_STRICT_OOS_HISTORY'),
    (select count(*) from public.flow_phase4d_shadow_observations_v4 where freeze_cutoff_date=v_cutoff),
    (select count(*) from public.flow_phase4d_shadow_evaluations_v4 where freeze_cutoff_date=v_cutoff),
    count(*) filter(where forward_shadow_state='FORWARD_SHADOW_PASS'),count(*) filter(where forward_shadow_state='FORWARD_SHADOW_FAIL'),
    count(*) filter(where promotion_ready),max(last_observation_date),max(last_evaluation_date),false,
    case when count(*)<>27 then 'PHASE4D_FORWARD_SHADOW_INCOMPLETE'
      when coalesce(max(last_observation_date),v_cutoff)=v_cutoff then 'PHASE4D_FORWARD_SHADOW_ARMED'
      when count(*) filter(where promotion_ready)>0 then 'PHASE4D_FORWARD_SHADOW_PROMOTION_CANDIDATES'
      else 'PHASE4D_FORWARD_SHADOW_ACCUMULATING' end
  from public.flow_phase4d_shadow_candidate_state_v4 where freeze_cutoff_date=v_cutoff;
  select count(*) into v_rows from public.flow_phase4d_shadow_candidate_state_v4 where freeze_cutoff_date=v_cutoff;
  return jsonb_build_object('status','OK','cutoff',v_cutoff,'candidate_rows',v_rows,
    'gate',(select phase4d_shadow_gate_state from public.flow_phase4d_shadow_snapshot_v4 where freeze_cutoff_date=v_cutoff),'production_scoring_changed',false);
end;
$$;

create or replace view public.flow_phase4d_shadow_quality_summary
with (security_invoker=true) as
select * from public.flow_phase4d_shadow_snapshot_v4 where freeze_cutoff_date=(select max(freeze_cutoff_date) from public.flow_phase4d_shadow_snapshot_v4);
revoke all on public.flow_phase4d_shadow_quality_summary from public,anon,authenticated;
grant select on public.flow_phase4d_shadow_quality_summary to service_role;

revoke all on function public.flow_freeze_phase4d_shadow_factor_threshold_v4(text,date) from public,anon,authenticated;
revoke all on function public.flow_freeze_phase4d_shadow_registry_v4(date) from public,anon,authenticated;
revoke all on function public.flow_capture_phase4d_shadow_v4(date) from public,anon,authenticated;
revoke all on function public.flow_evaluate_phase4d_shadow_v4() from public,anon,authenticated;
revoke all on function public.flow_finalize_phase4d_shadow_v4() from public,anon,authenticated;
grant execute on function public.flow_freeze_phase4d_shadow_factor_threshold_v4(text,date) to service_role;
grant execute on function public.flow_freeze_phase4d_shadow_registry_v4(date) to service_role;
grant execute on function public.flow_capture_phase4d_shadow_v4(date) to service_role;
grant execute on function public.flow_evaluate_phase4d_shadow_v4() to service_role;
grant execute on function public.flow_finalize_phase4d_shadow_v4() to service_role;

comment on table public.flow_phase4d_shadow_registry_v4 is 'Immutable pre-outcome forward-shadow registry. Historical OOS failures are excluded; 120D insufficient-history candidates remain provisional and cannot become promotion_ready without historical OOS PASS.';
comment on table public.flow_phase4d_shadow_observations_v4 is 'Compressed capture-time ticker cohorts. No future outcomes are used at capture.';
comment on table public.flow_phase4d_shadow_evaluations_v4 is 'Corporate-action-guarded realized forward effects, evaluated only after clean outcomes mature.';

-- Run after the 18:24 WIB market-memory capture. pg_cron schedules are UTC.
do $$
declare j record;
begin
  for j in select jobid from cron.job where jobname in ('flow-phase4d-shadow-capture','flow-phase4d-shadow-evaluate','flow-phase4d-shadow-finalize') loop
    perform cron.unschedule(j.jobid);
  end loop;
  perform cron.schedule('flow-phase4d-shadow-capture','26 11 * * 1-5',$cmd$select public.flow_capture_phase4d_shadow_v4((now() at time zone 'Asia/Jakarta')::date);$cmd$);
  perform cron.schedule('flow-phase4d-shadow-evaluate','28 11 * * 1-5',$cmd$select public.flow_evaluate_phase4d_shadow_v4();$cmd$);
  perform cron.schedule('flow-phase4d-shadow-finalize','29 11 * * 1-5',$cmd$select public.flow_finalize_phase4d_shadow_v4();$cmd$);
end;
$$;
