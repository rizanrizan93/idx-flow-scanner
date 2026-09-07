-- Phase 3B: ticker-level Broker Affinity Breadth + Multi-Lag Consensus Proxy.
--
-- IMPORTANT SEMANTICS
-- IDX Broker Summary is market-wide broker activity without per-ticker buy/sell direction.
-- This layer aggregates only historical CO-ACTIVITY affinity from Phase 3A. It must never
-- be described as brokers buying, selling, accumulating, or distributing a ticker.
--
-- This remains SHADOW research. It does NOT change final_score, production scoring,
-- authorization, execution-ready semantics, or the existing broker production overlay.
-- Foreign/stock-flow fields are retained as confirmation evidence only and are NOT weighted
-- into the Phase 3B proxy score.

create table if not exists public.flow_ticker_affinity_consensus_v3 (
  as_of_date date not null,
  ticker text not null,
  active_broker_count integer not null,
  active_broker_activity_share_pct numeric not null,
  affinity_active_broker_count integer not null,
  stable_affinity_broker_count integer not null,
  recent_strengthening_broker_count integer not null,
  multi_lag_broker_count integer not null,
  lag0_broker_count integer not null,
  lag1_broker_count integer not null,
  lag2_broker_count integer not null,
  lag5_broker_count integer not null,
  raw_affinity_breadth_pct numeric not null,
  activity_weighted_breadth_pct numeric not null,
  weighted_affinity_score numeric not null,
  mean_affinity_score numeric not null,
  multi_lag_confirmation_pct numeric not null,
  stable_confirmation_pct numeric not null,
  breadth_state text not null,
  broker_consensus_proxy_score numeric not null,
  consensus_rank_pct numeric,
  stock_residual_activity_z numeric,
  turnover_residual_z numeric,
  volume_residual_z numeric,
  frequency_residual_z numeric,
  foreign_net_volume_pct numeric,
  return_pct numeric,
  stock_residual_quality_state text,
  association_semantics text not null default 'CO_ACTIVITY_AFFINITY_NOT_BUY_SELL',
  score_formula text not null default '30_BREADTH_CAP40__25_WEIGHTED_BREADTH_CAP35__20_AFFINITY_QUALITY__15_MULTI_LAG__10_STABILITY',
  source text not null default 'DERIVED_PHASE3B_TICKER_AFFINITY_CONSENSUS',
  source_verified boolean not null default true,
  provenance_state text not null default 'SHADOW_FROM_PHASE3A_AFFINITY_AND_PHASE2_CURRENT_ACTIVITY',
  computed_at timestamptz not null default now(),
  primary key (as_of_date,ticker),
  constraint flow_ticker_affinity_consensus_v3_breadth_state_ck
    check (breadth_state in ('WEAK','MODERATE','STRONG','BROAD')),
  constraint flow_ticker_affinity_consensus_v3_semantics_ck
    check (association_semantics='CO_ACTIVITY_AFFINITY_NOT_BUY_SELL'),
  constraint flow_ticker_affinity_consensus_v3_counts_ck
    check (
      active_broker_count > 0
      and affinity_active_broker_count between 1 and active_broker_count
      and stable_affinity_broker_count between 0 and affinity_active_broker_count
      and recent_strengthening_broker_count between 0 and affinity_active_broker_count
      and multi_lag_broker_count between 0 and affinity_active_broker_count
      and lag0_broker_count between 0 and affinity_active_broker_count
      and lag1_broker_count between 0 and affinity_active_broker_count
      and lag2_broker_count between 0 and affinity_active_broker_count
      and lag5_broker_count between 0 and affinity_active_broker_count
    ),
  constraint flow_ticker_affinity_consensus_v3_pct_ck
    check (
      active_broker_activity_share_pct between 0 and 100
      and raw_affinity_breadth_pct between 0 and 100
      and activity_weighted_breadth_pct between 0 and 100
      and weighted_affinity_score between 0 and 100
      and mean_affinity_score between 0 and 100
      and multi_lag_confirmation_pct between 0 and 100
      and stable_confirmation_pct between 0 and 100
      and broker_consensus_proxy_score between 0 and 100
      and (consensus_rank_pct is null or consensus_rank_pct between 0 and 100)
    )
);

create index if not exists flow_ticker_affinity_consensus_v3_score_idx
  on public.flow_ticker_affinity_consensus_v3
  (as_of_date desc,broker_consensus_proxy_score desc);
create index if not exists flow_ticker_affinity_consensus_v3_breadth_idx
  on public.flow_ticker_affinity_consensus_v3
  (as_of_date desc,breadth_state,affinity_active_broker_count desc);
create index if not exists flow_ticker_affinity_consensus_v3_ticker_idx
  on public.flow_ticker_affinity_consensus_v3
  (ticker,as_of_date desc);

alter table public.flow_ticker_affinity_consensus_v3 enable row level security;
revoke all on table public.flow_ticker_affinity_consensus_v3 from public, anon, authenticated;
grant select,insert,update,delete on table public.flow_ticker_affinity_consensus_v3 to service_role;

create table if not exists public.flow_ticker_affinity_consensus_snapshot_v3 (
  as_of_date date primary key,
  phase3a_affinity_rows integer not null,
  active_broker_count integer not null,
  active_broker_activity_share_pct numeric not null,
  consensus_ticker_count integer not null,
  broad_ticker_count integer not null,
  strong_ticker_count integer not null,
  moderate_ticker_count integer not null,
  weak_ticker_count integer not null,
  max_affinity_active_brokers integer not null,
  max_activity_weighted_breadth_pct numeric not null,
  max_broker_consensus_proxy_score numeric not null,
  source text not null default 'DERIVED_PHASE3B_TICKER_AFFINITY_CONSENSUS_SNAPSHOT',
  source_verified boolean not null default true,
  provenance_state text not null default 'SHADOW_FROM_PHASE3A_AFFINITY_AND_PHASE2_CURRENT_ACTIVITY',
  computed_at timestamptz not null default now()
);

alter table public.flow_ticker_affinity_consensus_snapshot_v3 enable row level security;
revoke all on table public.flow_ticker_affinity_consensus_snapshot_v3 from public, anon, authenticated;
grant select,insert,update,delete on table public.flow_ticker_affinity_consensus_snapshot_v3 to service_role;

create or replace function public.flow_refresh_ticker_affinity_consensus_v3(
  p_as_of_date date default ((now() at time zone 'Asia/Jakarta')::date)
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  phase3a_state text;
  phase3a_date date;
  active_n integer := 0;
  active_share numeric := 0;
  affinity_rows_n integer := 0;
  inserted_n integer := 0;
  broad_n integer := 0;
  strong_n integer := 0;
  moderate_n integer := 0;
  weak_n integer := 0;
  max_brokers integer := 0;
  max_weighted_breadth numeric := 0;
  max_proxy numeric := 0;
begin
  select phase3a_gate_state,as_of_date
    into phase3a_state,phase3a_date
  from public.flow_phase3a_quality_summary;

  if phase3a_state is distinct from 'PHASE3A_READY' then
    raise exception 'Phase3B requires PHASE3A_READY, got %',coalesce(phase3a_state,'NULL');
  end if;
  if phase3a_date is distinct from p_as_of_date then
    return jsonb_build_object(
      'as_of_date',p_as_of_date,
      'status','PHASE3A_AS_OF_MISMATCH',
      'phase3a_as_of_date',phase3a_date
    );
  end if;

  select count(*)::integer,coalesce(sum(activity_share_pct),0)::numeric
    into active_n,active_share
  from public.flow_broker_behavior_features_v2
  where trade_date=p_as_of_date
    and feature_quality_state='MATURE'
    and source_verified
    and residual_activity_z>=1.5;

  if active_n < 5 or active_share<=0 then
    return jsonb_build_object(
      'as_of_date',p_as_of_date,
      'status','INSUFFICIENT_ACTIVE_BROKER_COHORT',
      'active_brokers',active_n,
      'active_activity_share_pct',active_share
    );
  end if;

  select count(*)::integer into affinity_rows_n
  from public.flow_broker_ticker_affinity_v3
  where as_of_date=p_as_of_date
    and source_verified;

  delete from public.flow_ticker_affinity_consensus_v3 where as_of_date=p_as_of_date;
  delete from public.flow_ticker_affinity_consensus_snapshot_v3 where as_of_date=p_as_of_date;

  with active as (
    select broker_code,residual_activity_z,activity_share_pct
    from public.flow_broker_behavior_features_v2
    where trade_date=p_as_of_date
      and feature_quality_state='MATURE'
      and source_verified
      and residual_activity_z>=1.5
  ), affinity as (
    select broker_code,ticker,lag_sessions,stability_state,research_affinity_score
    from public.flow_broker_ticker_affinity_v3
    where as_of_date=p_as_of_date
      and source_verified
      and association_semantics='CO_ACTIVITY_AFFINITY_NOT_BUY_SELL'
      and stability_state in ('STABLE','RECENT_STRENGTHENING')
  ), pair_agg as (
    select
      a.broker_code,
      a.ticker,
      count(distinct a.lag_sessions)::integer lag_count,
      count(*) filter(where a.stability_state='STABLE')::integer stable_lag_count,
      count(*) filter(where a.stability_state='RECENT_STRENGTHENING')::integer recent_lag_count,
      bool_or(a.lag_sessions=0) lag0,
      bool_or(a.lag_sessions=1) lag1,
      bool_or(a.lag_sessions=2) lag2,
      bool_or(a.lag_sessions=5) lag5,
      max(a.research_affinity_score)::numeric best_affinity_score,
      avg(a.research_affinity_score)::numeric mean_pair_affinity_score
    from affinity a
    join active x using(broker_code)
    group by a.broker_code,a.ticker
  ), ticker_agg as (
    select
      p.ticker,
      count(*)::integer matched_brokers,
      count(*) filter(where p.stable_lag_count>0)::integer stable_brokers,
      count(*) filter(where p.recent_lag_count>0)::integer recent_brokers,
      count(*) filter(where p.lag_count>=2)::integer multi_lag_brokers,
      count(*) filter(where p.lag0)::integer lag0_brokers,
      count(*) filter(where p.lag1)::integer lag1_brokers,
      count(*) filter(where p.lag2)::integer lag2_brokers,
      count(*) filter(where p.lag5)::integer lag5_brokers,
      sum(x.activity_share_pct)::numeric matched_activity_share,
      coalesce(
        sum(x.activity_share_pct*p.best_affinity_score)/nullif(sum(x.activity_share_pct),0),
        avg(p.best_affinity_score)
      )::numeric weighted_affinity,
      avg(p.best_affinity_score)::numeric mean_affinity
    from pair_agg p
    join active x using(broker_code)
    group by p.ticker
  ), metrics as (
    select
      t.*,
      100::numeric*t.matched_brokers/active_n::numeric raw_breadth,
      100::numeric*t.matched_activity_share/nullif(active_share,0) weighted_breadth,
      100::numeric*t.multi_lag_brokers/nullif(t.matched_brokers,0) multi_lag_pct,
      100::numeric*t.stable_brokers/nullif(t.matched_brokers,0) stable_pct
    from ticker_agg t
  ), scored as (
    select
      m.*,
      greatest(0::numeric,least(100::numeric,100::numeric*m.raw_breadth/40::numeric)) breadth_component,
      greatest(0::numeric,least(100::numeric,100::numeric*m.weighted_breadth/35::numeric)) weighted_breadth_component,
      case
        when m.raw_breadth>=25 then 'BROAD'
        when m.raw_breadth>=15 then 'STRONG'
        when m.raw_breadth>=8 then 'MODERATE'
        else 'WEAK'
      end breadth_state,
      greatest(0::numeric,least(100::numeric,
        0.30*greatest(0::numeric,least(100::numeric,100::numeric*m.raw_breadth/40::numeric))
        +0.25*greatest(0::numeric,least(100::numeric,100::numeric*m.weighted_breadth/35::numeric))
        +0.20*m.weighted_affinity
        +0.15*m.multi_lag_pct
        +0.10*m.stable_pct
      )) proxy_score
    from metrics m
  )
  insert into public.flow_ticker_affinity_consensus_v3 (
    as_of_date,ticker,active_broker_count,active_broker_activity_share_pct,
    affinity_active_broker_count,stable_affinity_broker_count,recent_strengthening_broker_count,
    multi_lag_broker_count,lag0_broker_count,lag1_broker_count,lag2_broker_count,lag5_broker_count,
    raw_affinity_breadth_pct,activity_weighted_breadth_pct,weighted_affinity_score,mean_affinity_score,
    multi_lag_confirmation_pct,stable_confirmation_pct,breadth_state,broker_consensus_proxy_score,
    stock_residual_activity_z,turnover_residual_z,volume_residual_z,frequency_residual_z,
    foreign_net_volume_pct,return_pct,stock_residual_quality_state,computed_at
  )
  select
    p_as_of_date,s.ticker,active_n,active_share,
    s.matched_brokers,s.stable_brokers,s.recent_brokers,s.multi_lag_brokers,
    s.lag0_brokers,s.lag1_brokers,s.lag2_brokers,s.lag5_brokers,
    s.raw_breadth,s.weighted_breadth,s.weighted_affinity,s.mean_affinity,
    s.multi_lag_pct,s.stable_pct,s.breadth_state,s.proxy_score,
    r.stock_residual_activity_z,r.turnover_residual_z,r.volume_residual_z,r.frequency_residual_z,
    r.foreign_net_volume_pct,r.return_pct,r.residual_quality_state,now()
  from scored s
  left join public.flow_stock_residual_activity_v2 r
    on r.trade_date=p_as_of_date and r.ticker=s.ticker and r.source_verified;

  get diagnostics inserted_n=row_count;

  with ranked as (
    select ticker,
           round(100::numeric*percent_rank() over(order by broker_consensus_proxy_score),2) rank_pct
    from public.flow_ticker_affinity_consensus_v3
    where as_of_date=p_as_of_date
  )
  update public.flow_ticker_affinity_consensus_v3 c
  set consensus_rank_pct=r.rank_pct
  from ranked r
  where c.as_of_date=p_as_of_date and c.ticker=r.ticker;

  select
    count(*) filter(where breadth_state='BROAD')::integer,
    count(*) filter(where breadth_state='STRONG')::integer,
    count(*) filter(where breadth_state='MODERATE')::integer,
    count(*) filter(where breadth_state='WEAK')::integer,
    coalesce(max(affinity_active_broker_count),0)::integer,
    coalesce(max(activity_weighted_breadth_pct),0)::numeric,
    coalesce(max(broker_consensus_proxy_score),0)::numeric
  into broad_n,strong_n,moderate_n,weak_n,max_brokers,max_weighted_breadth,max_proxy
  from public.flow_ticker_affinity_consensus_v3
  where as_of_date=p_as_of_date;

  insert into public.flow_ticker_affinity_consensus_snapshot_v3 (
    as_of_date,phase3a_affinity_rows,active_broker_count,active_broker_activity_share_pct,
    consensus_ticker_count,broad_ticker_count,strong_ticker_count,moderate_ticker_count,weak_ticker_count,
    max_affinity_active_brokers,max_activity_weighted_breadth_pct,max_broker_consensus_proxy_score,
    computed_at
  ) values (
    p_as_of_date,affinity_rows_n,active_n,active_share,
    inserted_n,broad_n,strong_n,moderate_n,weak_n,
    max_brokers,max_weighted_breadth,max_proxy,now()
  );

  insert into public.flow_ingestion_audit (
    provider,dataset,started_at,completed_at,status,rows_received,rows_accepted,
    rows_rejected,freshness_date,details
  ) values (
    'IDX_OFFICIAL_DERIVED','TICKER_AFFINITY_CONSENSUS_V3_SHADOW',now(),now(),'OK',
    affinity_rows_n,inserted_n,0,p_as_of_date,
    jsonb_build_object(
      'phase','PHASE3B_TICKER_AFFINITY_CONSENSUS',
      'as_of_date',p_as_of_date,
      'active_brokers',active_n,
      'active_activity_share_pct',active_share,
      'consensus_tickers',inserted_n,
      'broad_tickers',broad_n,
      'strong_tickers',strong_n,
      'association_semantics','CO_ACTIVITY_AFFINITY_NOT_BUY_SELL',
      'foreign_and_stock_fields_confirmation_only',true,
      'no_production_scoring_change',true
    )
  );

  return jsonb_build_object(
    'as_of_date',p_as_of_date,
    'status','OK',
    'active_brokers',active_n,
    'active_activity_share_pct',active_share,
    'consensus_tickers',inserted_n,
    'broad_tickers',broad_n,
    'strong_tickers',strong_n,
    'max_affinity_active_brokers',max_brokers,
    'max_activity_weighted_breadth_pct',max_weighted_breadth,
    'max_broker_consensus_proxy_score',max_proxy,
    'association_semantics','CO_ACTIVITY_AFFINITY_NOT_BUY_SELL'
  );
end;
$$;

revoke all on function public.flow_refresh_ticker_affinity_consensus_v3(date)
  from public, anon, authenticated;
grant execute on function public.flow_refresh_ticker_affinity_consensus_v3(date)
  to service_role;

create or replace view public.flow_phase3b_quality_summary as
with latest as (
  select max(as_of_date) as_of_date
  from public.flow_ticker_affinity_consensus_snapshot_v3
), s as (
  select x.*
  from public.flow_ticker_affinity_consensus_snapshot_v3 x
  join latest l using(as_of_date)
), c as (
  select
    count(*)::integer consensus_rows,
    count(*) filter(where not source_verified)::integer unverified_rows,
    count(*) filter(where association_semantics<>'CO_ACTIVITY_AFFINITY_NOT_BUY_SELL')::integer bad_semantics_rows,
    count(*) filter(where stock_residual_activity_z is null)::integer missing_stock_confirmation_rows,
    count(*) filter(where breadth_state in ('STRONG','BROAD'))::integer strong_or_broad_rows
  from public.flow_ticker_affinity_consensus_v3 x
  join latest l using(as_of_date)
), a as (
  select count(*) filter(where status='FAILED')::integer failed_audit_rows
  from public.flow_ingestion_audit i
  join latest l on i.freshness_date=l.as_of_date
  where i.provider='IDX_OFFICIAL_DERIVED'
    and i.dataset='TICKER_AFFINITY_CONSENSUS_V3_SHADOW'
), p as (
  select phase3a_gate_state,as_of_date phase3a_as_of_date
  from public.flow_phase3a_quality_summary
)
select
  p.phase3a_gate_state,
  p.phase3a_as_of_date,
  s.as_of_date,
  s.active_broker_count,
  s.active_broker_activity_share_pct,
  s.consensus_ticker_count,
  s.broad_ticker_count,
  s.strong_ticker_count,
  s.max_affinity_active_brokers,
  s.max_activity_weighted_breadth_pct,
  s.max_broker_consensus_proxy_score,
  c.consensus_rows,
  c.strong_or_broad_rows,
  c.unverified_rows,
  c.bad_semantics_rows,
  c.missing_stock_confirmation_rows,
  a.failed_audit_rows,
  case
    when p.phase3a_gate_state='PHASE3A_READY'
      and s.as_of_date=p.phase3a_as_of_date
      and s.active_broker_count between 10 and 60
      and s.consensus_ticker_count>=100
      and s.max_affinity_active_brokers>=5
      and c.strong_or_broad_rows>0
      and c.unverified_rows=0
      and c.bad_semantics_rows=0
      and c.missing_stock_confirmation_rows=0
      and a.failed_audit_rows=0
      then 'PHASE3B_READY'
    else 'PHASE3B_NOT_READY'
  end phase3b_gate_state
from p
cross join s
cross join c
cross join a;

revoke all on public.flow_phase3b_quality_summary from public, anon, authenticated;
grant select on public.flow_phase3b_quality_summary to service_role;

create extension if not exists pg_cron;
do $$
declare r record;
begin
  for r in select jobid from cron.job where jobname='flow-ticker-affinity-consensus-v3-shadow-daily' loop
    perform cron.unschedule(r.jobid);
  end loop;
  perform cron.schedule(
    'flow-ticker-affinity-consensus-v3-shadow-daily',
    '18 11 * * 1-5',
    $cron$select public.flow_refresh_ticker_affinity_consensus_v3((now() at time zone 'Asia/Jakarta')::date);$cron$
  );
end $$;
