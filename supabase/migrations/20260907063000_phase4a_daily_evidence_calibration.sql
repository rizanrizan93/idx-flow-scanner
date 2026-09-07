-- Phase 4A automatic daily evidence calibration.
--
-- This makes self-calibration independent of manual Streamlit scan frequency.
-- After Phase 3C finishes, the database snapshots the day's 3A/3B/3C evidence
-- at 18:21 WIB. The 18:22 calibration uses only prior dates, never today's
-- just-created observation. Production runtime observations remain separately
-- preserved as an audit of the score actually used by each scanner run.

create table if not exists public.flow_broker_adaptive_daily_observations (
  as_of_date date not null,
  ticker text not null,
  phase3a_score numeric not null,
  phase3a_eligible boolean not null,
  phase3b_score numeric not null,
  phase3b_eligible boolean not null,
  phase3c_score numeric not null,
  phase3c_eligible boolean not null,
  evidence_layer_count integer not null,
  advanced_broker_score numeric not null,
  advanced_evidence_eligible boolean not null,
  candidate_class text not null,
  entry_close numeric,
  return_5d numeric,
  return_10d numeric,
  return_20d numeric,
  mfe_20d numeric,
  mae_20d numeric,
  evaluated_through date,
  evaluation_status text not null default 'PENDING',
  semantics text not null default 'STATISTICAL_CO_ACTIVITY_EVIDENCE_NOT_BUY_SELL',
  source text not null default 'DERIVED_PHASE4A_DAILY_3ABC_CALIBRATION',
  source_verified boolean not null default true,
  created_at timestamptz not null default now(),
  evaluated_at timestamptz,
  primary key (as_of_date,ticker),
  constraint flow_broker_adaptive_daily_obs_score_ck check (
    phase3a_score between 0 and 100
    and phase3b_score between 0 and 100
    and phase3c_score between 0 and 100
    and evidence_layer_count between 0 and 3
    and advanced_broker_score between 50 and 100
  ),
  constraint flow_broker_adaptive_daily_obs_class_ck check (
    candidate_class in ('STRONG','INTERMEDIATE','CONTROL')
  ),
  constraint flow_broker_adaptive_daily_obs_status_ck check (
    evaluation_status in ('PENDING','PARTIAL','COMPLETE')
  ),
  constraint flow_broker_adaptive_daily_obs_semantics_ck check (
    semantics='STATISTICAL_CO_ACTIVITY_EVIDENCE_NOT_BUY_SELL'
  )
);

create index if not exists flow_broker_adaptive_daily_obs_eval_idx
  on public.flow_broker_adaptive_daily_observations (evaluation_status,as_of_date,ticker);
create index if not exists flow_broker_adaptive_daily_obs_class_idx
  on public.flow_broker_adaptive_daily_observations
  (as_of_date desc,candidate_class,advanced_broker_score desc);

alter table public.flow_broker_adaptive_daily_observations enable row level security;
revoke all on table public.flow_broker_adaptive_daily_observations from public,anon,authenticated;
grant select,insert,update,delete on table public.flow_broker_adaptive_daily_observations to service_role;

create or replace function public.flow_refresh_broker_adaptive_daily_outcomes(
  p_limit integer default 10000
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
    select as_of_date,ticker
    from public.flow_broker_adaptive_daily_observations
    where evaluation_status <> 'COMPLETE'
    order by as_of_date,ticker
    limit greatest(coalesce(p_limit,10000),0)
  ), series as (
    select
      p.as_of_date,p.ticker,s.trade_date,s.close,s.high,s.low,
      row_number() over(
        partition by p.as_of_date,p.ticker
        order by s.trade_date
      )::integer rn
    from pending p
    join public.flow_official_stock_summary s
      on s.ticker=p.ticker
     and s.trade_date>=p.as_of_date
     and s.source_verified
  ), agg as (
    select
      as_of_date,ticker,
      min(trade_date) entry_date,
      max(close) filter(where rn=1) entry_close,
      max(close) filter(where rn=6) close_5d,
      max(close) filter(where rn=11) close_10d,
      max(close) filter(where rn=21) close_20d,
      max(high) filter(where rn between 2 and 21) high_20d,
      min(low) filter(where rn between 2 and 21) low_20d,
      max(trade_date) evaluated_through
    from series
    group by as_of_date,ticker
  ), upd as (
    update public.flow_broker_adaptive_daily_observations o
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
    where o.as_of_date=a.as_of_date
      and o.ticker=a.ticker
      and a.entry_date=a.as_of_date
      and a.entry_close>0
    returning 1
  )
  select count(*)::integer into updated_n from upd;

  return jsonb_build_object('status','OK','updated_rows',updated_n);
end;
$$;

revoke all on function public.flow_refresh_broker_adaptive_daily_outcomes(integer)
  from public,anon,authenticated;
grant execute on function public.flow_refresh_broker_adaptive_daily_outcomes(integer)
  to service_role;

create or replace function public.flow_snapshot_broker_adaptive_daily_evidence(
  p_as_of_date date default ((now() at time zone 'Asia/Jakarta')::date)
)
returns jsonb
language plpgsql
security definer
set search_path=pg_catalog,public
as $$
declare
  b_state text;
  c_state text;
  b_date date;
  c_date date;
  inserted_n integer := 0;
  strong_n integer := 0;
  control_n integer := 0;
begin
  perform public.flow_refresh_broker_adaptive_daily_outcomes(30000);

  select phase3b_gate_state,as_of_date into b_state,b_date
  from public.flow_phase3b_quality_summary;
  select phase3c_gate_state,as_of_date into c_state,c_date
  from public.flow_phase3c_quality_summary;

  if b_state is distinct from 'PHASE3B_READY'
     or c_state is distinct from 'PHASE3C_READY' then
    return jsonb_build_object(
      'status','UPSTREAM_NOT_READY',
      'phase3b_state',b_state,
      'phase3c_state',c_state
    );
  end if;
  if b_date is distinct from p_as_of_date or c_date is distinct from p_as_of_date then
    return jsonb_build_object(
      'status','UPSTREAM_AS_OF_MISMATCH',
      'requested_as_of_date',p_as_of_date,
      'phase3b_as_of_date',b_date,
      'phase3c_as_of_date',c_date
    );
  end if;

  with c3_ranked as (
    select
      t.ticker,
      t.coalition_ticker_profile_score,
      c.activation_state,
      case c.activation_state
        when 'BROAD_ACTIVE' then 1::numeric
        when 'PARTIAL' then 0.50::numeric
        else 0::numeric
      end activation_factor,
      t.source_verified and c.source_verified source_verified,
      row_number() over(
        partition by t.ticker
        order by
          t.coalition_ticker_profile_score * case c.activation_state
            when 'BROAD_ACTIVE' then 1::numeric
            when 'PARTIAL' then 0.50::numeric
            else 0::numeric
          end desc,
          t.coalition_id
      ) rn
    from public.flow_broker_coalition_ticker_affinity_v3 t
    join public.flow_broker_coalitions_v3 c
      using(as_of_date,coalition_id)
    where t.as_of_date=p_as_of_date
  ), c3 as (
    select
      ticker,
      least(100::numeric,greatest(0::numeric,
        coalition_ticker_profile_score*activation_factor)) phase3c_score,
      source_verified
    from c3_ranked
    where rn=1
  ), universe as (
    select ticker
    from public.flow_ticker_affinity_consensus_v3
    where as_of_date=p_as_of_date
    union
    select ticker from c3
  ), raw as (
    select
      u.ticker,
      coalesce(b.weighted_affinity_score,0)::numeric phase3a_score,
      (
        coalesce(b.source_verified,false)
        and coalesce(b.affinity_active_broker_count,0)>=3
        and coalesce(b.weighted_affinity_score,0)>=65
        and coalesce(b.consensus_reliability_factor,0)>=0.60
      ) phase3a_eligible,
      coalesce(b.broker_consensus_proxy_score,0)::numeric phase3b_score,
      (
        coalesce(b.source_verified,false)
        and coalesce(b.breadth_state,'') in ('STRONG','BROAD')
        and coalesce(b.broker_consensus_proxy_score,0)>=45
      ) phase3b_eligible,
      coalesce(c.phase3c_score,0)::numeric phase3c_score,
      (
        coalesce(c.source_verified,false)
        and coalesce(c.phase3c_score,0)>=50
      ) phase3c_eligible,
      coalesce(b.consensus_reliability_factor,0)::numeric consensus_reliability_factor
    from universe u
    left join public.flow_ticker_affinity_consensus_v3 b
      on b.as_of_date=p_as_of_date and b.ticker=u.ticker
    left join c3 c on c.ticker=u.ticker
  ), scored as (
    select
      r.*,
      (phase3a_eligible::integer+phase3b_eligible::integer+phase3c_eligible::integer)::integer evidence_layer_count,
      least(1::numeric,greatest(0::numeric,
        0.25::numeric*case when phase3a_eligible
          then (phase3a_score/100::numeric)*least(1::numeric,greatest(0::numeric,consensus_reliability_factor))
          else 0::numeric end
        + 0.50::numeric*case when phase3b_eligible then phase3b_score/100::numeric else 0::numeric end
        + 0.25::numeric*case when phase3c_eligible then phase3c_score/100::numeric else 0::numeric end
      )) support
    from raw r
  ), final as (
    select
      s.*,
      50::numeric+50::numeric*support advanced_broker_score,
      evidence_layer_count>0 advanced_evidence_eligible
    from scored s
  ), source_rows as (
    select
      f.*,
      case
        when advanced_evidence_eligible and advanced_broker_score>=65 then 'STRONG'
        when not advanced_evidence_eligible or advanced_broker_score<=55 then 'CONTROL'
        else 'INTERMEDIATE'
      end candidate_class,
      px.close entry_close
    from final f
    left join lateral (
      select s.close
      from public.flow_official_stock_summary s
      where s.ticker=f.ticker
        and s.trade_date=p_as_of_date
        and s.source_verified
      order by s.ingested_at desc
      limit 1
    ) px on true
  ), upserted as (
    insert into public.flow_broker_adaptive_daily_observations (
      as_of_date,ticker,
      phase3a_score,phase3a_eligible,phase3b_score,phase3b_eligible,
      phase3c_score,phase3c_eligible,evidence_layer_count,
      advanced_broker_score,advanced_evidence_eligible,candidate_class,entry_close
    )
    select
      p_as_of_date,ticker,
      least(100::numeric,greatest(0::numeric,phase3a_score)),phase3a_eligible,
      least(100::numeric,greatest(0::numeric,phase3b_score)),phase3b_eligible,
      least(100::numeric,greatest(0::numeric,phase3c_score)),phase3c_eligible,
      evidence_layer_count,
      least(100::numeric,greatest(50::numeric,advanced_broker_score)),
      advanced_evidence_eligible,candidate_class,entry_close
    from source_rows
    on conflict (as_of_date,ticker) do update set
      phase3a_score=excluded.phase3a_score,
      phase3a_eligible=excluded.phase3a_eligible,
      phase3b_score=excluded.phase3b_score,
      phase3b_eligible=excluded.phase3b_eligible,
      phase3c_score=excluded.phase3c_score,
      phase3c_eligible=excluded.phase3c_eligible,
      evidence_layer_count=excluded.evidence_layer_count,
      advanced_broker_score=excluded.advanced_broker_score,
      advanced_evidence_eligible=excluded.advanced_evidence_eligible,
      candidate_class=excluded.candidate_class,
      entry_close=coalesce(public.flow_broker_adaptive_daily_observations.entry_close,excluded.entry_close)
    returning candidate_class
  )
  select
    count(*)::integer,
    count(*) filter(where candidate_class='STRONG')::integer,
    count(*) filter(where candidate_class='CONTROL')::integer
  into inserted_n,strong_n,control_n
  from upserted;

  insert into public.flow_ingestion_audit (
    provider,dataset,started_at,completed_at,status,rows_received,rows_accepted,
    rows_rejected,freshness_date,details
  ) values (
    'IDX_OFFICIAL_DERIVED','BROKER_ADAPTIVE_DAILY_EVIDENCE_V1',now(),now(),'OK',
    inserted_n,inserted_n,0,p_as_of_date,
    jsonb_build_object(
      'phase','PHASE4A_AUTOMATIC_DAILY_CALIBRATION',
      'strong_rows',strong_n,
      'control_rows',control_n,
      'uses_same_day_phase3b_phase3c_only',true,
      'no_same_day_calibration',true,
      'semantics','STATISTICAL_CO_ACTIVITY_EVIDENCE_NOT_BUY_SELL'
    )
  );

  return jsonb_build_object(
    'status','OK',
    'as_of_date',p_as_of_date,
    'rows',inserted_n,
    'strong_rows',strong_n,
    'control_rows',control_n
  );
end;
$$;

revoke all on function public.flow_snapshot_broker_adaptive_daily_evidence(date)
  from public,anon,authenticated;
grant execute on function public.flow_snapshot_broker_adaptive_daily_evidence(date)
  to service_role;

-- Replace the calibrator so its statistical sample is fully automatic daily
-- evidence rather than being dependent on how many times Streamlit was scanned.
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
  perform public.flow_refresh_broker_adaptive_daily_outcomes(30000);

  select * into st
  from public.flow_broker_adaptive_calibration_state
  where model_key='ADVANCED_BROKER_ABC_V1'
  for update;
  if not found then
    raise exception 'Adaptive broker calibration state missing';
  end if;

  with sample as (
    select *
    from public.flow_broker_adaptive_daily_observations
    where as_of_date < p_as_of_date
      and as_of_date >= p_as_of_date - 180
      and source_verified
  )
  select
    count(*) filter(where candidate_class='STRONG' and return_5d is not null)::integer,
    count(*) filter(where candidate_class='CONTROL' and return_5d is not null)::integer,
    avg(return_5d) filter(where candidate_class='STRONG'),
    avg(return_5d) filter(where candidate_class='CONTROL'),
    100::numeric*avg(case when return_5d>0 then 1 else 0 end)
      filter(where candidate_class='STRONG' and return_5d is not null),
    100::numeric*avg(case when return_5d>0 then 1 else 0 end)
      filter(where candidate_class='CONTROL' and return_5d is not null),
    count(*) filter(where candidate_class='STRONG' and return_20d is not null)::integer,
    count(*) filter(where candidate_class='CONTROL' and return_20d is not null)::integer,
    avg(return_20d) filter(where candidate_class='STRONG'),
    avg(return_20d) filter(where candidate_class='CONTROL'),
    100::numeric*avg(case when return_20d>0 then 1 else 0 end)
      filter(where candidate_class='STRONG' and return_20d is not null),
    100::numeric*avg(case when return_20d>0 then 1 else 0 end)
      filter(where candidate_class='CONTROL' and return_20d is not null)
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
      if coalesce(ret_lift5,0)>=0.50
         and coalesce(hit_lift5,0)>=5.0
         and (strong_n20<30 or coalesce(ret_lift20,0)>=0)
         and (strong_n20<30 or coalesce(hit_lift20,0)>=0) then
        next_weight := least(st.max_advanced_weight,prev_weight+st.weight_step);
        decision := case when next_weight>prev_weight then 'INCREASE' else 'HOLD' end;
      elsif coalesce(ret_lift5,0)<=-0.25
         or coalesce(hit_lift5,0)<=-3.0
         or (strong_n20>=30 and coalesce(ret_lift20,0)<-0.50)
         or (strong_n20>=30 and coalesce(hit_lift20,0)<-5.0) then
        next_weight := greatest(st.min_advanced_weight,prev_weight-st.weight_step);
        decision := case when next_weight<prev_weight then 'DECREASE' else 'HOLD' end;
      end if;
    end if;

    if next_weight>0.02 and decision<>'DECREASE' then
      next_status := 'CALIBRATED';
    elsif next_weight<0.02 then
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
    'sample_source','AUTOMATIC_DAILY_3ABC_EVIDENCE',
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

revoke all on function public.flow_recalibrate_broker_adaptive_scoring(date)
  from public,anon,authenticated;
grant execute on function public.flow_recalibrate_broker_adaptive_scoring(date)
  to service_role;

-- Add automatic calibration telemetry without changing the existing production
-- readiness column order/meaning.
create or replace view public.flow_broker_adaptive_daily_quality_summary as
select
  count(*)::integer observation_rows,
  count(distinct as_of_date)::integer observation_dates,
  count(*) filter(where candidate_class='STRONG')::integer strong_rows,
  count(*) filter(where candidate_class='CONTROL')::integer control_rows,
  count(*) filter(where evaluation_status='COMPLETE')::integer complete_rows,
  count(*) filter(where not source_verified)::integer unverified_rows,
  count(*) filter(where semantics<>'STATISTICAL_CO_ACTIVITY_EVIDENCE_NOT_BUY_SELL')::integer bad_semantics_rows,
  min(as_of_date) first_observation_date,
  max(as_of_date) latest_observation_date
from public.flow_broker_adaptive_daily_observations;

revoke all on public.flow_broker_adaptive_daily_quality_summary from public,anon,authenticated;
grant select on public.flow_broker_adaptive_daily_quality_summary to service_role;

do $$
declare j record;
begin
  for j in select jobid from cron.job where jobname='flow-broker-adaptive-daily-evidence-snapshot'
  loop
    perform cron.unschedule(j.jobid);
  end loop;
end $$;

select cron.schedule(
  'flow-broker-adaptive-daily-evidence-snapshot',
  '21 11 * * 1-5',
  $$select public.flow_snapshot_broker_adaptive_daily_evidence((now() at time zone 'Asia/Jakarta')::date);$$
);
