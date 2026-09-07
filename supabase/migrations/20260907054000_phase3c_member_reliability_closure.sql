-- Phase 3C closure: distinguish 2-broker pairs from multi-broker coalitions and
-- reliability-calibrate coalition->ticker profile scores by independent member votes.
-- Raw/base profile scores remain stored for audit. This remains SHADOW-only.

alter table public.flow_broker_coalitions_v3
  add column if not exists structure_class text;

update public.flow_broker_coalitions_v3
set structure_class=case
  when member_count=2 then 'PAIR'
  when member_count between 3 and 4 then 'CLUSTER'
  else 'BROAD_CLUSTER'
end
where structure_class is null;

alter table public.flow_broker_coalitions_v3
  alter column structure_class set not null;
alter table public.flow_broker_coalitions_v3
  drop constraint if exists flow_broker_coalitions_v3_structure_class_ck;
alter table public.flow_broker_coalitions_v3
  add constraint flow_broker_coalitions_v3_structure_class_ck
  check (
    (member_count=2 and structure_class='PAIR')
    or (member_count between 3 and 4 and structure_class='CLUSTER')
    or (member_count>=5 and structure_class='BROAD_CLUSTER')
  );

alter table public.flow_broker_coalition_ticker_affinity_v3
  add column if not exists base_coalition_ticker_profile_score numeric,
  add column if not exists member_reliability_factor numeric,
  add column if not exists reliability_rule text;

alter table public.flow_broker_coalition_ticker_affinity_v3
  alter column score_formula set default
    '50_MEMBER_BREADTH__35_MEAN_AFFINITY__15_MULTI_LAG__X_MEMBER_RELIABILITY_FULL_AT_3';

alter table public.flow_broker_coalition_ticker_affinity_v3
  drop constraint if exists flow_broker_coalition_ticker_affinity_v3_reliability_ck;
alter table public.flow_broker_coalition_ticker_affinity_v3
  add constraint flow_broker_coalition_ticker_affinity_v3_reliability_ck
  check (
    (base_coalition_ticker_profile_score is null or base_coalition_ticker_profile_score between 0 and 100)
    and (member_reliability_factor is null or member_reliability_factor between 0 and 1)
    and (
      base_coalition_ticker_profile_score is null
      or member_reliability_factor is null
      or coalition_ticker_profile_score <= base_coalition_ticker_profile_score + 0.000001
    )
  );

alter function public.flow_refresh_broker_coalitions_v3(date)
  rename to flow_refresh_broker_coalitions_v3_base;

revoke all on function public.flow_refresh_broker_coalitions_v3_base(date)
  from public, anon, authenticated;
grant execute on function public.flow_refresh_broker_coalitions_v3_base(date)
  to service_role;

create or replace function public.flow_finalize_broker_coalition_reliability_v3(
  p_as_of_date date
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  coalition_rows integer := 0;
  ticker_rows integer := 0;
  sector_rows integer := 0;
  max_base numeric := 0;
  max_adjusted numeric := 0;
begin
  if p_as_of_date is null then
    raise exception 'Phase3C reliability as_of_date must not be null';
  end if;

  update public.flow_broker_coalitions_v3
  set structure_class=case
    when member_count=2 then 'PAIR'
    when member_count between 3 and 4 then 'CLUSTER'
    else 'BROAD_CLUSTER'
  end,
  computed_at=now()
  where as_of_date=p_as_of_date;
  get diagnostics coalition_rows=row_count;

  update public.flow_broker_coalition_ticker_affinity_v3
  set
    base_coalition_ticker_profile_score=coalesce(
      base_coalition_ticker_profile_score,
      coalition_ticker_profile_score
    ),
    member_reliability_factor=least(1::numeric,affinity_member_count/3::numeric),
    reliability_rule='INDEPENDENT_AFFINITY_MEMBERS__FULL_AT_3',
    score_formula='50_MEMBER_BREADTH__35_MEAN_AFFINITY__15_MULTI_LAG__X_MEMBER_RELIABILITY_FULL_AT_3',
    coalition_ticker_profile_score=coalesce(
      base_coalition_ticker_profile_score,
      coalition_ticker_profile_score
    ) * least(1::numeric,affinity_member_count/3::numeric),
    computed_at=now()
  where as_of_date=p_as_of_date;
  get diagnostics ticker_rows=row_count;

  delete from public.flow_broker_coalition_sector_affinity_v3
  where as_of_date=p_as_of_date;

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
  get diagnostics sector_rows=row_count;

  update public.flow_broker_coalition_snapshot_v3
  set sector_profile_count=sector_rows,computed_at=now()
  where as_of_date=p_as_of_date;

  select
    coalesce(max(base_coalition_ticker_profile_score),0),
    coalesce(max(coalition_ticker_profile_score),0)
  into max_base,max_adjusted
  from public.flow_broker_coalition_ticker_affinity_v3
  where as_of_date=p_as_of_date;

  insert into public.flow_ingestion_audit (
    provider,dataset,started_at,completed_at,status,rows_received,rows_accepted,
    rows_rejected,freshness_date,details
  ) values (
    'IDX_OFFICIAL_DERIVED','BROKER_COALITION_V3_RELIABILITY',now(),now(),'OK',
    ticker_rows,ticker_rows,0,p_as_of_date,
    jsonb_build_object(
      'phase','PHASE3C_MEMBER_RELIABILITY_CLOSURE',
      'coalition_rows',coalition_rows,
      'ticker_rows',ticker_rows,
      'sector_rows',sector_rows,
      'reliability_rule','INDEPENDENT_AFFINITY_MEMBERS__FULL_AT_3',
      'max_base_score',max_base,
      'max_adjusted_score',max_adjusted,
      'no_production_scoring_change',true
    )
  );

  return jsonb_build_object(
    'as_of_date',p_as_of_date,
    'status','OK',
    'coalition_rows',coalition_rows,
    'ticker_rows',ticker_rows,
    'sector_rows',sector_rows,
    'max_base_score',max_base,
    'max_adjusted_score',max_adjusted,
    'reliability_rule','INDEPENDENT_AFFINITY_MEMBERS__FULL_AT_3'
  );
end;
$$;

revoke all on function public.flow_finalize_broker_coalition_reliability_v3(date)
  from public, anon, authenticated;
grant execute on function public.flow_finalize_broker_coalition_reliability_v3(date)
  to service_role;

create or replace function public.flow_refresh_broker_coalitions_v3(
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
  base_result := public.flow_refresh_broker_coalitions_v3_base(p_as_of_date);
  if coalesce(base_result->>'status','') <> 'OK' then
    return base_result;
  end if;

  reliability_result := public.flow_finalize_broker_coalition_reliability_v3(p_as_of_date);
  return base_result || jsonb_build_object(
    'max_base_ticker_profile_score',reliability_result->'max_base_score',
    'max_ticker_profile_score',reliability_result->'max_adjusted_score',
    'member_reliability_rule',reliability_result->'reliability_rule'
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
      where not e.source_verified or e.association_semantics<>'CO_ACTIVITY_COALITION_NOT_BUY_SELL')::integer bad_edge_rows,
    (select count(*) from public.flow_broker_coalitions_v3 c join latest l using(as_of_date)
      where not c.source_verified or c.association_semantics<>'CO_ACTIVITY_COALITION_NOT_BUY_SELL')::integer bad_coalition_rows,
    (select count(*) from public.flow_broker_coalition_ticker_affinity_v3 t join latest l using(as_of_date)
      where not t.source_verified or t.association_semantics<>'CO_ACTIVITY_COALITION_NOT_BUY_SELL')::integer bad_ticker_profile_rows,
    (select count(*) from public.flow_broker_coalition_sector_affinity_v3 x join latest l using(as_of_date)
      where not x.source_verified or x.association_semantics<>'CO_ACTIVITY_COALITION_NOT_BUY_SELL')::integer bad_sector_profile_rows,
    (select count(*) from (
      select m.as_of_date,m.broker_code,count(*) n
      from public.flow_broker_coalition_members_v3 m
      join latest l using(as_of_date)
      group by m.as_of_date,m.broker_code
      having count(*)>1
    ) q)::integer duplicate_member_rows,
    (select count(*) from public.flow_broker_coalitions_v3 c join latest l using(as_of_date)
      where structure_class is null
        or (member_count=2 and structure_class<>'PAIR')
        or (member_count between 3 and 4 and structure_class<>'CLUSTER')
        or (member_count>=5 and structure_class<>'BROAD_CLUSTER'))::integer bad_structure_class_rows,
    (select count(*) from public.flow_broker_coalition_ticker_affinity_v3 t join latest l using(as_of_date)
      where base_coalition_ticker_profile_score is null
         or member_reliability_factor is null
         or reliability_rule is null)::integer missing_reliability_rows,
    (select count(*) from public.flow_broker_coalition_ticker_affinity_v3 t join latest l using(as_of_date)
      where coalition_ticker_profile_score > base_coalition_ticker_profile_score + 0.000001
         or abs(member_reliability_factor-least(1::numeric,affinity_member_count/3::numeric))>0.000001)::integer reliability_violation_rows
), audit as (
  select count(*) filter(where status='FAILED')::integer failed_audit_rows
  from public.flow_ingestion_audit i
  join latest l on i.freshness_date=l.as_of_date
  where i.provider='IDX_OFFICIAL_DERIVED'
    and i.dataset in ('BROKER_COALITION_V3_SHADOW','BROKER_COALITION_V3_RELIABILITY')
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
      and integrity.bad_structure_class_rows=0
      and integrity.missing_reliability_rows=0
      and integrity.reliability_violation_rows=0
      and audit.failed_audit_rows=0
      then 'PHASE3C_READY'
    else 'PHASE3C_NOT_READY'
  end phase3c_gate_state,
  integrity.bad_structure_class_rows,
  integrity.missing_reliability_rows,
  integrity.reliability_violation_rows
from p
cross join s
cross join integrity
cross join audit;

revoke all on public.flow_phase3c_quality_summary from public, anon, authenticated;
grant select on public.flow_phase3c_quality_summary to service_role;
