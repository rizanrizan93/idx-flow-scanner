-- Phase 3A: event-conditioned Broker–Ticker Affinity research matrix.
--
-- IMPORTANT SEMANTICS
-- IDX Broker Summary is market-wide broker activity without per-ticker buy/sell direction.
-- Therefore every relationship produced here is CO-ACTIVITY AFFINITY only. It must never
-- be described as a broker buying, selling, accumulating, or distributing a ticker.
--
-- This is a SHADOW research layer. It does NOT change final_score, production scoring,
-- execution authorization, execution-ready semantics, or the existing broker overlay.

create table if not exists public.flow_broker_ticker_affinity_v3 (
  as_of_date date not null,
  lag_sessions smallint not null,
  broker_code text not null,
  ticker text not null,
  broker_current_name text,
  training_start_date date not null,
  training_end_date date not null,
  training_window_sessions integer not null,
  eligible_sessions integer not null,
  broker_event_threshold numeric not null default 1.5,
  stock_event_threshold numeric not null default 1.0,
  broker_event_count integer not null,
  stock_event_count integer not null,
  coevent_count integer not null,
  expected_coevent_count numeric not null,
  broker_event_rate_pct numeric not null,
  stock_event_rate_pct numeric not null,
  conditional_hit_pct numeric not null,
  excess_hit_pct numeric not null,
  affinity_lift numeric not null,
  affinity_z numeric not null,
  first_half_lift numeric,
  first_half_z numeric,
  second_half_lift numeric,
  second_half_z numeric,
  stability_state text not null,
  research_affinity_score numeric not null,
  association_semantics text not null default 'CO_ACTIVITY_AFFINITY_NOT_BUY_SELL',
  retention_rule text not null default 'COEVENTS_GE5__LIFT_GE1_5__Z_GE2_5__EXCESS_HIT_GE10PP',
  source text not null default 'DERIVED_PHASE3A_BROKER_TICKER_AFFINITY',
  source_verified boolean not null default true,
  source_broker_dataset text not null default 'flow_broker_behavior_features_v2',
  source_stock_dataset text not null default 'flow_stock_residual_activity_v2',
  provenance_state text not null default 'SHADOW_EVENT_CONDITIONED_FROM_VERIFIED_PHASE2_RESIDUALS',
  computed_at timestamptz not null default now(),
  primary key (as_of_date,lag_sessions,broker_code,ticker),
  constraint flow_broker_ticker_affinity_v3_lag_ck
    check (lag_sessions in (0,1,2,5)),
  constraint flow_broker_ticker_affinity_v3_stability_ck
    check (stability_state in ('STABLE','RECENT_STRENGTHENING','DECAYING','MIXED')),
  constraint flow_broker_ticker_affinity_v3_semantics_ck
    check (association_semantics='CO_ACTIVITY_AFFINITY_NOT_BUY_SELL'),
  constraint flow_broker_ticker_affinity_v3_counts_ck
    check (
      training_window_sessions between 160 and 220
      and eligible_sessions >= 155
      and broker_event_count >= 12
      and stock_event_count >= 10
      and coevent_count >= 5
      and coevent_count <= broker_event_count
      and coevent_count <= stock_event_count
    ),
  constraint flow_broker_ticker_affinity_v3_retention_ck
    check (affinity_lift >= 1.5 and affinity_z >= 2.5 and excess_hit_pct >= 10),
  constraint flow_broker_ticker_affinity_v3_score_ck
    check (research_affinity_score between 0 and 100)
);

create index if not exists flow_broker_ticker_affinity_v3_latest_score_idx
  on public.flow_broker_ticker_affinity_v3
    (as_of_date desc,lag_sessions,research_affinity_score desc);
create index if not exists flow_broker_ticker_affinity_v3_broker_idx
  on public.flow_broker_ticker_affinity_v3
    (broker_code,lag_sessions,as_of_date desc,research_affinity_score desc);
create index if not exists flow_broker_ticker_affinity_v3_ticker_idx
  on public.flow_broker_ticker_affinity_v3
    (ticker,lag_sessions,as_of_date desc,research_affinity_score desc);

alter table public.flow_broker_ticker_affinity_v3 enable row level security;
revoke all on table public.flow_broker_ticker_affinity_v3 from public, anon, authenticated;
grant select,insert,update,delete on table public.flow_broker_ticker_affinity_v3 to service_role;

create table if not exists public.flow_broker_ticker_affinity_snapshot_v3 (
  as_of_date date not null,
  lag_sessions smallint not null,
  training_start_date date not null,
  training_end_date date not null,
  training_window_sessions integer not null,
  eligible_sessions integer not null,
  eligible_brokers integer not null,
  eligible_tickers integer not null,
  broker_event_ready_count integer not null,
  stock_event_ready_count integer not null,
  candidate_pairs_considered bigint not null,
  retained_affinity_rows integer not null,
  stable_rows integer not null,
  recent_strengthening_rows integer not null,
  decaying_rows integer not null,
  mixed_rows integer not null,
  source text not null default 'DERIVED_PHASE3A_BROKER_TICKER_AFFINITY_SNAPSHOT',
  source_verified boolean not null default true,
  provenance_state text not null default 'SHADOW_EVENT_CONDITIONED_FROM_VERIFIED_PHASE2_RESIDUALS',
  computed_at timestamptz not null default now(),
  primary key (as_of_date,lag_sessions),
  constraint flow_broker_ticker_affinity_snapshot_v3_lag_ck
    check (lag_sessions in (0,1,2,5)),
  constraint flow_broker_ticker_affinity_snapshot_v3_window_ck
    check (training_window_sessions between 160 and 220 and eligible_sessions >= 155)
);

create index if not exists flow_broker_ticker_affinity_snapshot_v3_date_idx
  on public.flow_broker_ticker_affinity_snapshot_v3 (as_of_date desc,lag_sessions);

alter table public.flow_broker_ticker_affinity_snapshot_v3 enable row level security;
revoke all on table public.flow_broker_ticker_affinity_snapshot_v3 from public, anon, authenticated;
grant select,insert,update,delete on table public.flow_broker_ticker_affinity_snapshot_v3 to service_role;

create or replace function public.flow_refresh_broker_ticker_affinity_v3(
  p_as_of_date date default ((now() at time zone 'Asia/Jakarta')::date),
  p_window_sessions integer default 200
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  phase2_state text;
  common_sessions integer := 0;
  common_first date;
  common_last date;
  lag_n integer;
  eligible_n integer;
  half_n integer;
  second_n integer;
  eligible_brokers_n integer := 0;
  eligible_tickers_n integer := 0;
  broker_ready_n integer := 0;
  stock_ready_n integer := 0;
  retained_n integer := 0;
  stable_n integer := 0;
  recent_n integer := 0;
  decaying_n integer := 0;
  mixed_n integer := 0;
  total_retained integer := 0;
  total_stable integer := 0;
begin
  if p_as_of_date is null then
    raise exception 'Phase3A as_of_date must not be null';
  end if;
  if p_window_sessions < 160 or p_window_sessions > 220 then
    raise exception 'Phase3A window must be 160..220 sessions, got %',p_window_sessions;
  end if;

  select phase2_gate_state into phase2_state
  from public.flow_phase2_quality_summary;
  if phase2_state is distinct from 'PHASE2_READY' then
    raise exception 'Phase3A requires PHASE2_READY, got %',coalesce(phase2_state,'NULL');
  end if;

  with common as (
    select trade_date
    from (
      select trade_date
      from public.flow_broker_market_regime_v2
      where trade_date<=p_as_of_date
      intersect
      select distinct trade_date
      from public.flow_stock_residual_activity_v2
      where trade_date<=p_as_of_date
    ) q
    order by trade_date desc
    limit p_window_sessions
  )
  select count(*)::integer,min(trade_date),max(trade_date)
    into common_sessions,common_first,common_last
  from common;

  if common_sessions < 160 then
    return jsonb_build_object(
      'as_of_date',p_as_of_date,
      'status','INSUFFICIENT_COMMON_SESSIONS',
      'common_sessions',common_sessions
    );
  end if;
  if common_last is distinct from p_as_of_date then
    return jsonb_build_object(
      'as_of_date',p_as_of_date,
      'status','NO_PHASE2_DATA_FOR_AS_OF',
      'latest_common_date',common_last
    );
  end if;

  delete from public.flow_broker_ticker_affinity_v3 where as_of_date=p_as_of_date;
  delete from public.flow_broker_ticker_affinity_snapshot_v3 where as_of_date=p_as_of_date;

  foreach lag_n in array array[0,1,2,5] loop
    eligible_n := common_sessions-lag_n;
    half_n := floor(eligible_n/2.0)::integer;
    second_n := eligible_n-half_n;

    with selected as (
      select trade_date
      from (
        select trade_date
        from public.flow_broker_market_regime_v2
        where trade_date<=p_as_of_date
        intersect
        select distinct trade_date
        from public.flow_stock_residual_activity_v2
        where trade_date<=p_as_of_date
      ) q
      order by trade_date desc
      limit p_window_sessions
    ), sessions as (
      select trade_date,row_number() over(order by trade_date)::integer seq
      from selected
    ), eligible_brokers as (
      select f.broker_code,max(d.broker_name) current_name
      from public.flow_broker_behavior_features_v2 f
      join sessions s using(trade_date)
      left join public.flow_official_broker_directory d using(broker_code)
      where s.seq<=eligible_n
        and f.feature_quality_state='MATURE'
        and f.source_verified
      group by f.broker_code
      having count(*)=eligible_n
    ), broker_events as (
      select f.broker_code,s.seq
      from public.flow_broker_behavior_features_v2 f
      join sessions s using(trade_date)
      join eligible_brokers e using(broker_code)
      where s.seq<=eligible_n
        and f.feature_quality_state='MATURE'
        and f.source_verified
        and f.residual_activity_z>=1.5
    ), broker_counts as (
      select
        broker_code,
        count(*)::integer b_events,
        count(*) filter(where seq<=half_n)::integer b_first,
        count(*) filter(where seq>half_n)::integer b_second
      from broker_events
      group by broker_code
      having count(*)>=12
    ), eligible_stocks as (
      select r.ticker
      from public.flow_stock_residual_activity_v2 r
      join sessions s using(trade_date)
      where s.seq>lag_n
        and r.source_verified
      group by r.ticker
      having count(*)=eligible_n
    ), stock_events as (
      select r.ticker,(s.seq-lag_n)::integer src_seq
      from public.flow_stock_residual_activity_v2 r
      join sessions s using(trade_date)
      join eligible_stocks e using(ticker)
      where s.seq>lag_n
        and r.source_verified
        and r.stock_residual_activity_z>=1.0
    ), stock_counts as (
      select
        ticker,
        count(*)::integer s_events,
        count(*) filter(where src_seq<=half_n)::integer s_first,
        count(*) filter(where src_seq>half_n)::integer s_second
      from stock_events
      group by ticker
      having count(*)>=10
    ), coevents as (
      select
        b.broker_code,
        s.ticker,
        count(*)::integer coevents,
        count(*) filter(where b.seq<=half_n)::integer c_first,
        count(*) filter(where b.seq>half_n)::integer c_second
      from broker_events b
      join stock_events s on s.src_seq=b.seq
      group by b.broker_code,s.ticker
      having count(*)>=5
    ), base_metrics as (
      select
        c.broker_code,
        c.ticker,
        c.coevents,
        c.c_first,
        c.c_second,
        bc.b_events,
        bc.b_first,
        bc.b_second,
        sc.s_events,
        sc.s_first,
        sc.s_second,
        (bc.b_events*sc.s_events/eligible_n::numeric) expected_all,
        (bc.b_first*sc.s_first/nullif(half_n,0)::numeric) expected_first,
        (bc.b_second*sc.s_second/nullif(second_n,0)::numeric) expected_second
      from coevents c
      join broker_counts bc using(broker_code)
      join stock_counts sc using(ticker)
    ), metrics as (
      select
        m.*,
        100::numeric*m.b_events/eligible_n broker_rate,
        100::numeric*m.s_events/eligible_n stock_rate,
        100::numeric*m.coevents/m.b_events conditional_hit,
        100::numeric*m.coevents/m.b_events - 100::numeric*m.s_events/eligible_n excess_hit,
        m.coevents/nullif(m.expected_all,0) lift_all,
        (m.coevents-m.expected_all)/nullif(
          sqrt(
            m.b_events*(m.s_events/eligible_n::numeric)*(1-m.s_events/eligible_n::numeric)*
            ((eligible_n-m.b_events)/nullif((eligible_n-1)::numeric,0))
          ),0
        ) z_all,
        m.c_first/nullif(m.expected_first,0) lift_first,
        (m.c_first-m.expected_first)/nullif(
          sqrt(
            m.b_first*(m.s_first/nullif(half_n,0)::numeric)*(1-m.s_first/nullif(half_n,0)::numeric)*
            ((half_n-m.b_first)/nullif((half_n-1)::numeric,0))
          ),0
        ) z_first,
        m.c_second/nullif(m.expected_second,0) lift_second,
        (m.c_second-m.expected_second)/nullif(
          sqrt(
            m.b_second*(m.s_second/nullif(second_n,0)::numeric)*(1-m.s_second/nullif(second_n,0)::numeric)*
            ((second_n-m.b_second)/nullif((second_n-1)::numeric,0))
          ),0
        ) z_second
      from base_metrics m
    ), retained as (
      select *,
        case
          when coalesce(lift_first,0)>=1.10 and coalesce(lift_second,0)>=1.10
            and (100::numeric*c_first/nullif(b_first,0)-100::numeric*s_first/nullif(half_n,0))>0
            and (100::numeric*c_second/nullif(b_second,0)-100::numeric*s_second/nullif(second_n,0))>0
            then 'STABLE'
          when coalesce(lift_second,0)>=1.50 and coalesce(z_second,0)>=1.50
            and coalesce(lift_first,0)<1.10
            then 'RECENT_STRENGTHENING'
          when coalesce(lift_first,0)>=1.50 and coalesce(z_first,0)>=1.50
            and coalesce(lift_second,0)<1.10
            then 'DECAYING'
          else 'MIXED'
        end stability_state
      from metrics
      where lift_all>=1.5
        and z_all>=2.5
        and excess_hit>=10
    ), scored as (
      select r.*,
        greatest(0::numeric,least(100::numeric,
          0.40*greatest(0::numeric,least(100::numeric,100::numeric*r.z_all/5::numeric))
          +0.25*greatest(0::numeric,least(100::numeric,100::numeric*(r.lift_all-1::numeric)/1.5::numeric))
          +0.20*greatest(0::numeric,least(100::numeric,100::numeric*r.excess_hit/30::numeric))
          +0.15*(case r.stability_state
                   when 'STABLE' then 100::numeric
                   when 'RECENT_STRENGTHENING' then 80::numeric
                   when 'MIXED' then 40::numeric
                   else 20::numeric
                 end)
        )) research_score
      from retained r
    )
    insert into public.flow_broker_ticker_affinity_v3 (
      as_of_date,lag_sessions,broker_code,ticker,broker_current_name,
      training_start_date,training_end_date,training_window_sessions,eligible_sessions,
      broker_event_count,stock_event_count,coevent_count,expected_coevent_count,
      broker_event_rate_pct,stock_event_rate_pct,conditional_hit_pct,excess_hit_pct,
      affinity_lift,affinity_z,first_half_lift,first_half_z,second_half_lift,second_half_z,
      stability_state,research_affinity_score,computed_at
    )
    select
      p_as_of_date,lag_n,s.broker_code,s.ticker,e.current_name,
      common_first,common_last,common_sessions,eligible_n,
      s.b_events,s.s_events,s.coevents,s.expected_all,
      s.broker_rate,s.stock_rate,s.conditional_hit,s.excess_hit,
      s.lift_all,s.z_all,s.lift_first,s.z_first,s.lift_second,s.z_second,
      s.stability_state,s.research_score,now()
    from scored s
    left join eligible_brokers e using(broker_code);

    get diagnostics retained_n=row_count;

    with selected as (
      select trade_date
      from (
        select trade_date
        from public.flow_broker_market_regime_v2
        where trade_date<=p_as_of_date
        intersect
        select distinct trade_date
        from public.flow_stock_residual_activity_v2
        where trade_date<=p_as_of_date
      ) q
      order by trade_date desc
      limit p_window_sessions
    ), sessions as (
      select trade_date,row_number() over(order by trade_date)::integer seq
      from selected
    ), b_coverage as (
      select f.broker_code,
             count(*) filter(where f.feature_quality_state='MATURE' and f.source_verified)::integer mature_n,
             count(*) filter(where f.feature_quality_state='MATURE' and f.source_verified and f.residual_activity_z>=1.5)::integer event_n
      from public.flow_broker_behavior_features_v2 f
      join sessions s using(trade_date)
      where s.seq<=eligible_n
      group by f.broker_code
    ), s_coverage as (
      select r.ticker,
             count(*) filter(where r.source_verified)::integer observed_n,
             count(*) filter(where r.source_verified and r.stock_residual_activity_z>=1.0)::integer event_n
      from public.flow_stock_residual_activity_v2 r
      join sessions s using(trade_date)
      where s.seq>lag_n
      group by r.ticker
    )
    select
      count(*) filter(where mature_n=eligible_n)::integer,
      count(*) filter(where mature_n=eligible_n and event_n>=12)::integer
      into eligible_brokers_n,broker_ready_n
    from b_coverage;

    with selected as (
      select trade_date
      from (
        select trade_date
        from public.flow_broker_market_regime_v2
        where trade_date<=p_as_of_date
        intersect
        select distinct trade_date
        from public.flow_stock_residual_activity_v2
        where trade_date<=p_as_of_date
      ) q
      order by trade_date desc
      limit p_window_sessions
    ), sessions as (
      select trade_date,row_number() over(order by trade_date)::integer seq
      from selected
    ), s_coverage as (
      select r.ticker,
             count(*) filter(where r.source_verified)::integer observed_n,
             count(*) filter(where r.source_verified and r.stock_residual_activity_z>=1.0)::integer event_n
      from public.flow_stock_residual_activity_v2 r
      join sessions s using(trade_date)
      where s.seq>lag_n
      group by r.ticker
    )
    select
      count(*) filter(where observed_n=eligible_n)::integer,
      count(*) filter(where observed_n=eligible_n and event_n>=10)::integer
      into eligible_tickers_n,stock_ready_n
    from s_coverage;

    select
      count(*) filter(where stability_state='STABLE')::integer,
      count(*) filter(where stability_state='RECENT_STRENGTHENING')::integer,
      count(*) filter(where stability_state='DECAYING')::integer,
      count(*) filter(where stability_state='MIXED')::integer
      into stable_n,recent_n,decaying_n,mixed_n
    from public.flow_broker_ticker_affinity_v3
    where as_of_date=p_as_of_date and lag_sessions=lag_n;

    insert into public.flow_broker_ticker_affinity_snapshot_v3 (
      as_of_date,lag_sessions,training_start_date,training_end_date,
      training_window_sessions,eligible_sessions,eligible_brokers,eligible_tickers,
      broker_event_ready_count,stock_event_ready_count,candidate_pairs_considered,
      retained_affinity_rows,stable_rows,recent_strengthening_rows,decaying_rows,mixed_rows,
      computed_at
    ) values (
      p_as_of_date,lag_n,common_first,common_last,
      common_sessions,eligible_n,eligible_brokers_n,eligible_tickers_n,
      broker_ready_n,stock_ready_n,(broker_ready_n::bigint*stock_ready_n::bigint),
      retained_n,stable_n,recent_n,decaying_n,mixed_n,now()
    );

    total_retained := total_retained+retained_n;
    total_stable := total_stable+stable_n;
  end loop;

  insert into public.flow_ingestion_audit (
    provider,dataset,started_at,completed_at,status,rows_received,rows_accepted,
    rows_rejected,freshness_date,details
  ) values (
    'IDX_OFFICIAL_DERIVED','BROKER_TICKER_AFFINITY_V3_SHADOW',now(),now(),'OK',
    total_retained,total_retained,0,p_as_of_date,
    jsonb_build_object(
      'phase','PHASE3A_EVENT_CONDITIONED_AFFINITY',
      'as_of_date',p_as_of_date,
      'window_sessions',common_sessions,
      'lags',jsonb_build_array(0,1,2,5),
      'broker_event_threshold',1.5,
      'stock_event_threshold',1.0,
      'retention_rule','COEVENTS_GE5__LIFT_GE1_5__Z_GE2_5__EXCESS_HIT_GE10PP',
      'association_semantics','CO_ACTIVITY_AFFINITY_NOT_BUY_SELL',
      'retained_rows',total_retained,
      'stable_rows',total_stable,
      'no_production_scoring_change',true
    )
  );

  return jsonb_build_object(
    'as_of_date',p_as_of_date,
    'status','OK',
    'window_sessions',common_sessions,
    'training_start_date',common_first,
    'training_end_date',common_last,
    'lags',jsonb_build_array(0,1,2,5),
    'retained_rows',total_retained,
    'stable_rows',total_stable,
    'association_semantics','CO_ACTIVITY_AFFINITY_NOT_BUY_SELL'
  );
end;
$$;

revoke all on function public.flow_refresh_broker_ticker_affinity_v3(date,integer)
  from public, anon, authenticated;
grant execute on function public.flow_refresh_broker_ticker_affinity_v3(date,integer)
  to service_role;

create or replace view public.flow_phase3a_quality_summary as
with latest as (
  select max(as_of_date) as_of_date
  from public.flow_broker_ticker_affinity_snapshot_v3
), s as (
  select
    x.as_of_date,
    count(*)::integer lag_count,
    min(eligible_brokers)::integer min_eligible_brokers,
    min(eligible_tickers)::integer min_eligible_tickers,
    min(broker_event_ready_count)::integer min_broker_event_ready,
    min(stock_event_ready_count)::integer min_stock_event_ready,
    sum(retained_affinity_rows)::bigint retained_rows,
    sum(stable_rows)::bigint stable_rows,
    count(*) filter(where not source_verified)::integer unverified_snapshots
  from public.flow_broker_ticker_affinity_snapshot_v3 x
  join latest l using(as_of_date)
  group by x.as_of_date
), m as (
  select
    count(*) filter(where not source_verified)::bigint unverified_affinity_rows,
    count(*) filter(where association_semantics<>'CO_ACTIVITY_AFFINITY_NOT_BUY_SELL')::bigint bad_semantics_rows
  from public.flow_broker_ticker_affinity_v3 a
  join latest l using(as_of_date)
), a as (
  select count(*) filter(where status='FAILED')::integer failed_audit_rows
  from public.flow_ingestion_audit i
  join latest l on i.freshness_date=l.as_of_date
  where i.provider='IDX_OFFICIAL_DERIVED'
    and i.dataset='BROKER_TICKER_AFFINITY_V3_SHADOW'
), p as (
  select phase2_gate_state,residual_sessions,last_residual_date
  from public.flow_phase2c_quality_summary c
  cross join public.flow_phase2_quality_summary q
)
select
  p.phase2_gate_state,
  s.as_of_date,
  p.last_residual_date as phase2_last_residual_date,
  s.lag_count,
  s.min_eligible_brokers,
  s.min_eligible_tickers,
  s.min_broker_event_ready,
  s.min_stock_event_ready,
  s.retained_rows,
  s.stable_rows,
  s.unverified_snapshots,
  m.unverified_affinity_rows,
  m.bad_semantics_rows,
  a.failed_audit_rows,
  case
    when p.phase2_gate_state='PHASE2_READY'
      and s.as_of_date=p.last_residual_date
      and s.lag_count=4
      and s.min_eligible_brokers>=80
      and s.min_eligible_tickers>=500
      and s.min_broker_event_ready>=75
      and s.min_stock_event_ready>=400
      and s.retained_rows>0
      and s.unverified_snapshots=0
      and m.unverified_affinity_rows=0
      and m.bad_semantics_rows=0
      and a.failed_audit_rows=0
      then 'PHASE3A_READY'
    else 'PHASE3A_NOT_READY'
  end as phase3a_gate_state
from p
left join s on true
cross join m
cross join a;

revoke all on public.flow_phase3a_quality_summary from public, anon, authenticated;
grant select on public.flow_phase3a_quality_summary to service_role;

create extension if not exists pg_cron;
do $$
declare r record;
begin
  for r in select jobid from cron.job where jobname='flow-broker-ticker-affinity-v3-shadow-daily' loop
    perform cron.unschedule(r.jobid);
  end loop;
  perform cron.schedule(
    'flow-broker-ticker-affinity-v3-shadow-daily',
    '16 11 * * 1-5',
    $cron$select public.flow_refresh_broker_ticker_affinity_v3((now() at time zone 'Asia/Jakarta')::date,200);$cron$
  );
end $$;
