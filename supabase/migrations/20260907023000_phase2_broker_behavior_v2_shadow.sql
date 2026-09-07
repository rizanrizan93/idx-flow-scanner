-- Phase 2A/2B: shadow Broker Behavior V2 feature engine.
-- Derived only from verified official IDX broker activity. This migration does NOT
-- change production scoring, execution authorization, or the existing V1 overlay.

create or replace function public.flow_robust_z_from_history(
  p_value numeric,
  p_history numeric[],
  p_min_samples integer default 5
)
returns numeric
language sql
immutable
set search_path = pg_catalog, public
as $$
with vals as (
  select v::numeric as v
  from unnest(coalesce(p_history, array[]::numeric[])) v
  where v is not null
), center_stats as (
  select
    count(*)::integer as n,
    percentile_cont(0.5) within group (order by v)::numeric as med,
    stddev_pop(v)::numeric as sd
  from vals
), dispersion as (
  select
    c.n,
    c.med,
    c.sd,
    percentile_cont(0.5) within group (order by abs(v.v-c.med))::numeric as mad
  from center_stats c
  left join vals v on true
  group by c.n,c.med,c.sd
)
select case
  when p_value is null or d.n < greatest(coalesce(p_min_samples,5),1) then null
  else greatest(
    -8::numeric,
    least(
      8::numeric,
      (p_value-d.med) /
      coalesce(
        nullif(1.4826::numeric*d.mad,0),
        nullif(d.sd,0),
        greatest(abs(coalesce(d.med,0))*0.05::numeric,1::numeric)
      )
    )
  )
end
from dispersion d;
$$;

revoke all on function public.flow_robust_z_from_history(numeric,numeric[],integer)
  from public, anon, authenticated;
grant execute on function public.flow_robust_z_from_history(numeric,numeric[],integer)
  to service_role;

create table if not exists public.flow_broker_behavior_features_v2 (
  trade_date date not null,
  broker_code text not null,
  observed_broker_name text,
  current_directory_name text,
  current_directory_active boolean,
  baseline_sessions integer not null default 0,
  traded_value numeric not null default 0,
  volume numeric not null default 0,
  frequency numeric not null default 0,
  activity_share_pct numeric,
  value_rank integer,
  value_z60 numeric,
  volume_z60 numeric,
  frequency_z60 numeric,
  activity_share_z60 numeric,
  rank_momentum_5 numeric,
  avg_ticket_value numeric,
  avg_ticket_z60 numeric,
  avg_size_shares numeric,
  avg_size_z60 numeric,
  high_activity_flag boolean not null default false,
  high_activity_days_5 integer not null default 0,
  high_activity_streak integer not null default 0,
  persistence_5_pct numeric not null default 0,
  stability_score numeric,
  activity_shock_z numeric,
  activity_shock_score numeric,
  residual_activity_z numeric,
  feature_quality_state text not null,
  source text not null default 'DERIVED_IDX_OFFICIAL_BROKER_BEHAVIOR_V2',
  source_verified boolean not null default true,
  source_dataset text not null default 'flow_official_broker_activity',
  provenance_state text not null default 'SHADOW_DERIVED_FROM_VERIFIED_OFFICIAL_IDX_BROKER_SUMMARY',
  computed_at timestamptz not null default now(),
  primary key (trade_date,broker_code),
  constraint flow_broker_behavior_features_v2_quality_ck
    check (feature_quality_state in ('WARMUP','READY','MATURE')),
  constraint flow_broker_behavior_features_v2_nonnegative_ck
    check (baseline_sessions >= 0 and high_activity_days_5 between 0 and 5 and high_activity_streak between 0 and 10)
);

create index if not exists flow_broker_behavior_features_v2_broker_date_idx
  on public.flow_broker_behavior_features_v2 (broker_code,trade_date desc);
create index if not exists flow_broker_behavior_features_v2_date_quality_idx
  on public.flow_broker_behavior_features_v2 (trade_date desc,feature_quality_state);

alter table public.flow_broker_behavior_features_v2 enable row level security;
revoke all on table public.flow_broker_behavior_features_v2 from public, anon, authenticated;
grant select,insert,update,delete on table public.flow_broker_behavior_features_v2 to service_role;

create table if not exists public.flow_broker_market_regime_v2 (
  trade_date date primary key,
  baseline_sessions integer not null default 0,
  broker_count integer not null,
  ready_broker_count integer not null default 0,
  total_value numeric not null default 0,
  total_volume numeric not null default 0,
  total_frequency numeric not null default 0,
  market_value_z60 numeric,
  market_volume_z60 numeric,
  market_frequency_z60 numeric,
  top10_value_share_pct numeric,
  value_hhi_10k numeric,
  value_entropy_pct numeric,
  concentration_z60 numeric,
  entropy_z60 numeric,
  activity_breadth_pct numeric,
  high_activity_broker_count integer not null default 0,
  shock_broker_count integer not null default 0,
  rank_riser_count integer not null default 0,
  market_activity_intensity_z numeric,
  regime_label text not null,
  regime_quality_state text not null,
  source text not null default 'DERIVED_IDX_OFFICIAL_BROKER_MARKET_REGIME_V2',
  source_verified boolean not null default true,
  source_dataset text not null default 'flow_broker_behavior_features_v2',
  provenance_state text not null default 'SHADOW_DERIVED_FROM_VERIFIED_OFFICIAL_IDX_BROKER_SUMMARY',
  computed_at timestamptz not null default now(),
  constraint flow_broker_market_regime_v2_quality_ck
    check (regime_quality_state in ('WARMUP','READY','MATURE')),
  constraint flow_broker_market_regime_v2_label_ck
    check (regime_label in (
      'WARMUP','NORMAL_ACTIVITY','LOW_PARTICIPATION','BROKER_EXPANSION',
      'BROAD_ACTIVITY_EXPANSION','CONCENTRATED_ACTIVITY','ACTIVITY_SHOCK'
    ))
);

create index if not exists flow_broker_market_regime_v2_label_date_idx
  on public.flow_broker_market_regime_v2 (regime_label,trade_date desc);

alter table public.flow_broker_market_regime_v2 enable row level security;
revoke all on table public.flow_broker_market_regime_v2 from public, anon, authenticated;
grant select,insert,update,delete on table public.flow_broker_market_regime_v2 to service_role;

create or replace function public.flow_refresh_broker_behavior_v2(
  p_date date default ((now() at time zone 'Asia/Jakarta')::date)
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, extensions
as $$
declare
  raw_quality text;
  feature_rows integer := 0;
  ready_brokers integer := 0;
  market_baseline integer := 0;
  market_value_z numeric;
  market_volume_z numeric;
  market_frequency_z numeric;
  current_broker_count integer := 0;
  current_total_value numeric := 0;
  current_total_volume numeric := 0;
  current_total_frequency numeric := 0;
  top10_share numeric := 0;
  hhi numeric := 0;
  entropy_pct numeric := 0;
  breadth_pct numeric := 0;
  high_count integer := 0;
  shock_count integer := 0;
  riser_count integer := 0;
  concentration_z numeric;
  entropy_z numeric;
  intensity_z numeric;
  regime text;
  regime_quality text;
  hist_value numeric[];
  hist_volume numeric[];
  hist_frequency numeric[];
  hist_top10 numeric[];
  hist_entropy numeric[];
begin
  select training_quality_state
    into raw_quality
  from public.flow_broker_session_quality
  where trade_date=p_date;

  if raw_quality is null then
    return jsonb_build_object('trade_date',p_date,'status','NO_OFFICIAL_BROKER_SESSION');
  end if;
  if raw_quality <> 'PASS' then
    raise exception 'Phase2 V2 requires PASS broker session quality for %, got %', p_date,raw_quality;
  end if;

  delete from public.flow_broker_behavior_features_v2 where trade_date=p_date;
  delete from public.flow_broker_market_regime_v2 where trade_date=p_date;

  with base as (
    select
      a.trade_date,
      a.broker_code,
      a.broker_name,
      a.traded_value,
      a.volume,
      a.frequency,
      a.traded_value/nullif(sum(a.traded_value) over (partition by a.trade_date),0) as activity_share,
      rank() over (partition by a.trade_date order by a.traded_value desc,a.broker_code)::integer as value_rank,
      a.traded_value/nullif(a.frequency,0) as avg_ticket_value,
      a.volume/nullif(a.frequency,0) as avg_size_shares
    from public.flow_official_broker_activity a
    where a.source='IDX_OFFICIAL_BROKER_SUMMARY'
      and a.source_verified
      and a.trade_date between (p_date-interval '120 days')::date and p_date
  ), current_rows as (
    select * from base where trade_date=p_date
  ), enriched as (
    select
      c.*,
      d.broker_name as current_directory_name,
      d.is_active as current_directory_active,
      coalesce(h.baseline_sessions,0)::integer as baseline_sessions,
      h.value_hist,
      h.volume_hist,
      h.frequency_hist,
      h.share_hist,
      h.ticket_hist,
      h.size_hist,
      h.prior5_avg_rank,
      h.share_mean,
      h.share_std
    from current_rows c
    left join public.flow_official_broker_directory d using (broker_code)
    left join lateral (
      select
        count(*)::integer as baseline_sessions,
        array_agg(p.traded_value order by p.trade_date desc)::numeric[] as value_hist,
        array_agg(p.volume order by p.trade_date desc)::numeric[] as volume_hist,
        array_agg(p.frequency order by p.trade_date desc)::numeric[] as frequency_hist,
        array_agg(p.activity_share order by p.trade_date desc)::numeric[] as share_hist,
        array_agg(p.avg_ticket_value order by p.trade_date desc)::numeric[] as ticket_hist,
        array_agg(p.avg_size_shares order by p.trade_date desc)::numeric[] as size_hist,
        avg(p.value_rank) filter (where p.rn<=5)::numeric as prior5_avg_rank,
        avg(p.activity_share)::numeric as share_mean,
        stddev_pop(p.activity_share)::numeric as share_std
      from (
        select p0.*,row_number() over(order by p0.trade_date desc) rn
        from base p0
        where p0.broker_code=c.broker_code
          and p0.trade_date<p_date
        order by p0.trade_date desc
        limit 60
      ) p
    ) h on true
  ), scored as (
    select
      e.*,
      public.flow_robust_z_from_history(e.traded_value,e.value_hist,20) as value_z,
      public.flow_robust_z_from_history(e.volume,e.volume_hist,20) as volume_z,
      public.flow_robust_z_from_history(e.frequency,e.frequency_hist,20) as frequency_z,
      public.flow_robust_z_from_history(e.activity_share,e.share_hist,20) as share_z,
      public.flow_robust_z_from_history(e.avg_ticket_value,e.ticket_hist,20) as ticket_z,
      public.flow_robust_z_from_history(e.avg_size_shares,e.size_hist,20) as size_z
    from enriched e
  ), flagged as (
    select
      s.*,
      greatest(
        coalesce(s.value_z,0),coalesce(s.volume_z,0),coalesce(s.frequency_z,0),coalesce(s.share_z,0)
      ) as shock_z,
      (
        s.baseline_sessions>=20 and
        greatest(
          coalesce(s.value_z,0),coalesce(s.volume_z,0),coalesce(s.frequency_z,0),coalesce(s.share_z,0)
        ) >= 1
      ) as high_flag
    from scored s
  ), with_persistence as (
    select
      f.*,
      coalesce(p.prior_high_4,0)::integer as prior_high_4,
      coalesce(p.prior_streak,0)::integer as prior_streak
    from flagged f
    left join lateral (
      with recent as (
        select q.high_activity_flag,
               row_number() over(order by q.trade_date desc)::integer rn
        from (
          select trade_date,high_activity_flag
          from public.flow_broker_behavior_features_v2
          where broker_code=f.broker_code and trade_date<p_date
          order by trade_date desc
          limit 9
        ) q
      )
      select
        count(*) filter (where rn<=4 and high_activity_flag)::integer as prior_high_4,
        coalesce(
          (min(rn) filter (where not high_activity_flag)-1),
          count(*)
        )::integer as prior_streak
      from recent
    ) p on true
  )
  insert into public.flow_broker_behavior_features_v2 (
    trade_date,broker_code,observed_broker_name,current_directory_name,current_directory_active,
    baseline_sessions,traded_value,volume,frequency,activity_share_pct,value_rank,
    value_z60,volume_z60,frequency_z60,activity_share_z60,rank_momentum_5,
    avg_ticket_value,avg_ticket_z60,avg_size_shares,avg_size_z60,
    high_activity_flag,high_activity_days_5,high_activity_streak,persistence_5_pct,
    stability_score,activity_shock_z,activity_shock_score,residual_activity_z,
    feature_quality_state,computed_at
  )
  select
    p_date,
    w.broker_code,
    w.broker_name,
    w.current_directory_name,
    w.current_directory_active,
    w.baseline_sessions,
    w.traded_value,
    w.volume,
    w.frequency,
    100*w.activity_share,
    w.value_rank,
    w.value_z,
    w.volume_z,
    w.frequency_z,
    w.share_z,
    case when w.prior5_avg_rank is null then null else w.prior5_avg_rank-w.value_rank end,
    w.avg_ticket_value,
    w.ticket_z,
    w.avg_size_shares,
    w.size_z,
    w.high_flag,
    least(5,(case when w.high_flag then 1 else 0 end)+w.prior_high_4),
    case when w.high_flag then least(10,1+w.prior_streak) else 0 end,
    20*least(5,(case when w.high_flag then 1 else 0 end)+w.prior_high_4),
    case
      when w.baseline_sessions<5 or coalesce(abs(w.share_mean),0)=0 then null
      else greatest(0::numeric,least(100::numeric,
        100::numeric/(1::numeric+4::numeric*coalesce(w.share_std,0)/nullif(abs(w.share_mean),0))
      ))
    end,
    w.shock_z,
    greatest(0::numeric,least(100::numeric,50::numeric+12.5::numeric*w.shock_z)),
    w.share_z,
    case when w.baseline_sessions>=60 then 'MATURE'
         when w.baseline_sessions>=20 then 'READY'
         else 'WARMUP' end,
    now()
  from with_persistence w;

  get diagnostics feature_rows=row_count;

  select
    count(*)::integer,
    coalesce(sum(traded_value),0),
    coalesce(sum(volume),0),
    coalesce(sum(frequency),0)
  into current_broker_count,current_total_value,current_total_volume,current_total_frequency
  from public.flow_official_broker_activity
  where source='IDX_OFFICIAL_BROKER_SUMMARY' and source_verified and trade_date=p_date;

  with prior_daily as (
    select trade_date,sum(traded_value)::numeric tv,sum(volume)::numeric vol,sum(frequency)::numeric freq
    from public.flow_official_broker_activity
    where source='IDX_OFFICIAL_BROKER_SUMMARY' and source_verified
      and trade_date<p_date and trade_date>=(p_date-interval '120 days')::date
    group by trade_date
    order by trade_date desc
    limit 60
  )
  select
    count(*)::integer,
    array_agg(tv order by trade_date desc)::numeric[],
    array_agg(vol order by trade_date desc)::numeric[],
    array_agg(freq order by trade_date desc)::numeric[]
  into market_baseline,hist_value,hist_volume,hist_frequency
  from prior_daily;

  market_value_z := public.flow_robust_z_from_history(current_total_value,hist_value,20);
  market_volume_z := public.flow_robust_z_from_history(current_total_volume,hist_volume,20);
  market_frequency_z := public.flow_robust_z_from_history(current_total_frequency,hist_frequency,20);

  with ranked as (
    select *,row_number() over(order by traded_value desc,broker_code)::integer rn
    from public.flow_broker_behavior_features_v2
    where trade_date=p_date
  ), agg as (
    select
      count(*) filter (where feature_quality_state in ('READY','MATURE'))::integer ready_count,
      coalesce(sum(activity_share_pct) filter (where rn<=10),0)::numeric top10_pct,
      coalesce(sum(power(activity_share_pct,2)),0)::numeric hhi_value,
      coalesce(
        -sum(case when activity_share_pct>0 then
          (activity_share_pct/100::numeric)*ln(activity_share_pct/100::numeric)
        else 0 end) / nullif(ln(count(*)::numeric),0) * 100::numeric,
        0
      )::numeric entropy_value,
      count(*) filter (
        where feature_quality_state in ('READY','MATURE') and residual_activity_z>=1
      )::integer high_n,
      count(*) filter (
        where feature_quality_state in ('READY','MATURE') and activity_shock_z>=2
      )::integer shock_n,
      count(*) filter (
        where feature_quality_state in ('READY','MATURE') and rank_momentum_5>=5
      )::integer riser_n
    from ranked
  )
  select
    ready_count,top10_pct,hhi_value,entropy_value,
    case when ready_count=0 then 0 else 100::numeric*high_n/ready_count end,
    high_n,shock_n,riser_n
  into ready_brokers,top10_share,hhi,entropy_pct,breadth_pct,high_count,shock_count,riser_count
  from agg;

  select
    array_agg(top10_value_share_pct order by trade_date desc)::numeric[],
    array_agg(value_entropy_pct order by trade_date desc)::numeric[]
  into hist_top10,hist_entropy
  from (
    select trade_date,top10_value_share_pct,value_entropy_pct
    from public.flow_broker_market_regime_v2
    where trade_date<p_date and trade_date>=(p_date-interval '120 days')::date
    order by trade_date desc
    limit 60
  ) h;

  concentration_z := public.flow_robust_z_from_history(top10_share,hist_top10,20);
  entropy_z := public.flow_robust_z_from_history(entropy_pct,hist_entropy,20);
  intensity_z := greatest(
    coalesce(market_value_z,0),coalesce(market_volume_z,0),coalesce(market_frequency_z,0)
  );

  regime_quality := case when market_baseline>=60 then 'MATURE'
                         when market_baseline>=20 then 'READY'
                         else 'WARMUP' end;

  regime := case
    when market_baseline<20 then 'WARMUP'
    when intensity_z>=2.5 and shock_count>=10 then 'ACTIVITY_SHOCK'
    when coalesce(market_value_z,0)>=1 and breadth_pct>=30 and entropy_pct>=70 then 'BROAD_ACTIVITY_EXPANSION'
    when top10_share>=66 and (coalesce(concentration_z,0)>=1 or entropy_pct<=72) then 'CONCENTRATED_ACTIVITY'
    when breadth_pct>=35 and coalesce(market_value_z,0)>=0 then 'BROKER_EXPANSION'
    when coalesce(market_value_z,0)<=-1 and breadth_pct<=15 then 'LOW_PARTICIPATION'
    else 'NORMAL_ACTIVITY'
  end;

  insert into public.flow_broker_market_regime_v2 (
    trade_date,baseline_sessions,broker_count,ready_broker_count,
    total_value,total_volume,total_frequency,market_value_z60,market_volume_z60,market_frequency_z60,
    top10_value_share_pct,value_hhi_10k,value_entropy_pct,concentration_z60,entropy_z60,
    activity_breadth_pct,high_activity_broker_count,shock_broker_count,rank_riser_count,
    market_activity_intensity_z,regime_label,regime_quality_state,computed_at
  ) values (
    p_date,market_baseline,current_broker_count,ready_brokers,
    current_total_value,current_total_volume,current_total_frequency,
    market_value_z,market_volume_z,market_frequency_z,
    top10_share,hhi,entropy_pct,concentration_z,entropy_z,
    breadth_pct,high_count,shock_count,riser_count,
    intensity_z,regime,regime_quality,now()
  );

  insert into public.flow_ingestion_audit (
    provider,dataset,started_at,completed_at,status,rows_received,rows_accepted,
    rows_rejected,freshness_date,details
  ) values (
    'IDX_OFFICIAL_DERIVED','BROKER_BEHAVIOR_V2_SHADOW',now(),now(),'OK',
    current_broker_count,feature_rows,0,p_date,
    jsonb_build_object(
      'phase','PHASE2_BROKER_BEHAVIOR_V2_SHADOW',
      'feature_rows',feature_rows,
      'ready_brokers',ready_brokers,
      'regime',regime,
      'regime_quality',regime_quality,
      'no_production_scoring_change',true
    )
  );

  return jsonb_build_object(
    'trade_date',p_date,
    'status','OK',
    'feature_rows',feature_rows,
    'ready_brokers',ready_brokers,
    'regime_label',regime,
    'regime_quality_state',regime_quality,
    'activity_breadth_pct',breadth_pct,
    'top10_value_share_pct',top10_share,
    'value_hhi_10k',hhi,
    'value_entropy_pct',entropy_pct
  );
end;
$$;

revoke all on function public.flow_refresh_broker_behavior_v2(date)
  from public, anon, authenticated;
grant execute on function public.flow_refresh_broker_behavior_v2(date)
  to service_role;

create or replace function public.flow_backfill_broker_behavior_v2(
  p_start_date date,
  p_end_date date
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  d date;
  r jsonb;
  sessions integer := 0;
  feature_rows bigint := 0;
  failures integer := 0;
begin
  if p_start_date is null or p_end_date is null or p_start_date>p_end_date then
    raise exception 'invalid Phase2 V2 backfill window: % to %',p_start_date,p_end_date;
  end if;
  if (p_end_date-p_start_date)>31 then
    raise exception 'Phase2 V2 backfill window exceeds 31 calendar days: % to %',p_start_date,p_end_date;
  end if;

  for d in
    select trade_date
    from public.flow_broker_session_quality
    where trade_date between p_start_date and p_end_date
      and training_quality_state='PASS'
    order by trade_date
  loop
    begin
      r := public.flow_refresh_broker_behavior_v2(d);
      sessions := sessions+1;
      feature_rows := feature_rows+coalesce((r->>'feature_rows')::integer,0);
    exception when others then
      failures := failures+1;
      insert into public.flow_ingestion_audit (
        provider,dataset,started_at,completed_at,status,rows_received,rows_accepted,
        rows_rejected,freshness_date,error_code,details
      ) values (
        'IDX_OFFICIAL_DERIVED','BROKER_BEHAVIOR_V2_SHADOW',now(),now(),'FAILED',0,0,0,d,
        sqlstate,jsonb_build_object('error',sqlerrm,'phase','PHASE2_BROKER_BEHAVIOR_V2_SHADOW')
      );
    end;
  end loop;

  return jsonb_build_object(
    'start_date',p_start_date,
    'end_date',p_end_date,
    'sessions_attempted',sessions+failures,
    'sessions_completed',sessions,
    'feature_rows_touched',feature_rows,
    'failures',failures
  );
end;
$$;

revoke all on function public.flow_backfill_broker_behavior_v2(date,date)
  from public, anon, authenticated;
grant execute on function public.flow_backfill_broker_behavior_v2(date,date)
  to service_role;

create or replace view public.flow_phase2ab_quality_summary as
with f as (
  select
    count(*)::bigint feature_rows,
    count(distinct trade_date)::integer feature_sessions,
    count(*) filter (where feature_quality_state='WARMUP')::bigint warmup_rows,
    count(*) filter (where feature_quality_state='READY')::bigint ready_rows,
    count(*) filter (where feature_quality_state='MATURE')::bigint mature_rows,
    count(*) filter (where not source_verified)::bigint unverified_rows,
    min(trade_date) first_feature_date,
    max(trade_date) last_feature_date
  from public.flow_broker_behavior_features_v2
), r as (
  select
    count(*)::integer regime_sessions,
    count(*) filter (where regime_quality_state in ('READY','MATURE'))::integer ready_regime_sessions,
    count(*) filter (where regime_quality_state='MATURE')::integer mature_regime_sessions,
    count(*) filter (where not source_verified)::integer unverified_regime_sessions,
    min(trade_date) first_regime_date,
    max(trade_date) last_regime_date
  from public.flow_broker_market_regime_v2
), a as (
  select count(*) filter (where status='FAILED')::integer failed_audit_rows
  from public.flow_ingestion_audit
  where provider='IDX_OFFICIAL_DERIVED' and dataset='BROKER_BEHAVIOR_V2_SHADOW'
)
select f.*,r.*,a.*,
  case
    when f.feature_sessions>=250
      and r.ready_regime_sessions>=240
      and r.mature_regime_sessions>=190
      and f.unverified_rows=0
      and r.unverified_regime_sessions=0
      and a.failed_audit_rows=0
      then 'PHASE2AB_READY'
    else 'PHASE2AB_NOT_READY'
  end as phase2ab_gate_state
from f cross join r cross join a;

revoke all on public.flow_phase2ab_quality_summary from public, anon, authenticated;
grant select on public.flow_phase2ab_quality_summary to service_role;

create extension if not exists pg_cron;
do $$
declare r record;
begin
  for r in select jobid from cron.job where jobname='flow-broker-behavior-v2-shadow-daily' loop
    perform cron.unschedule(r.jobid);
  end loop;
  perform cron.schedule(
    'flow-broker-behavior-v2-shadow-daily',
    '10 11 * * 1-5',
    $cron$select public.flow_refresh_broker_behavior_v2((now() at time zone 'Asia/Jakarta')::date);$cron$
  );
end $$;
