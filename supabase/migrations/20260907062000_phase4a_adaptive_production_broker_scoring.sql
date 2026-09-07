-- Phase 4A: production 3A/3B/3C scoring with leakage-safe self-calibration.
--
-- The total broker-family ranking budget remains fixed at 8%.
-- Initial allocation: Broker V1 6% + advanced 3A/3B/3C 2%.
-- The advanced share can self-calibrate between 0% and 6%; the V1 share is the
-- remainder. No broker-family score can override suspension, dilution, risk,
-- execution geometry, evidence validity, or production authorization gates.
--
-- Phase 3A/3B/3C semantics remain statistical co-activity evidence, NOT proof
-- of broker buy/sell activity in a ticker.

create table if not exists public.flow_broker_adaptive_calibration_state (
  model_key text primary key,
  family_budget numeric not null default 0.08,
  advanced_weight numeric not null default 0.02,
  min_advanced_weight numeric not null default 0.00,
  max_advanced_weight numeric not null default 0.06,
  weight_step numeric not null default 0.005,
  calibration_status text not null default 'BOOTSTRAP',
  min_strong_5d integer not null default 30,
  min_control_5d integer not null default 100,
  strong_n_5d integer not null default 0,
  control_n_5d integer not null default 0,
  strong_avg_return_5d numeric,
  control_avg_return_5d numeric,
  return_lift_5d numeric,
  strong_hit_rate_5d numeric,
  control_hit_rate_5d numeric,
  hit_lift_pp_5d numeric,
  strong_n_20d integer not null default 0,
  control_n_20d integer not null default 0,
  return_lift_20d numeric,
  hit_lift_pp_20d numeric,
  last_calibrated_date date,
  last_weight_change_date date,
  calibration_rule text not null default 'ROLLING_180D__STRONG_ADV_SCORE_GE65__5D_PRIMARY__20D_CONFIRM__MAX_STEP_0P5PCT__7D_COOLDOWN',
  source text not null default 'DERIVED_PHASE4A_FORWARD_OUTCOME_CALIBRATION',
  source_verified boolean not null default true,
  updated_at timestamptz not null default now(),
  constraint flow_broker_adaptive_calibration_state_budget_ck check (
    family_budget between 0 and 0.20
    and min_advanced_weight between 0 and family_budget
    and max_advanced_weight between min_advanced_weight and family_budget
    and advanced_weight between min_advanced_weight and max_advanced_weight
    and weight_step > 0 and weight_step <= 0.02
  ),
  constraint flow_broker_adaptive_calibration_state_status_ck check (
    calibration_status in ('BOOTSTRAP','LEARNING','CALIBRATED','DEGRADED')
  )
);

insert into public.flow_broker_adaptive_calibration_state (
  model_key,family_budget,advanced_weight,min_advanced_weight,max_advanced_weight,
  weight_step,calibration_status
) values (
  'ADVANCED_BROKER_ABC_V1',0.08,0.02,0.00,0.06,0.005,'BOOTSTRAP'
)
on conflict (model_key) do nothing;

create table if not exists public.flow_broker_adaptive_score_observations (
  run_id uuid not null references public.flow_scan_runs(id) on delete cascade,
  ticker text not null,
  as_of_date date not null,
  evidence_as_of_date date not null,
  phase3a_score numeric not null,
  phase3a_eligible boolean not null,
  phase3b_score numeric not null,
  phase3b_eligible boolean not null,
  phase3c_score numeric not null,
  phase3c_eligible boolean not null,
  evidence_layer_count integer not null,
  advanced_broker_score numeric not null,
  advanced_evidence_eligible boolean not null,
  family_budget numeric not null,
  applied_v1_weight numeric not null,
  applied_advanced_weight numeric not null,
  base_score_pre_broker_family numeric not null,
  broker_family_score_adjustment numeric not null,
  final_score numeric not null,
  entry_close numeric,
  return_5d numeric,
  return_10d numeric,
  return_20d numeric,
  mfe_20d numeric,
  mae_20d numeric,
  evaluated_through date,
  evaluation_status text not null default 'PENDING',
  calibration_status_at_signal text not null,
  semantics text not null default 'STATISTICAL_CO_ACTIVITY_EVIDENCE_NOT_BUY_SELL',
  source text not null default 'RUNTIME_PHASE4A_ADAPTIVE_BROKER_SCORING',
  source_verified boolean not null default true,
  created_at timestamptz not null default now(),
  evaluated_at timestamptz,
  primary key (run_id,ticker),
  constraint flow_broker_adaptive_score_observations_score_ck check (
    phase3a_score between 0 and 100
    and phase3b_score between 0 and 100
    and phase3c_score between 0 and 100
    and evidence_layer_count between 0 and 3
    and advanced_broker_score between 50 and 100
    and base_score_pre_broker_family between 0 and 100
    and final_score between 0 and 100
  ),
  constraint flow_broker_adaptive_score_observations_weight_ck check (
    family_budget between 0 and 0.20
    and applied_v1_weight between 0 and family_budget
    and applied_advanced_weight between 0 and family_budget
    and applied_v1_weight + applied_advanced_weight <= family_budget + 0.000001
  ),
  constraint flow_broker_adaptive_score_observations_status_ck check (
    evaluation_status in ('PENDING','PARTIAL','COMPLETE')
  ),
  constraint flow_broker_adaptive_score_observations_semantics_ck check (
    semantics='STATISTICAL_CO_ACTIVITY_EVIDENCE_NOT_BUY_SELL'
  )
);

create index if not exists flow_broker_adaptive_obs_date_idx
  on public.flow_broker_adaptive_score_observations (as_of_date desc,ticker);
create index if not exists flow_broker_adaptive_obs_eval_idx
  on public.flow_broker_adaptive_score_observations (evaluation_status,as_of_date);
create index if not exists flow_broker_adaptive_obs_strong_idx
  on public.flow_broker_adaptive_score_observations
  (as_of_date desc,advanced_evidence_eligible,advanced_broker_score desc);

create table if not exists public.flow_broker_adaptive_calibration_history (
  as_of_date date not null,
  model_key text not null,
  previous_advanced_weight numeric not null,
  new_advanced_weight numeric not null,
  resulting_v1_weight numeric not null,
  strong_n_5d integer not null,
  control_n_5d integer not null,
  return_lift_5d numeric,
  hit_lift_pp_5d numeric,
  strong_n_20d integer not null,
  control_n_20d integer not null,
  return_lift_20d numeric,
  hit_lift_pp_20d numeric,
  calibration_decision text not null,
  calibration_status text not null,
  source text not null default 'DERIVED_PHASE4A_FORWARD_OUTCOME_CALIBRATION',
  source_verified boolean not null default true,
  created_at timestamptz not null default now(),
  primary key (as_of_date,model_key),
  constraint flow_broker_adaptive_calibration_history_weight_ck check (
    previous_advanced_weight between 0 and 0.20
    and new_advanced_weight between 0 and 0.20
    and resulting_v1_weight between 0 and 0.20
  ),
  constraint flow_broker_adaptive_calibration_history_decision_ck check (
    calibration_decision in ('BOOTSTRAP_HOLD','HOLD','INCREASE','DECREASE')
  )
);

alter table public.flow_broker_adaptive_calibration_state enable row level security;
alter table public.flow_broker_adaptive_score_observations enable row level security;
alter table public.flow_broker_adaptive_calibration_history enable row level security;

revoke all on table public.flow_broker_adaptive_calibration_state from public,anon,authenticated;
revoke all on table public.flow_broker_adaptive_score_observations from public,anon,authenticated;
revoke all on table public.flow_broker_adaptive_calibration_history from public,anon,authenticated;

grant select,insert,update,delete on table public.flow_broker_adaptive_calibration_state to service_role;
grant select,insert,update,delete on table public.flow_broker_adaptive_score_observations to service_role;
grant select,insert,update,delete on table public.flow_broker_adaptive_calibration_history to service_role;

create or replace function public.flow_capture_broker_adaptive_score_observation()
returns trigger
language plpgsql
security definer
set search_path=pg_catalog,public
as $$
declare
  d jsonb;
  evidence_date date;
  v_entry numeric;
begin
  d := coalesce(new.diagnostics,'{}'::jsonb);
  if jsonb_typeof(d) <> 'object' then
    return new;
  end if;
  if lower(coalesce(d->>'adaptive_broker_layer_loaded','false')) <> 'true' then
    return new;
  end if;
  evidence_date := nullif(d->>'adaptive_broker_evidence_as_of_date','')::date;
  if evidence_date is null or evidence_date <> new.as_of_date then
    return new;
  end if;

  select s.close into v_entry
  from public.flow_official_stock_summary s
  where s.ticker=new.ticker
    and s.trade_date=new.as_of_date
    and s.source_verified
  order by s.ingested_at desc
  limit 1;

  insert into public.flow_broker_adaptive_score_observations (
    run_id,ticker,as_of_date,evidence_as_of_date,
    phase3a_score,phase3a_eligible,phase3b_score,phase3b_eligible,
    phase3c_score,phase3c_eligible,evidence_layer_count,
    advanced_broker_score,advanced_evidence_eligible,
    family_budget,applied_v1_weight,applied_advanced_weight,
    base_score_pre_broker_family,broker_family_score_adjustment,final_score,
    entry_close,calibration_status_at_signal
  ) values (
    new.run_id,new.ticker,new.as_of_date,evidence_date,
    coalesce(nullif(d->>'phase3a_score','')::numeric,0),
    lower(coalesce(d->>'phase3a_eligible','false'))='true',
    coalesce(nullif(d->>'phase3b_score','')::numeric,0),
    lower(coalesce(d->>'phase3b_eligible','false'))='true',
    coalesce(nullif(d->>'phase3c_score','')::numeric,0),
    lower(coalesce(d->>'phase3c_eligible','false'))='true',
    coalesce(nullif(d->>'advanced_broker_evidence_layer_count','')::integer,0),
    coalesce(nullif(d->>'advanced_broker_score','')::numeric,50),
    lower(coalesce(d->>'advanced_broker_evidence_eligible','false'))='true',
    coalesce(nullif(d->>'broker_family_budget','')::numeric,0.08),
    coalesce(nullif(d->>'broker_v1_weight_effective','')::numeric,0.08),
    coalesce(nullif(d->>'advanced_broker_weight_effective','')::numeric,0),
    coalesce(nullif(d->>'base_score_pre_broker_family','')::numeric,new.final_score),
    coalesce(nullif(d->>'broker_family_score_adjustment','')::numeric,0),
    new.final_score,
    v_entry,
    coalesce(nullif(d->>'adaptive_broker_calibration_status',''),'BOOTSTRAP')
  )
  on conflict (run_id,ticker) do update set
    as_of_date=excluded.as_of_date,
    evidence_as_of_date=excluded.evidence_as_of_date,
    phase3a_score=excluded.phase3a_score,
    phase3a_eligible=excluded.phase3a_eligible,
    phase3b_score=excluded.phase3b_score,
    phase3b_eligible=excluded.phase3b_eligible,
    phase3c_score=excluded.phase3c_score,
    phase3c_eligible=excluded.phase3c_eligible,
    evidence_layer_count=excluded.evidence_layer_count,
    advanced_broker_score=excluded.advanced_broker_score,
    advanced_evidence_eligible=excluded.advanced_evidence_eligible,
    family_budget=excluded.family_budget,
    applied_v1_weight=excluded.applied_v1_weight,
    applied_advanced_weight=excluded.applied_advanced_weight,
    base_score_pre_broker_family=excluded.base_score_pre_broker_family,
    broker_family_score_adjustment=excluded.broker_family_score_adjustment,
    final_score=excluded.final_score,
    entry_close=coalesce(public.flow_broker_adaptive_score_observations.entry_close,excluded.entry_close),
    calibration_status_at_signal=excluded.calibration_status_at_signal;

  return new;
end;
$$;

revoke all on function public.flow_capture_broker_adaptive_score_observation() from public,anon,authenticated;
grant execute on function public.flow_capture_broker_adaptive_score_observation() to service_role;

drop trigger if exists flow_scan_results_capture_adaptive_broker_obs on public.flow_scan_results;
create trigger flow_scan_results_capture_adaptive_broker_obs
after insert or update of diagnostics,final_score on public.flow_scan_results
for each row execute function public.flow_capture_broker_adaptive_score_observation();

create or replace function public.flow_refresh_broker_adaptive_outcomes(
  p_limit integer default 5000
)
returns jsonb
language plpgsql
security definer
set search_path=pg_catalog,public
as $$
declare
  updated_n integer := 0;
begin
  with pending as (
    select run_id,ticker,as_of_date
    from public.flow_broker_adaptive_score_observations
    where evaluation_status <> 'COMPLETE'
    order by as_of_date,ticker
    limit greatest(coalesce(p_limit,5000),0)
  ), series as (
    select
      p.run_id,p.ticker,p.as_of_date,
      s.trade_date,s.close,s.high,s.low,
      row_number() over(
        partition by p.run_id,p.ticker
        order by s.trade_date
      )::integer rn
    from pending p
    join public.flow_official_stock_summary s
      on s.ticker=p.ticker
     and s.trade_date>=p.as_of_date
     and s.source_verified
  ), agg as (
    select
      run_id,ticker,as_of_date,
      min(trade_date) entry_date,
      max(close) filter(where rn=1) entry_close,
      max(close) filter(where rn=6) close_5d,
      max(close) filter(where rn=11) close_10d,
      max(close) filter(where rn=21) close_20d,
      max(high) filter(where rn between 2 and 21) high_20d,
      min(low) filter(where rn between 2 and 21) low_20d,
      max(trade_date) evaluated_through
    from series
    group by run_id,ticker,as_of_date
  ), upd as (
    update public.flow_broker_adaptive_score_observations o
    set
      entry_close=a.entry_close,
      return_5d=case when a.close_5d is not null and a.entry_close>0
        then 100::numeric*(a.close_5d/a.entry_close-1) else null end,
      return_10d=case when a.close_10d is not null and a.entry_close>0
        then 100::numeric*(a.close_10d/a.entry_close-1) else null end,
      return_20d=case when a.close_20d is not null and a.entry_close>0
        then 100::numeric*(a.close_20d/a.entry_close-1) else null end,
      mfe_20d=case when a.high_20d is not null and a.entry_close>0
        then 100::numeric*(a.high_20d/a.entry_close-1) else null end,
      mae_20d=case when a.low_20d is not null and a.entry_close>0
        then 100::numeric*(a.low_20d/a.entry_close-1) else null end,
      evaluated_through=a.evaluated_through,
      evaluation_status=case
        when a.close_20d is not null then 'COMPLETE'
        when a.close_5d is not null or a.close_10d is not null then 'PARTIAL'
        else 'PENDING'
      end,
      evaluated_at=now()
    from agg a
    where o.run_id=a.run_id
      and o.ticker=a.ticker
      and a.entry_date=a.as_of_date
      and a.entry_close>0
    returning 1
  )
  select count(*)::integer into updated_n from upd;

  return jsonb_build_object('status','OK','updated_rows',updated_n);
end;
$$;

revoke all on function public.flow_refresh_broker_adaptive_outcomes(integer) from public,anon,authenticated;
grant execute on function public.flow_refresh_broker_adaptive_outcomes(integer) to service_role;

create or replace function public.flow_recalibrate_broker_adaptive_scoring(
  p_as_of_date date default ((now() at time zone 'Asia/Jakarta')::date)
)
returns jsonb
language plpgsql
security definer
set search_path=pg_catalog,public
as $$
declare
  st public.flow_broker_adaptive_calibration_state%rowtype;
  strong_n5 integer := 0;
  control_n5 integer := 0;
  strong_ret5 numeric;
  control_ret5 numeric;
  ret_lift5 numeric;
  strong_hit5 numeric;
  control_hit5 numeric;
  hit_lift5 numeric;
  strong_n20 integer := 0;
  control_n20 integer := 0;
  strong_ret20 numeric;
  control_ret20 numeric;
  ret_lift20 numeric;
  strong_hit20 numeric;
  control_hit20 numeric;
  hit_lift20 numeric;
  prev_weight numeric;
  next_weight numeric;
  decision text := 'HOLD';
  next_status text := 'LEARNING';
  cooldown_ok boolean := false;
begin
  perform public.flow_refresh_broker_adaptive_outcomes(30000);

  select * into st
  from public.flow_broker_adaptive_calibration_state
  where model_key='ADVANCED_BROKER_ABC_V1'
  for update;

  if not found then
    raise exception 'Adaptive broker calibration state missing';
  end if;

  with sample as (
    select *
    from public.flow_broker_adaptive_score_observations
    where as_of_date < p_as_of_date
      and as_of_date >= p_as_of_date - 180
      and source_verified
  )
  select
    count(*) filter(where advanced_evidence_eligible and advanced_broker_score>=65 and return_5d is not null)::integer,
    count(*) filter(where (not advanced_evidence_eligible or advanced_broker_score<=55) and return_5d is not null)::integer,
    avg(return_5d) filter(where advanced_evidence_eligible and advanced_broker_score>=65),
    avg(return_5d) filter(where (not advanced_evidence_eligible or advanced_broker_score<=55)),
    100::numeric*avg(case when return_5d>0 then 1 else 0 end) filter(where advanced_evidence_eligible and advanced_broker_score>=65 and return_5d is not null),
    100::numeric*avg(case when return_5d>0 then 1 else 0 end) filter(where (not advanced_evidence_eligible or advanced_broker_score<=55) and return_5d is not null),
    count(*) filter(where advanced_evidence_eligible and advanced_broker_score>=65 and return_20d is not null)::integer,
    count(*) filter(where (not advanced_evidence_eligible or advanced_broker_score<=55) and return_20d is not null)::integer,
    avg(return_20d) filter(where advanced_evidence_eligible and advanced_broker_score>=65),
    avg(return_20d) filter(where (not advanced_evidence_eligible or advanced_broker_score<=55)),
    100::numeric*avg(case when return_20d>0 then 1 else 0 end) filter(where advanced_evidence_eligible and advanced_broker_score>=65 and return_20d is not null),
    100::numeric*avg(case when return_20d>0 then 1 else 0 end) filter(where (not advanced_evidence_eligible or advanced_broker_score<=55) and return_20d is not null)
  into
    strong_n5,control_n5,strong_ret5,control_ret5,strong_hit5,control_hit5,
    strong_n20,control_n20,strong_ret20,control_ret20,strong_hit20,control_hit20
  from sample;

  ret_lift5 := case when strong_ret5 is not null and control_ret5 is not null then strong_ret5-control_ret5 end;
  hit_lift5 := case when strong_hit5 is not null and control_hit5 is not null then strong_hit5-control_hit5 end;
  ret_lift20 := case when strong_ret20 is not null and control_ret20 is not null then strong_ret20-control_ret20 end;
  hit_lift20 := case when strong_hit20 is not null and control_hit20 is not null then strong_hit20-control_hit20 end;

  prev_weight := st.advanced_weight;
  next_weight := prev_weight;
  cooldown_ok := st.last_weight_change_date is null or p_as_of_date-st.last_weight_change_date>=7;

  if strong_n5 < st.min_strong_5d or control_n5 < st.min_control_5d then
    decision := 'BOOTSTRAP_HOLD';
    next_status := 'BOOTSTRAP';
  else
    next_status := 'LEARNING';
    if cooldown_ok then
      if coalesce(ret_lift5,0) >= 0.50
         and coalesce(hit_lift5,0) >= 5.0
         and (strong_n20 < 30 or coalesce(ret_lift20,0) >= 0)
         and (strong_n20 < 30 or coalesce(hit_lift20,0) >= 0) then
        next_weight := least(st.max_advanced_weight,prev_weight+st.weight_step);
        decision := case when next_weight>prev_weight then 'INCREASE' else 'HOLD' end;
      elsif coalesce(ret_lift5,0) <= -0.25
         or coalesce(hit_lift5,0) <= -3.0
         or (strong_n20>=30 and coalesce(ret_lift20,0) < -0.50)
         or (strong_n20>=30 and coalesce(hit_lift20,0) < -5.0) then
        next_weight := greatest(st.min_advanced_weight,prev_weight-st.weight_step);
        decision := case when next_weight<prev_weight then 'DECREASE' else 'HOLD' end;
      end if;
    end if;

    if next_weight > 0.02 and decision <> 'DECREASE' then
      next_status := 'CALIBRATED';
    elsif next_weight < 0.02 then
      next_status := 'DEGRADED';
    end if;
  end if;

  update public.flow_broker_adaptive_calibration_state
  set
    advanced_weight=next_weight,
    calibration_status=next_status,
    strong_n_5d=strong_n5,
    control_n_5d=control_n5,
    strong_avg_return_5d=strong_ret5,
    control_avg_return_5d=control_ret5,
    return_lift_5d=ret_lift5,
    strong_hit_rate_5d=strong_hit5,
    control_hit_rate_5d=control_hit5,
    hit_lift_pp_5d=hit_lift5,
    strong_n_20d=strong_n20,
    control_n_20d=control_n20,
    return_lift_20d=ret_lift20,
    hit_lift_pp_20d=hit_lift20,
    last_calibrated_date=p_as_of_date,
    last_weight_change_date=case when next_weight<>prev_weight then p_as_of_date else last_weight_change_date end,
    updated_at=now()
  where model_key=st.model_key;

  insert into public.flow_broker_adaptive_calibration_history (
    as_of_date,model_key,previous_advanced_weight,new_advanced_weight,resulting_v1_weight,
    strong_n_5d,control_n_5d,return_lift_5d,hit_lift_pp_5d,
    strong_n_20d,control_n_20d,return_lift_20d,hit_lift_pp_20d,
    calibration_decision,calibration_status
  ) values (
    p_as_of_date,st.model_key,prev_weight,next_weight,st.family_budget-next_weight,
    strong_n5,control_n5,ret_lift5,hit_lift5,
    strong_n20,control_n20,ret_lift20,hit_lift20,
    decision,next_status
  )
  on conflict (as_of_date,model_key) do update set
    previous_advanced_weight=excluded.previous_advanced_weight,
    new_advanced_weight=excluded.new_advanced_weight,
    resulting_v1_weight=excluded.resulting_v1_weight,
    strong_n_5d=excluded.strong_n_5d,
    control_n_5d=excluded.control_n_5d,
    return_lift_5d=excluded.return_lift_5d,
    hit_lift_pp_5d=excluded.hit_lift_pp_5d,
    strong_n_20d=excluded.strong_n_20d,
    control_n_20d=excluded.control_n_20d,
    return_lift_20d=excluded.return_lift_20d,
    hit_lift_pp_20d=excluded.hit_lift_pp_20d,
    calibration_decision=excluded.calibration_decision,
    calibration_status=excluded.calibration_status,
    created_at=now();

  return jsonb_build_object(
    'status','OK',
    'as_of_date',p_as_of_date,
    'decision',decision,
    'calibration_status',next_status,
    'previous_advanced_weight',prev_weight,
    'new_advanced_weight',next_weight,
    'resulting_v1_weight',st.family_budget-next_weight,
    'strong_n_5d',strong_n5,
    'control_n_5d',control_n5,
    'return_lift_5d',ret_lift5,
    'hit_lift_pp_5d',hit_lift5,
    'strong_n_20d',strong_n20,
    'control_n_20d',control_n20,
    'return_lift_20d',ret_lift20,
    'hit_lift_pp_20d',hit_lift20
  );
end;
$$;

revoke all on function public.flow_recalibrate_broker_adaptive_scoring(date) from public,anon,authenticated;
grant execute on function public.flow_recalibrate_broker_adaptive_scoring(date) to service_role;

create or replace view public.flow_broker_adaptive_quality_summary as
with s as (
  select *
  from public.flow_broker_adaptive_calibration_state
  where model_key='ADVANCED_BROKER_ABC_V1'
), o as (
  select
    count(*)::integer observation_rows,
    count(*) filter(where source_verified=false)::integer unverified_rows,
    count(*) filter(where evidence_as_of_date<>as_of_date)::integer date_mismatch_rows,
    count(*) filter(where applied_v1_weight+applied_advanced_weight>family_budget+0.000001)::integer budget_violation_rows,
    count(*) filter(where evaluation_status='COMPLETE')::integer complete_outcome_rows,
    max(as_of_date) latest_observation_date
  from public.flow_broker_adaptive_score_observations
)
select
  s.model_key,s.family_budget,s.advanced_weight,
  s.family_budget-s.advanced_weight as effective_v1_weight,
  s.min_advanced_weight,s.max_advanced_weight,s.calibration_status,
  s.strong_n_5d,s.control_n_5d,s.return_lift_5d,s.hit_lift_pp_5d,
  s.strong_n_20d,s.control_n_20d,s.return_lift_20d,s.hit_lift_pp_20d,
  s.last_calibrated_date,s.last_weight_change_date,
  o.observation_rows,o.complete_outcome_rows,o.latest_observation_date,
  o.unverified_rows,o.date_mismatch_rows,o.budget_violation_rows,
  case
    when s.family_budget=0.08
      and s.advanced_weight between s.min_advanced_weight and s.max_advanced_weight
      and s.family_budget-s.advanced_weight>=0.02
      and o.unverified_rows=0
      and o.date_mismatch_rows=0
      and o.budget_violation_rows=0
      then 'ADAPTIVE_BROKER_PRODUCTION_READY'
    else 'ADAPTIVE_BROKER_PRODUCTION_NOT_READY'
  end adaptive_broker_gate_state
from s cross join o;

revoke all on public.flow_broker_adaptive_quality_summary from public,anon,authenticated;
grant select on public.flow_broker_adaptive_quality_summary to service_role;

do $$
declare j record;
begin
  for j in select jobid from cron.job where jobname='flow-broker-adaptive-calibration-daily'
  loop
    perform cron.unschedule(j.jobid);
  end loop;
end $$;

select cron.schedule(
  'flow-broker-adaptive-calibration-daily',
  '22 11 * * 1-5',
  $$select public.flow_recalibrate_broker_adaptive_scoring((now() at time zone 'Asia/Jakarta')::date);$$
);
