-- Phase 3C: Broker Coalition Detector + coalition ticker/sector affinity profiles.
--
-- IMPORTANT SEMANTICS
-- IDX Broker Summary is market-wide broker activity without per-ticker buy/sell direction.
-- Coalitions here are statistical co-activity communities only. They must never be described
-- as brokers coordinating, buying, selling, accumulating, or distributing a ticker/sector.
--
-- This remains SHADOW research. It does NOT change final_score, production scoring,
-- production authorization, execution-ready semantics, runtime universe, or the existing
-- broker production overlay.

create table if not exists public.flow_broker_coalition_edges_v3 (
  as_of_date date not null,
  broker_a text not null,
  broker_b text not null,
  overlap_sessions integer not null,
  broker_a_event_count integer not null,
  broker_b_event_count integer not null,
  co_event_count integer not null,
  expected_co_events numeric not null,
  event_lift numeric not null,
  jaccard numeric not null,
  excess_z numeric not null,
  edge_strength_score numeric not null,
  mutual_rank_a integer not null,
  mutual_rank_b integer not null,
  association_semantics text not null default 'CO_ACTIVITY_COALITION_NOT_BUY_SELL',
  source text not null default 'DERIVED_PHASE3C_BROKER_COALITION_EDGE',
  source_verified boolean not null default true,
  provenance_state text not null default 'SHADOW_FROM_PHASE2_BROKER_RESIDUAL_ACTIVITY',
  computed_at timestamptz not null default now(),
  primary key (as_of_date,broker_a,broker_b),
  constraint flow_broker_coalition_edges_v3_order_ck check (broker_a < broker_b),
  constraint flow_broker_coalition_edges_v3_metric_ck check (
    overlap_sessions >= 190
    and broker_a_event_count >= 12
    and broker_b_event_count >= 12
    and co_event_count >= 10
    and expected_co_events > 0
    and event_lift >= 1.7
    and jaccard >= 0.15
    and excess_z >= 2.5
    and edge_strength_score between 0 and 100
    and mutual_rank_a between 1 and 2
    and mutual_rank_b between 1 and 2
  ),
  constraint flow_broker_coalition_edges_v3_semantics_ck
    check (association_semantics='CO_ACTIVITY_COALITION_NOT_BUY_SELL')
);

create index if not exists flow_broker_coalition_edges_v3_a_idx
  on public.flow_broker_coalition_edges_v3 (broker_a,as_of_date desc);
create index if not exists flow_broker_coalition_edges_v3_b_idx
  on public.flow_broker_coalition_edges_v3 (broker_b,as_of_date desc);
create index if not exists flow_broker_coalition_edges_v3_strength_idx
  on public.flow_broker_coalition_edges_v3 (as_of_date desc,edge_strength_score desc);

create table if not exists public.flow_broker_coalition_members_v3 (
  as_of_date date not null,
  coalition_id text not null,
  anchor_broker text not null,
  broker_code text not null,
  coalition_member_count integer not null,
  current_residual_activity_z numeric,
  current_activity_share_pct numeric,
  is_active boolean not null,
  association_semantics text not null default 'CO_ACTIVITY_COALITION_NOT_BUY_SELL',
  source text not null default 'DERIVED_PHASE3C_BROKER_COALITION_MEMBER',
  source_verified boolean not null default true,
  provenance_state text not null default 'SHADOW_FROM_PHASE3C_MUTUAL_TOP2_GRAPH',
  computed_at timestamptz not null default now(),
  primary key (as_of_date,coalition_id,broker_code),
  constraint flow_broker_coalition_members_v3_unique_broker unique (as_of_date,broker_code),
  constraint flow_broker_coalition_members_v3_count_ck check (coalition_member_count >= 2),
  constraint flow_broker_coalition_members_v3_semantics_ck
    check (association_semantics='CO_ACTIVITY_COALITION_NOT_BUY_SELL')
);

create index if not exists flow_broker_coalition_members_v3_broker_idx
  on public.flow_broker_coalition_members_v3 (broker_code,as_of_date desc);
create index if not exists flow_broker_coalition_members_v3_coalition_idx
  on public.flow_broker_coalition_members_v3 (as_of_date desc,coalition_id);

create table if not exists public.flow_broker_coalitions_v3 (
  as_of_date date not null,
  coalition_id text not null,
  anchor_broker text not null,
  member_count integer not null,
  edge_count integer not null,
  possible_edge_count integer not null,
  graph_density_pct numeric not null,
  mean_edge_strength numeric not null,
  min_edge_strength numeric not null,
  max_edge_strength numeric not null,
  active_member_count integer not null,
  active_member_pct numeric not null,
  active_activity_share_pct numeric not null,
  activation_state text not null,
  members text[] not null,
  association_semantics text not null default 'CO_ACTIVITY_COALITION_NOT_BUY_SELL',
  source text not null default 'DERIVED_PHASE3C_BROKER_COALITION',
  source_verified boolean not null default true,
  provenance_state text not null default 'SHADOW_FROM_PHASE3C_MUTUAL_TOP2_GRAPH',
  computed_at timestamptz not null default now(),
  primary key (as_of_date,coalition_id),
  constraint flow_broker_coalitions_v3_counts_ck check (
    member_count >= 2
    and edge_count >= 1
    and possible_edge_count = member_count*(member_count-1)/2
    and edge_count <= possible_edge_count
    and active_member_count between 0 and member_count
  ),
  constraint flow_broker_coalitions_v3_pct_ck check (
    graph_density_pct between 0 and 100
    and mean_edge_strength between 0 and 100
    and min_edge_strength between 0 and 100
    and max_edge_strength between 0 and 100
    and active_member_pct between 0 and 100
    and active_activity_share_pct between 0 and 100
  ),
  constraint flow_broker_coalitions_v3_activation_ck
    check (activation_state in ('DORMANT','PARTIAL','BROAD_ACTIVE')),
  constraint flow_broker_coalitions_v3_semantics_ck
    check (association_semantics='CO_ACTIVITY_COALITION_NOT_BUY_SELL')
);

create index if not exists flow_broker_coalitions_v3_active_idx
  on public.flow_broker_coalitions_v3 (as_of_date desc,activation_state,member_count desc);
create index if not exists flow_broker_coalitions_v3_strength_idx
  on public.flow_broker_coalitions_v3 (as_of_date desc,mean_edge_strength desc);

create table if not exists public.flow_broker_coalition_ticker_affinity_v3 (
  as_of_date date not null,
  coalition_id text not null,
  ticker text not null,
  sector text not null,
  coalition_member_count integer not null,
  affinity_member_count integer not null,
  affinity_member_pct numeric not null,
  stable_member_count integer not null,
  recent_strengthening_member_count integer not null,
  multi_lag_member_count integer not null,
  multi_lag_member_pct numeric not null,
  mean_member_affinity_score numeric not null,
  max_member_affinity_score numeric not null,
  coalition_ticker_profile_score numeric not null,
  association_semantics text not null default 'CO_ACTIVITY_COALITION_NOT_BUY_SELL',
  score_formula text not null default '50_MEMBER_BREADTH__35_MEAN_AFFINITY__15_MULTI_LAG',
  source text not null default 'DERIVED_PHASE3C_COALITION_TICKER_AFFINITY',
  source_verified boolean not null default true,
  provenance_state text not null default 'SHADOW_FROM_PHASE3A_STABLE_AFFINITY_AND_PHASE3C_COALITION',
  computed_at timestamptz not null default now(),
  primary key (as_of_date,coalition_id,ticker),
  constraint flow_broker_coalition_ticker_affinity_v3_counts_ck check (
    coalition_member_count >= 2
    and affinity_member_count between 2 and coalition_member_count
    and stable_member_count between 0 and affinity_member_count
    and recent_strengthening_member_count between 0 and affinity_member_count
    and multi_lag_member_count between 0 and affinity_member_count
  ),
  constraint flow_broker_coalition_ticker_affinity_v3_pct_ck check (
    affinity_member_pct between 0 and 100
    and multi_lag_member_pct between 0 and 100
    and mean_member_affinity_score between 0 and 100
    and max_member_affinity_score between 0 and 100
    and coalition_ticker_profile_score between 0 and 100
  ),
  constraint flow_broker_coalition_ticker_affinity_v3_semantics_ck
    check (association_semantics='CO_ACTIVITY_COALITION_NOT_BUY_SELL')
);

create index if not exists flow_broker_coalition_ticker_affinity_v3_score_idx
  on public.flow_broker_coalition_ticker_affinity_v3
  (as_of_date desc,coalition_ticker_profile_score desc);
create index if not exists flow_broker_coalition_ticker_affinity_v3_ticker_idx
  on public.flow_broker_coalition_ticker_affinity_v3 (ticker,as_of_date desc);
create index if not exists flow_broker_coalition_ticker_affinity_v3_coalition_idx
  on public.flow_broker_coalition_ticker_affinity_v3 (coalition_id,as_of_date desc);

create table if not exists public.flow_broker_coalition_sector_affinity_v3 (
  as_of_date date not null,
  coalition_id text not null,
  sector text not null,
  coalition_member_count integer not null,
  affinity_ticker_count integer not null,
  member_ticker_hits integer not null,
  sector_hit_share_pct numeric not null,
  mean_ticker_profile_score numeric not null,
  mean_member_affinity_score numeric not null,
  sector_profile_rank integer not null,
  association_semantics text not null default 'CO_ACTIVITY_COALITION_NOT_BUY_SELL',
  source text not null default 'DERIVED_PHASE3C_COALITION_SECTOR_AFFINITY',
  source_verified boolean not null default true,
  provenance_state text not null default 'SHADOW_FROM_PHASE3C_COALITION_TICKER_AFFINITY',
  computed_at timestamptz not null default now(),
  primary key (as_of_date,coalition_id,sector),
  constraint flow_broker_coalition_sector_affinity_v3_metric_ck check (
    coalition_member_count >= 2
    and affinity_ticker_count >= 1
    and member_ticker_hits >= 2
    and sector_hit_share_pct between 0 and 100
    and mean_ticker_profile_score between 0 and 100
    and mean_member_affinity_score between 0 and 100
    and sector_profile_rank >= 1
  ),
  constraint flow_broker_coalition_sector_affinity_v3_semantics_ck
    check (association_semantics='CO_ACTIVITY_COALITION_NOT_BUY_SELL')
);

create index if not exists flow_broker_coalition_sector_affinity_v3_rank_idx
  on public.flow_broker_coalition_sector_affinity_v3
  (as_of_date desc,coalition_id,sector_profile_rank);
create index if not exists flow_broker_coalition_sector_affinity_v3_sector_idx
  on public.flow_broker_coalition_sector_affinity_v3 (sector,as_of_date desc);

create table if not exists public.flow_broker_coalition_snapshot_v3 (
  as_of_date date primary key,
  window_sessions integer not null,
  eligible_broker_count integer not null,
  candidate_edge_count integer not null,
  retained_mutual_edge_count integer not null,
  coalition_count integer not null,
  coalition_ge3_count integer not null,
  max_member_count integer not null,
  active_coalition_count integer not null,
  ticker_profile_count integer not null,
  sector_profile_count integer not null,
  source text not null default 'DERIVED_PHASE3C_BROKER_COALITION_SNAPSHOT',
  source_verified boolean not null default true,
  provenance_state text not null default 'SHADOW_FROM_PHASE2_PHASE3A_PHASE3B',
  computed_at timestamptz not null default now(),
  constraint flow_broker_coalition_snapshot_v3_metric_ck check (
    window_sessions between 190 and 200
    and eligible_broker_count >= 0
    and candidate_edge_count >= retained_mutual_edge_count
    and retained_mutual_edge_count >= 0
    and coalition_count >= 0
    and coalition_ge3_count between 0 and coalition_count
    and max_member_count >= 0
    and active_coalition_count between 0 and coalition_count
    and ticker_profile_count >= 0
    and sector_profile_count >= 0
  )
);

alter table public.flow_broker_coalition_edges_v3 enable row level security;
alter table public.flow_broker_coalition_members_v3 enable row level security;
alter table public.flow_broker_coalitions_v3 enable row level security;
alter table public.flow_broker_coalition_ticker_affinity_v3 enable row level security;
alter table public.flow_broker_coalition_sector_affinity_v3 enable row level security;
alter table public.flow_broker_coalition_snapshot_v3 enable row level security;

revoke all on table public.flow_broker_coalition_edges_v3 from public, anon, authenticated;
revoke all on table public.flow_broker_coalition_members_v3 from public, anon, authenticated;
revoke all on table public.flow_broker_coalitions_v3 from public, anon, authenticated;
revoke all on table public.flow_broker_coalition_ticker_affinity_v3 from public, anon, authenticated;
revoke all on table public.flow_broker_coalition_sector_affinity_v3 from public, anon, authenticated;
revoke all on table public.flow_broker_coalition_snapshot_v3 from public, anon, authenticated;

grant select,insert,update,delete on table public.flow_broker_coalition_edges_v3 to service_role;
grant select,insert,update,delete on table public.flow_broker_coalition_members_v3 to service_role;
grant select,insert,update,delete on table public.flow_broker_coalitions_v3 to service_role;
grant select,insert,update,delete on table public.flow_broker_coalition_ticker_affinity_v3 to service_role;
grant select,insert,update,delete on table public.flow_broker_coalition_sector_affinity_v3 to service_role;
grant select,insert,update,delete on table public.flow_broker_coalition_snapshot_v3 to service_role;

create or replace function public.flow_refresh_broker_coalitions_v3(
  p_as_of_date date default ((now() at time zone 'Asia/Jakarta')::date)
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  phase3b_state text;
  phase3b_date date;
  window_n integer := 0;
  eligible_n integer := 0;
  candidate_n integer := 0;
  retained_n integer := 0;
  coalition_n integer := 0;
  coalition_ge3_n integer := 0;
  max_member_n integer := 0;
  active_coalition_n integer := 0;
  ticker_profile_n integer := 0;
  sector_profile_n integer := 0;
begin
  select phase3b_gate_state,as_of_date
    into phase3b_state,phase3b_date
  from public.flow_phase3b_quality_summary;

  if phase3b_state is distinct from 'PHASE3B_READY' then
    raise exception 'Phase3C requires PHASE3B_READY, got %',coalesce(phase3b_state,'NULL');
  end if;
  if phase3b_date is distinct from p_as_of_date then
    return jsonb_build_object(
      'as_of_date',p_as_of_date,
      'status','PHASE3B_AS_OF_MISMATCH',
      'phase3b_as_of_date',phase3b_date
    );
  end if;

  select count(*)::integer into window_n
  from (
    select distinct trade_date
    from public.flow_broker_behavior_features_v2
    where trade_date<=p_as_of_date
      and feature_quality_state='MATURE'
      and source_verified
    order by trade_date desc
    limit 200
  ) d;

  if window_n < 190 then
    return jsonb_build_object(
      'as_of_date',p_as_of_date,
      'status','INSUFFICIENT_MATURE_WINDOW',
      'window_sessions',window_n
    );
  end if;

  with dates as (
    select distinct trade_date
    from public.flow_broker_behavior_features_v2
    where trade_date<=p_as_of_date
      and feature_quality_state='MATURE'
      and source_verified
    order by trade_date desc
    limit 200
  ), events as (
    select f.trade_date,f.broker_code,(f.residual_activity_z>=1.5) as is_event
    from public.flow_broker_behavior_features_v2 f
    join dates d using(trade_date)
    where f.feature_quality_state='MATURE'
      and f.source_verified
  ), eligible as (
    select broker_code,count(*)::integer sessions,
           count(*) filter(where is_event)::integer event_count
    from events
    group by broker_code
    having count(*)>=190 and count(*) filter(where is_event)>=12
  )
  select count(*)::integer into eligible_n from eligible;

  if eligible_n < 20 then
    return jsonb_build_object(
      'as_of_date',p_as_of_date,
      'status','INSUFFICIENT_ELIGIBLE_BROKERS',
      'eligible_brokers',eligible_n
    );
  end if;

  delete from public.flow_broker_coalition_sector_affinity_v3 where as_of_date=p_as_of_date;
  delete from public.flow_broker_coalition_ticker_affinity_v3 where as_of_date=p_as_of_date;
  delete from public.flow_broker_coalition_members_v3 where as_of_date=p_as_of_date;
  delete from public.flow_broker_coalitions_v3 where as_of_date=p_as_of_date;
  delete from public.flow_broker_coalition_edges_v3 where as_of_date=p_as_of_date;
  delete from public.flow_broker_coalition_snapshot_v3 where as_of_date=p_as_of_date;

  with dates as (
    select distinct trade_date
    from public.flow_broker_behavior_features_v2
    where trade_date<=p_as_of_date
      and feature_quality_state='MATURE'
      and source_verified
    order by trade_date desc
    limit 200
  ), events as (
    select f.trade_date,f.broker_code,(f.residual_activity_z>=1.5) as is_event
    from public.flow_broker_behavior_features_v2 f
    join dates d using(trade_date)
    where f.feature_quality_state='MATURE'
      and f.source_verified
  ), eligible as (
    select broker_code,count(*)::integer sessions,
           count(*) filter(where is_event)::integer event_count
    from events
    group by broker_code
    having count(*)>=190 and count(*) filter(where is_event)>=12
  ), pairs as (
    select
      a.broker_code broker_a,
      b.broker_code broker_b,
      count(*)::integer overlap_sessions,
      count(*) filter(where a.is_event)::integer broker_a_events,
      count(*) filter(where b.is_event)::integer broker_b_events,
      count(*) filter(where a.is_event and b.is_event)::integer co_events
    from events a
    join events b
      on a.trade_date=b.trade_date and a.broker_code<b.broker_code
    join eligible ea on ea.broker_code=a.broker_code
    join eligible eb on eb.broker_code=b.broker_code
    group by a.broker_code,b.broker_code
  ), metrics as (
    select
      p.*,
      (broker_a_events::numeric*broker_b_events/nullif(overlap_sessions,0)) expected_co_events,
      co_events/nullif((broker_a_events::numeric*broker_b_events/nullif(overlap_sessions,0)),0) event_lift,
      co_events::numeric/nullif(broker_a_events+broker_b_events-co_events,0) jaccard,
      (co_events-(broker_a_events::numeric*broker_b_events/nullif(overlap_sessions,0)))
        /nullif(sqrt(
          (broker_a_events::numeric*broker_b_events/nullif(overlap_sessions,0))
          *(1-broker_a_events::numeric/nullif(overlap_sessions,0))
          *(1-broker_b_events::numeric/nullif(overlap_sessions,0))
        ),0) excess_z
    from pairs p
  ), candidates as (
    select
      m.*,
      greatest(0::numeric,least(100::numeric,
        35*least(event_lift/3,1)
        +35*least(excess_z/5,1)
        +20*least(jaccard/0.30,1)
        +10*least(co_events::numeric/20,1)
      )) edge_strength_score
    from metrics m
    where co_events>=10
      and event_lift>=1.7
      and jaccard>=0.15
      and excess_z>=2.5
  )
  select count(*)::integer into candidate_n from candidates;

  with dates as (
    select distinct trade_date
    from public.flow_broker_behavior_features_v2
    where trade_date<=p_as_of_date
      and feature_quality_state='MATURE'
      and source_verified
    order by trade_date desc
    limit 200
  ), events as (
    select f.trade_date,f.broker_code,(f.residual_activity_z>=1.5) as is_event
    from public.flow_broker_behavior_features_v2 f
    join dates d using(trade_date)
    where f.feature_quality_state='MATURE'
      and f.source_verified
  ), eligible as (
    select broker_code,count(*)::integer sessions,
           count(*) filter(where is_event)::integer event_count
    from events
    group by broker_code
    having count(*)>=190 and count(*) filter(where is_event)>=12
  ), pairs as (
    select
      a.broker_code broker_a,
      b.broker_code broker_b,
      count(*)::integer overlap_sessions,
      count(*) filter(where a.is_event)::integer broker_a_events,
      count(*) filter(where b.is_event)::integer broker_b_events,
      count(*) filter(where a.is_event and b.is_event)::integer co_events
    from events a
    join events b
      on a.trade_date=b.trade_date and a.broker_code<b.broker_code
    join eligible ea on ea.broker_code=a.broker_code
    join eligible eb on eb.broker_code=b.broker_code
    group by a.broker_code,b.broker_code
  ), metrics as (
    select
      p.*,
      (broker_a_events::numeric*broker_b_events/nullif(overlap_sessions,0)) expected_co_events,
      co_events/nullif((broker_a_events::numeric*broker_b_events/nullif(overlap_sessions,0)),0) event_lift,
      co_events::numeric/nullif(broker_a_events+broker_b_events-co_events,0) jaccard,
      (co_events-(broker_a_events::numeric*broker_b_events/nullif(overlap_sessions,0)))
        /nullif(sqrt(
          (broker_a_events::numeric*broker_b_events/nullif(overlap_sessions,0))
          *(1-broker_a_events::numeric/nullif(overlap_sessions,0))
          *(1-broker_b_events::numeric/nullif(overlap_sessions,0))
        ),0) excess_z
    from pairs p
  ), candidates as (
    select
      m.*,
      greatest(0::numeric,least(100::numeric,
        35*least(event_lift/3,1)
        +35*least(excess_z/5,1)
        +20*least(jaccard/0.30,1)
        +10*least(co_events::numeric/20,1)
      )) edge_strength_score
    from metrics m
    where co_events>=10
      and event_lift>=1.7
      and jaccard>=0.15
      and excess_z>=2.5
  ), directed as (
    select broker_a broker,broker_b other,edge_strength_score from candidates
    union all
    select broker_b,broker_a,edge_strength_score from candidates
  ), ranked as (
    select d.*,
           row_number() over(partition by broker order by edge_strength_score desc,other) mutual_rank
    from directed d
  ), mutual as (
    select
      a.broker broker_a,
      a.other broker_b,
      a.mutual_rank mutual_rank_a,
      b.mutual_rank mutual_rank_b
    from ranked a
    join ranked b on b.broker=a.other and b.other=a.broker
    where a.broker<a.other
      and a.mutual_rank<=2
      and b.mutual_rank<=2
  )
  insert into public.flow_broker_coalition_edges_v3 (
    as_of_date,broker_a,broker_b,overlap_sessions,broker_a_event_count,broker_b_event_count,
    co_event_count,expected_co_events,event_lift,jaccard,excess_z,edge_strength_score,
    mutual_rank_a,mutual_rank_b,computed_at
  )
  select
    p_as_of_date,c.broker_a,c.broker_b,c.overlap_sessions,c.broker_a_events,c.broker_b_events,
    c.co_events,c.expected_co_events,c.event_lift,c.jaccard,c.excess_z,c.edge_strength_score,
    m.mutual_rank_a,m.mutual_rank_b,now()
  from candidates c
  join mutual m using(broker_a,broker_b);

  get diagnostics retained_n=row_count;

  with recursive nodes as (
    select broker_a broker_code from public.flow_broker_coalition_edges_v3 where as_of_date=p_as_of_date
    union
    select broker_b from public.flow_broker_coalition_edges_v3 where as_of_date=p_as_of_date
  ), adjacency as (
    select broker_a src,broker_b dst from public.flow_broker_coalition_edges_v3 where as_of_date=p_as_of_date
    union all
    select broker_b,broker_a from public.flow_broker_coalition_edges_v3 where as_of_date=p_as_of_date
  ), reach(root,node) as (
    select broker_code,broker_code from nodes
    union
    select r.root,a.dst
    from reach r
    join adjacency a on a.src=r.node
  ), components as (
    select node broker_code,min(root) anchor_broker
    from reach
    group by node
  ), sizes as (
    select anchor_broker,count(*)::integer member_count
    from components
    group by anchor_broker
    having count(*)>=2
  )
  insert into public.flow_broker_coalition_members_v3 (
    as_of_date,coalition_id,anchor_broker,broker_code,coalition_member_count,
    current_residual_activity_z,current_activity_share_pct,is_active,computed_at
  )
  select
    p_as_of_date,'C_'||c.anchor_broker,c.anchor_broker,c.broker_code,s.member_count,
    f.residual_activity_z,f.activity_share_pct,
    coalesce(f.feature_quality_state='MATURE' and f.source_verified and f.residual_activity_z>=1.5,false),
    now()
  from components c
  join sizes s using(anchor_broker)
  left join public.flow_broker_behavior_features_v2 f
    on f.trade_date=p_as_of_date and f.broker_code=c.broker_code;

  with member_agg as (
    select
      coalition_id,
      min(anchor_broker) anchor_broker,
      count(*)::integer member_count,
      count(*) filter(where is_active)::integer active_member_count,
      coalesce(sum(current_activity_share_pct) filter(where is_active),0)::numeric active_activity_share_pct,
      array_agg(broker_code order by broker_code) members
    from public.flow_broker_coalition_members_v3
    where as_of_date=p_as_of_date
    group by coalition_id
  ), edge_agg as (
    select
      ma.coalition_id,
      count(*)::integer edge_count,
      avg(e.edge_strength_score)::numeric mean_edge_strength,
      min(e.edge_strength_score)::numeric min_edge_strength,
      max(e.edge_strength_score)::numeric max_edge_strength
    from public.flow_broker_coalition_edges_v3 e
    join public.flow_broker_coalition_members_v3 ma
      on ma.as_of_date=e.as_of_date and ma.broker_code=e.broker_a
    join public.flow_broker_coalition_members_v3 mb
      on mb.as_of_date=e.as_of_date and mb.broker_code=e.broker_b and mb.coalition_id=ma.coalition_id
    where e.as_of_date=p_as_of_date
    group by ma.coalition_id
  )
  insert into public.flow_broker_coalitions_v3 (
    as_of_date,coalition_id,anchor_broker,member_count,edge_count,possible_edge_count,
    graph_density_pct,mean_edge_strength,min_edge_strength,max_edge_strength,
    active_member_count,active_member_pct,active_activity_share_pct,activation_state,members,computed_at
  )
  select
    p_as_of_date,m.coalition_id,m.anchor_broker,m.member_count,e.edge_count,
    m.member_count*(m.member_count-1)/2,
    100::numeric*e.edge_count/nullif(m.member_count*(m.member_count-1)/2,0),
    e.mean_edge_strength,e.min_edge_strength,e.max_edge_strength,
    m.active_member_count,
    100::numeric*m.active_member_count/nullif(m.member_count,0),
    m.active_activity_share_pct,
    case
      when m.active_member_count>=2
        and 100::numeric*m.active_member_count/nullif(m.member_count,0)>=50 then 'BROAD_ACTIVE'
      when m.active_member_count>=1 then 'PARTIAL'
      else 'DORMANT'
    end,
    m.members,now()
  from member_agg m
  join edge_agg e using(coalition_id);

  with pair_affinity as (
    select
      a.broker_code,
      a.ticker,
      count(distinct a.lag_sessions)::integer lag_count,
      bool_or(a.stability_state='STABLE') has_stable,
      bool_or(a.stability_state='RECENT_STRENGTHENING') has_recent,
      max(a.research_affinity_score)::numeric best_affinity_score
    from public.flow_broker_ticker_affinity_v3 a
    where a.as_of_date=p_as_of_date
      and a.source_verified
      and a.association_semantics='CO_ACTIVITY_AFFINITY_NOT_BUY_SELL'
      and a.stability_state in ('STABLE','RECENT_STRENGTHENING')
    group by a.broker_code,a.ticker
  ), grouped as (
    select
      m.coalition_id,
      a.ticker,
      max(m.coalition_member_count)::integer coalition_member_count,
      count(distinct m.broker_code)::integer affinity_member_count,
      count(distinct m.broker_code) filter(where a.has_stable)::integer stable_member_count,
      count(distinct m.broker_code) filter(where a.has_recent)::integer recent_member_count,
      count(distinct m.broker_code) filter(where a.lag_count>=2)::integer multi_lag_member_count,
      avg(a.best_affinity_score)::numeric mean_affinity_score,
      max(a.best_affinity_score)::numeric max_affinity_score
    from public.flow_broker_coalition_members_v3 m
    join pair_affinity a on a.broker_code=m.broker_code
    where m.as_of_date=p_as_of_date
    group by m.coalition_id,a.ticker
    having count(distinct m.broker_code)>=2
  ), metrics as (
    select
      g.*,
      100::numeric*g.affinity_member_count/nullif(g.coalition_member_count,0) affinity_member_pct,
      100::numeric*g.multi_lag_member_count/nullif(g.affinity_member_count,0) multi_lag_member_pct
    from grouped g
  )
  insert into public.flow_broker_coalition_ticker_affinity_v3 (
    as_of_date,coalition_id,ticker,sector,coalition_member_count,affinity_member_count,
    affinity_member_pct,stable_member_count,recent_strengthening_member_count,
    multi_lag_member_count,multi_lag_member_pct,mean_member_affinity_score,
    max_member_affinity_score,coalition_ticker_profile_score,computed_at
  )
  select
    p_as_of_date,x.coalition_id,x.ticker,coalesce(r.sector,'UNKNOWN'),x.coalition_member_count,
    x.affinity_member_count,x.affinity_member_pct,x.stable_member_count,x.recent_member_count,
    x.multi_lag_member_count,x.multi_lag_member_pct,x.mean_affinity_score,x.max_affinity_score,
    greatest(0::numeric,least(100::numeric,
      0.50*x.affinity_member_pct
      +0.35*x.mean_affinity_score
      +0.15*x.multi_lag_member_pct
    )),
    now()
  from metrics x
  left join public.flow_stock_residual_activity_v2 r
    on r.trade_date=p_as_of_date and r.ticker=x.ticker and r.source_verified;

  get diagnostics ticker_profile_n=row_count;

  with sector_base as (
    select
      coalition_id,
      sector,
      max(coalition_member_count)::integer coalition_member_count,
      count(*)::integer affinity_ticker_count,
      sum(affinity_member_count)::integer member_ticker_hits,
      avg(coalition_ticker_profile_score)::numeric mean_ticker_profile_score,
      avg(mean_member_affinity_score)::numeric mean_member_affinity_score
    from public.flow_broker_coalition_ticker_affinity_v3
    where as_of_date=p_as_of_date
    group by coalition_id,sector
  ), totals as (
    select coalition_id,sum(member_ticker_hits)::numeric total_hits
    from sector_base
    group by coalition_id
  ), ranked as (
    select
      s.*,
      100::numeric*s.member_ticker_hits/nullif(t.total_hits,0) sector_hit_share_pct,
      row_number() over(
        partition by s.coalition_id
        order by s.member_ticker_hits desc,s.affinity_ticker_count desc,
                 s.mean_ticker_profile_score desc,s.sector
      )::integer sector_profile_rank
    from sector_base s
    join totals t using(coalition_id)
  )
  insert into public.flow_broker_coalition_sector_affinity_v3 (
    as_of_date,coalition_id,sector,coalition_member_count,affinity_ticker_count,
    member_ticker_hits,sector_hit_share_pct,mean_ticker_profile_score,
    mean_member_affinity_score,sector_profile_rank,computed_at
  )
  select
    p_as_of_date,coalition_id,sector,coalition_member_count,affinity_ticker_count,
    member_ticker_hits,sector_hit_share_pct,mean_ticker_profile_score,
    mean_member_affinity_score,sector_profile_rank,now()
  from ranked;

  get diagnostics sector_profile_n=row_count;

  select
    count(*)::integer,
    count(*) filter(where member_count>=3)::integer,
    coalesce(max(member_count),0)::integer,
    count(*) filter(where activation_state='BROAD_ACTIVE')::integer
  into coalition_n,coalition_ge3_n,max_member_n,active_coalition_n
  from public.flow_broker_coalitions_v3
  where as_of_date=p_as_of_date;

  insert into public.flow_broker_coalition_snapshot_v3 (
    as_of_date,window_sessions,eligible_broker_count,candidate_edge_count,
    retained_mutual_edge_count,coalition_count,coalition_ge3_count,max_member_count,
    active_coalition_count,ticker_profile_count,sector_profile_count,computed_at
  ) values (
    p_as_of_date,window_n,eligible_n,candidate_n,retained_n,coalition_n,
    coalition_ge3_n,max_member_n,active_coalition_n,ticker_profile_n,sector_profile_n,now()
  );

  insert into public.flow_ingestion_audit (
    provider,dataset,started_at,completed_at,status,rows_received,rows_accepted,
    rows_rejected,freshness_date,details
  ) values (
    'IDX_OFFICIAL_DERIVED','BROKER_COALITION_V3_SHADOW',now(),now(),'OK',
    candidate_n,retained_n,0,p_as_of_date,
    jsonb_build_object(
      'phase','PHASE3C_BROKER_COALITION_DETECTOR',
      'window_sessions',window_n,
      'eligible_brokers',eligible_n,
      'candidate_edges',candidate_n,
      'retained_mutual_top2_edges',retained_n,
      'coalitions',coalition_n,
      'coalitions_ge3',coalition_ge3_n,
      'max_member_count',max_member_n,
      'ticker_profiles',ticker_profile_n,
      'sector_profiles',sector_profile_n,
      'association_semantics','CO_ACTIVITY_COALITION_NOT_BUY_SELL',
      'no_production_scoring_change',true
    )
  );

  return jsonb_build_object(
    'as_of_date',p_as_of_date,
    'status','OK',
    'window_sessions',window_n,
    'eligible_brokers',eligible_n,
    'candidate_edges',candidate_n,
    'retained_mutual_top2_edges',retained_n,
    'coalitions',coalition_n,
    'coalitions_ge3',coalition_ge3_n,
    'max_member_count',max_member_n,
    'active_coalitions',active_coalition_n,
    'ticker_profiles',ticker_profile_n,
    'sector_profiles',sector_profile_n,
    'association_semantics','CO_ACTIVITY_COALITION_NOT_BUY_SELL'
  );
end;
$$;

revoke all on function public.flow_refresh_broker_coalitions_v3(date)
  from public, anon, authenticated;
grant execute on function public.flow_refresh_broker_coalitions_v3(date)
  to service_role;

create or replace view public.flow_phase3c_quality_summary as
with latest as (
  select max(as_of_date) as_of_date
  from public.flow_broker_coalition_snapshot_v3
), s as (
  select x.*
  from public.flow_broker_coalition_snapshot_v3 x
  join latest l using(as_of_date)
), integrity as (
  select
    (select count(*) from public.flow_broker_coalition_edges_v3 e join latest l using(as_of_date)
      where not e.source_verified or e.association_semantics<>'CO_ACTIVITY_COALITION_NOT_BUY_SELL')::integer
      bad_edge_rows,
    (select count(*) from public.flow_broker_coalitions_v3 c join latest l using(as_of_date)
      where not c.source_verified or c.association_semantics<>'CO_ACTIVITY_COALITION_NOT_BUY_SELL')::integer
      bad_coalition_rows,
    (select count(*) from public.flow_broker_coalition_ticker_affinity_v3 t join latest l using(as_of_date)
      where not t.source_verified or t.association_semantics<>'CO_ACTIVITY_COALITION_NOT_BUY_SELL')::integer
      bad_ticker_profile_rows,
    (select count(*) from public.flow_broker_coalition_sector_affinity_v3 x join latest l using(as_of_date)
      where not x.source_verified or x.association_semantics<>'CO_ACTIVITY_COALITION_NOT_BUY_SELL')::integer
      bad_sector_profile_rows,
    (select count(*) from (
      select m.as_of_date,m.broker_code,count(*) n
      from public.flow_broker_coalition_members_v3 m
      join latest l using(as_of_date)
      group by m.as_of_date,m.broker_code
      having count(*)>1
    ) q)::integer duplicate_member_rows
), audit as (
  select count(*) filter(where status='FAILED')::integer failed_audit_rows
  from public.flow_ingestion_audit i
  join latest l on i.freshness_date=l.as_of_date
  where i.provider='IDX_OFFICIAL_DERIVED'
    and i.dataset='BROKER_COALITION_V3_SHADOW'
), p as (
  select phase3b_gate_state,as_of_date phase3b_as_of_date
  from public.flow_phase3b_quality_summary
)
select
  p.phase3b_gate_state,
  p.phase3b_as_of_date,
  s.as_of_date,
  s.window_sessions,
  s.eligible_broker_count,
  s.candidate_edge_count,
  s.retained_mutual_edge_count,
  s.coalition_count,
  s.coalition_ge3_count,
  s.max_member_count,
  s.active_coalition_count,
  s.ticker_profile_count,
  s.sector_profile_count,
  integrity.bad_edge_rows,
  integrity.bad_coalition_rows,
  integrity.bad_ticker_profile_rows,
  integrity.bad_sector_profile_rows,
  integrity.duplicate_member_rows,
  audit.failed_audit_rows,
  case
    when p.phase3b_gate_state='PHASE3B_READY'
      and s.as_of_date=p.phase3b_as_of_date
      and s.window_sessions>=190
      and s.eligible_broker_count>=80
      and s.retained_mutual_edge_count between 15 and 80
      and s.coalition_count>=8
      and s.coalition_ge3_count>=3
      and s.max_member_count between 3 and 10
      and s.ticker_profile_count>=20
      and s.sector_profile_count>=10
      and integrity.bad_edge_rows=0
      and integrity.bad_coalition_rows=0
      and integrity.bad_ticker_profile_rows=0
      and integrity.bad_sector_profile_rows=0
      and integrity.duplicate_member_rows=0
      and audit.failed_audit_rows=0
      then 'PHASE3C_READY'
    else 'PHASE3C_NOT_READY'
  end phase3c_gate_state
from p
cross join s
cross join integrity
cross join audit;

revoke all on public.flow_phase3c_quality_summary from public, anon, authenticated;
grant select on public.flow_phase3c_quality_summary to service_role;

create extension if not exists pg_cron;
do $$
declare r record;
begin
  for r in select jobid from cron.job where jobname='flow-broker-coalition-v3-shadow-daily' loop
    perform cron.unschedule(r.jobid);
  end loop;
  perform cron.schedule(
    'flow-broker-coalition-v3-shadow-daily',
    '20 11 * * 1-5',
    $cron$select public.flow_refresh_broker_coalitions_v3((now() at time zone 'Asia/Jakarta')::date);$cron$
  );
end $$;
