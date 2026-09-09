-- Operational universe expansion only. Predictive attribution and Gate-15 remain shadow.
create table if not exists public.flow_operational_universe_contract_v1(
  operational_contract text primary key,
  source_universe_contract text not null references public.flow_universe_contract_v1(universe_contract),
  target_count integer not null check(target_count=900),
  enabled_from date not null,
  membership_definition text not null,
  ranking_eligibility_definition text not null,
  actionability_definition text not null,
  insufficient_history_definition text not null,
  runtime_ranking_enabled boolean not null,
  predictive_attribution_production_influence_enabled boolean not null default false
    check(predictive_attribution_production_influence_enabled=false),
  frozen_at timestamptz not null default statement_timestamp()
);

insert into public.flow_operational_universe_contract_v1(
  operational_contract,source_universe_contract,target_count,enabled_from,
  membership_definition,ranking_eligibility_definition,actionability_definition,
  insufficient_history_definition,runtime_ranking_enabled,
  predictive_attribution_production_influence_enabled
) values(
  'IDX_OPERATIONAL_TOP900_V1','TOP_900_UNIVERSE_V1',900,date '2026-09-09',
  'Exactly the 900 selected members from the latest CAPTURED prospective TOP_900_UNIVERSE_V1 snapshot. No current-membership historical backfill.',
  'Every selected member is attempted by the production scanner. A row enters the numeric ranking only when the existing evidence and minimum-price-history gates pass; missing evidence is never neutral-filled.',
  'Current tradeability and production actionability remain separate canonical fields. Ranking membership never bypasses risk, suspension, data-quality, authorization, or execution gates.',
  'Fewer than 80 valid recent price bars is INSUFFICIENT_HISTORY and fails closed until enough observations exist.',
  true,false
) on conflict(operational_contract) do update set
  source_universe_contract=excluded.source_universe_contract,
  target_count=excluded.target_count,
  enabled_from=excluded.enabled_from,
  membership_definition=excluded.membership_definition,
  ranking_eligibility_definition=excluded.ranking_eligibility_definition,
  actionability_definition=excluded.actionability_definition,
  insufficient_history_definition=excluded.insufficient_history_definition,
  runtime_ranking_enabled=excluded.runtime_ranking_enabled,
  predictive_attribution_production_influence_enabled=false;

create or replace function public.flow_load_operational_universe_v1()
returns table(
  snapshot_date date,
  ticker text,
  issuer_name text,
  sector text,
  subsector text,
  universe_rank integer,
  current_tradeable boolean,
  production_actionable boolean,
  data_quality_state text,
  liquidity_state text,
  selection_reason text,
  membership_state text,
  runtime_ranking_eligible boolean
)
language sql
stable
security invoker
set search_path=''
as $fn$
  with latest_captured as (
    select m.snapshot_date
    from public.flow_universe_capture_manifest_v1 m
    where m.universe_contract='TOP_900_UNIVERSE_V1'
      and m.capture_state='CAPTURED'
      and m.selected_count=900
    order by m.snapshot_date desc
    limit 1
  )
  select u.snapshot_date,u.ticker,u.issuer_name,u.sector,u.subsector,u.universe_rank,
         u.current_tradeable,u.production_actionable,u.data_quality_state,u.liquidity_state,
         u.selection_reason,u.membership_state,true as runtime_ranking_eligible
  from public.flow_universe_snapshot_v1 u
  join latest_captured l on l.snapshot_date=u.snapshot_date
  where u.universe_contract='TOP_900_UNIVERSE_V1'
    and u.selected_top900
    and u.universe_rank between 1 and 900
  order by u.universe_rank;
$fn$;

create or replace function public.flow_load_operational_prices_v1(
  p_tickers text[],
  p_limit integer default 120
)
returns table(ticker text,payload jsonb)
language sql
stable
security invoker
set search_path=''
as $fn$
  with requested as (
    select distinct upper(trim(x)) as ticker
    from unnest(coalesce(p_tickers,array[]::text[])) as x
    where trim(coalesce(x,''))<>''
    order by 1
    limit 900
  ), dedup as (
    select distinct on (s.ticker,s.trade_date)
      s.ticker,s.trade_date,s.open,s.high,s.low,s.close,s.volume
    from public.flow_official_stock_summary s
    join requested r on r.ticker=s.ticker
    where s.source_verified
      and s.close is not null
      and s.close>0
    order by s.ticker,s.trade_date desc,s.ingested_at desc,s.source asc
  ), ranked as (
    select d.*,row_number() over(partition by d.ticker order by d.trade_date desc) rn
    from dedup d
  )
  select r.ticker,
         jsonb_agg(jsonb_build_object(
           'trade_date',r.trade_date,
           'open',r.open,
           'high',r.high,
           'low',r.low,
           'close',r.close,
           'volume',r.volume
         ) order by r.trade_date) payload
  from ranked r
  where r.rn<=greatest(1,least(coalesce(p_limit,120),320))
  group by r.ticker
  order by r.ticker;
$fn$;

alter table public.flow_operational_universe_contract_v1 enable row level security;

revoke all on table public.flow_operational_universe_contract_v1
  from public,anon,authenticated;
grant select,insert,update,delete on table public.flow_operational_universe_contract_v1
  to service_role;

revoke all on function public.flow_load_operational_universe_v1(),
  public.flow_load_operational_prices_v1(text[],integer)
  from public,anon,authenticated;
grant execute on function public.flow_load_operational_universe_v1(),
  public.flow_load_operational_prices_v1(text[],integer)
  to service_role;
