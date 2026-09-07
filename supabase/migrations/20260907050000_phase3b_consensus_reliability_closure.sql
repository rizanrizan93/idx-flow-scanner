-- Phase 3B closure: reliability-calibrate the shadow consensus proxy.
-- A ticker with only 1-4 active broker-affinity matches must not rank like a true broad consensus.
-- Raw breadth, weighted breadth, affinity quality, and base proxy remain stored for audit.
-- Full reliability begins at five distinct active broker-affinity matches.
-- No production scoring/execution semantics are changed.

alter table public.flow_ticker_affinity_consensus_v3
  add column if not exists base_broker_consensus_proxy_score numeric,
  add column if not exists consensus_reliability_factor numeric,
  add column if not exists reliability_rule text;

alter table public.flow_ticker_affinity_consensus_v3
  alter column score_formula set default
    '30_BREADTH_CAP40__25_WEIGHTED_BREADTH_CAP35__20_AFFINITY_QUALITY__15_MULTI_LAG__10_STABILITY__X_RELIABILITY_FULL_AT_5_BROKERS';

update public.flow_ticker_affinity_consensus_v3
set reliability_rule='LINEAR_MATCH_COUNT__20PCT_PER_BROKER__FULL_AT_5'
where reliability_rule is null;

alter table public.flow_ticker_affinity_consensus_v3
  drop constraint if exists flow_ticker_affinity_consensus_v3_reliability_ck;
alter table public.flow_ticker_affinity_consensus_v3
  add constraint flow_ticker_affinity_consensus_v3_reliability_ck
  check (
    (base_broker_consensus_proxy_score is null or base_broker_consensus_proxy_score between 0 and 100)
    and (consensus_reliability_factor is null or consensus_reliability_factor between 0 and 1)
    and (
      base_broker_consensus_proxy_score is null
      or consensus_reliability_factor is null
      or broker_consensus_proxy_score <= base_broker_consensus_proxy_score + 0.000001
    )
  );

-- Preserve the already-tested Phase 3B builder as an internal base function.
alter function public.flow_refresh_ticker_affinity_consensus_v3(date)
  rename to flow_refresh_ticker_affinity_consensus_v3_base;

revoke all on function public.flow_refresh_ticker_affinity_consensus_v3_base(date)
  from public, anon, authenticated;
grant execute on function public.flow_refresh_ticker_affinity_consensus_v3_base(date)
  to service_role;

create or replace function public.flow_finalize_ticker_affinity_consensus_reliability_v3(
  p_as_of_date date
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  affected_n integer := 0;
  max_adjusted numeric := 0;
  max_base numeric := 0;
begin
  if p_as_of_date is null then
    raise exception 'Phase3B reliability as_of_date must not be null';
  end if;

  update public.flow_ticker_affinity_consensus_v3
  set
    base_broker_consensus_proxy_score=coalesce(
      base_broker_consensus_proxy_score,
      broker_consensus_proxy_score
    ),
    consensus_reliability_factor=least(
      1::numeric,
      affinity_active_broker_count/5::numeric
    ),
    reliability_rule='LINEAR_MATCH_COUNT__20PCT_PER_BROKER__FULL_AT_5',
    score_formula='30_BREADTH_CAP40__25_WEIGHTED_BREADTH_CAP35__20_AFFINITY_QUALITY__15_MULTI_LAG__10_STABILITY__X_RELIABILITY_FULL_AT_5_BROKERS',
    broker_consensus_proxy_score=coalesce(
      base_broker_consensus_proxy_score,
      broker_consensus_proxy_score
    ) * least(1::numeric,affinity_active_broker_count/5::numeric)
  where as_of_date=p_as_of_date;

  get diagnostics affected_n=row_count;

  with ranked as (
    select ticker,
           round((100::numeric*(percent_rank() over(order by broker_consensus_proxy_score))::numeric),2) rank_pct
    from public.flow_ticker_affinity_consensus_v3
    where as_of_date=p_as_of_date
  )
  update public.flow_ticker_affinity_consensus_v3 c
  set consensus_rank_pct=r.rank_pct
  from ranked r
  where c.as_of_date=p_as_of_date and c.ticker=r.ticker;

  select
    coalesce(max(broker_consensus_proxy_score),0),
    coalesce(max(base_broker_consensus_proxy_score),0)
  into max_adjusted,max_base
  from public.flow_ticker_affinity_consensus_v3
  where as_of_date=p_as_of_date;

  update public.flow_ticker_affinity_consensus_snapshot_v3
  set
    max_broker_consensus_proxy_score=max_adjusted,
    computed_at=now()
  where as_of_date=p_as_of_date;

  insert into public.flow_ingestion_audit (
    provider,dataset,started_at,completed_at,status,rows_received,rows_accepted,
    rows_rejected,freshness_date,details
  ) values (
    'IDX_OFFICIAL_DERIVED','TICKER_AFFINITY_CONSENSUS_V3_RELIABILITY',now(),now(),'OK',
    affected_n,affected_n,0,p_as_of_date,
    jsonb_build_object(
      'phase','PHASE3B_CONSENSUS_RELIABILITY_CLOSURE',
      'reliability_rule','LINEAR_MATCH_COUNT__20PCT_PER_BROKER__FULL_AT_5',
      'max_base_score',max_base,
      'max_adjusted_score',max_adjusted,
      'no_production_scoring_change',true
    )
  );

  return jsonb_build_object(
    'as_of_date',p_as_of_date,
    'status','OK',
    'rows',affected_n,
    'max_base_score',max_base,
    'max_adjusted_score',max_adjusted,
    'reliability_rule','LINEAR_MATCH_COUNT__20PCT_PER_BROKER__FULL_AT_5'
  );
end;
$$;

revoke all on function public.flow_finalize_ticker_affinity_consensus_reliability_v3(date)
  from public, anon, authenticated;
grant execute on function public.flow_finalize_ticker_affinity_consensus_reliability_v3(date)
  to service_role;

-- Restore the public service-role entry point as a wrapper so every refresh is finalized.
create or replace function public.flow_refresh_ticker_affinity_consensus_v3(
  p_as_of_date date default ((now() at time zone 'Asia/Jakarta')::date)
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  base_result jsonb;
  reliability_result jsonb;
begin
  base_result := public.flow_refresh_ticker_affinity_consensus_v3_base(p_as_of_date);
  if coalesce(base_result->>'status','') <> 'OK' then
    return base_result;
  end if;

  reliability_result := public.flow_finalize_ticker_affinity_consensus_reliability_v3(p_as_of_date);
  return base_result || jsonb_build_object(
    'max_base_consensus_proxy_score',reliability_result->'max_base_score',
    'max_broker_consensus_proxy_score',reliability_result->'max_adjusted_score',
    'reliability_rule',reliability_result->'reliability_rule'
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
    count(*) filter(where breadth_state in ('STRONG','BROAD'))::integer strong_or_broad_rows,
    count(*) filter(where base_broker_consensus_proxy_score is null or consensus_reliability_factor is null)::integer missing_reliability_rows,
    count(*) filter(where broker_consensus_proxy_score > base_broker_consensus_proxy_score + 0.000001)::integer reliability_violation_rows,
    count(*) filter(where affinity_active_broker_count>=5 and consensus_reliability_factor<>1)::integer full_breadth_reliability_violation_rows
  from public.flow_ticker_affinity_consensus_v3 x
  join latest l using(as_of_date)
), a as (
  select count(*) filter(where status='FAILED')::integer failed_audit_rows
  from public.flow_ingestion_audit i
  join latest l on i.freshness_date=l.as_of_date
  where i.provider='IDX_OFFICIAL_DERIVED'
    and i.dataset in (
      'TICKER_AFFINITY_CONSENSUS_V3_SHADOW',
      'TICKER_AFFINITY_CONSENSUS_V3_RELIABILITY'
    )
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
  c.missing_reliability_rows,
  c.reliability_violation_rows,
  c.full_breadth_reliability_violation_rows,
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
      and c.missing_reliability_rows=0
      and c.reliability_violation_rows=0
      and c.full_breadth_reliability_violation_rows=0
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
