-- Phase 1B: canonical IDX broker identity, rename history, and training-data quality gates.
-- This migration is evidence-foundation only. It does not change production scoring.

create table if not exists public.flow_official_broker_directory (
  broker_code text primary key,
  broker_name text not null,
  status_name text,
  is_active boolean not null default false,
  city text,
  license_text text,
  profile_url text not null,
  api_profile_path text,
  source text not null default 'IDX_OFFICIAL_EXCHANGE_MEMBER_DIRECTORY',
  source_verified boolean not null default true,
  source_url text not null,
  provenance_state text not null default 'VERIFIED_OFFICIAL_IDX_EXCHANGE_MEMBER_DIRECTORY',
  observed_on date not null default ((now() at time zone 'Asia/Jakarta')::date),
  retrieved_at timestamptz not null default now(),
  constraint flow_official_broker_directory_code_ck
    check (broker_code = upper(trim(broker_code)) and length(broker_code) between 1 and 8)
);

create index if not exists flow_official_broker_directory_active_idx
  on public.flow_official_broker_directory (is_active, broker_code);

alter table public.flow_official_broker_directory enable row level security;
revoke all on table public.flow_official_broker_directory from public, anon, authenticated;
grant select, insert, update, delete on table public.flow_official_broker_directory to service_role;

create or replace function public.flow_refresh_official_idx_broker_directory()
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, extensions
as $$
declare
  url constant text := 'https://block.idx.id/primary/ExchangeMember/GetBroker?length=200&start=0';
  payload jsonb;
  http_status integer;
  api_rows integer;
  records_total integer;
  distinct_codes integer;
  active_count integer;
  non_active_count integer;
  removed_count integer := 0;
  affected integer := 0;
begin
  select h.status, h.content::jsonb
    into http_status, payload
  from extensions.http_get(url) h;

  if http_status <> 200 then
    raise exception 'IDX broker directory HTTP %', http_status;
  end if;

  api_rows := coalesce(jsonb_array_length(coalesce(payload->'data','[]'::jsonb)),0);
  records_total := nullif(payload->>'recordsTotal','')::integer;

  if api_rows = 0 or records_total is null then
    raise exception 'IDX broker directory empty or missing recordsTotal';
  end if;
  if api_rows <> records_total then
    raise exception 'IDX broker directory incomplete page: rows %, total %', api_rows, records_total;
  end if;
  if api_rows < 80 or api_rows > 100 then
    raise exception 'IDX broker directory implausible row count: %', api_rows;
  end if;

  select count(distinct upper(trim(x->>'Code')))
    into distinct_codes
  from jsonb_array_elements(payload->'data') x
  where nullif(trim(x->>'Code'),'') is not null;

  if distinct_codes <> api_rows then
    raise exception 'IDX broker directory duplicate/blank code: rows %, distinct codes %',
      api_rows, distinct_codes;
  end if;

  if exists (
    select 1
    from jsonb_array_elements(payload->'data') x
    where nullif(trim(x->>'Name'),'') is null
       or nullif(trim(x->>'StatusName'),'') is null
       or nullif(trim(x->>'License'),'') is null
  ) then
    raise exception 'IDX broker directory contains missing name/status/license';
  end if;

  -- Reconcile current snapshot only after full validation. Historical identities
  -- stay preserved in flow_official_broker_activity and the views below.
  delete from public.flow_official_broker_directory d
  where not exists (
    select 1
    from jsonb_array_elements(payload->'data') x
    where upper(trim(x->>'Code')) = d.broker_code
  );
  get diagnostics removed_count = row_count;

  insert into public.flow_official_broker_directory
    (broker_code,broker_name,status_name,is_active,city,license_text,profile_url,
     api_profile_path,source,source_verified,source_url,provenance_state,observed_on,retrieved_at)
  select
    upper(trim(x->>'Code')),
    trim(x->>'Name'),
    trim(x->>'StatusName'),
    lower(trim(x->>'StatusName')) = 'aktif',
    nullif(trim(x->>'City'),''),
    nullif(trim(x->>'License'),''),
    'https://block.idx.id/id/anggota-bursa-dan-partisipan/profil-anggota-bursa/' || upper(trim(x->>'Code')),
    nullif(x->'Links'->0->>'Href',''),
    'IDX_OFFICIAL_EXCHANGE_MEMBER_DIRECTORY',
    true,
    url,
    'VERIFIED_OFFICIAL_IDX_EXCHANGE_MEMBER_DIRECTORY',
    (now() at time zone 'Asia/Jakarta')::date,
    now()
  from jsonb_array_elements(payload->'data') x
  on conflict (broker_code) do update set
    broker_name=excluded.broker_name,
    status_name=excluded.status_name,
    is_active=excluded.is_active,
    city=excluded.city,
    license_text=excluded.license_text,
    profile_url=excluded.profile_url,
    api_profile_path=excluded.api_profile_path,
    source=excluded.source,
    source_verified=excluded.source_verified,
    source_url=excluded.source_url,
    provenance_state=excluded.provenance_state,
    observed_on=excluded.observed_on,
    retrieved_at=excluded.retrieved_at;
  get diagnostics affected = row_count;

  select count(*) filter (where is_active),
         count(*) filter (where not is_active)
    into active_count, non_active_count
  from public.flow_official_broker_directory;

  insert into public.flow_ingestion_audit
    (provider,dataset,started_at,completed_at,status,rows_received,rows_accepted,
     rows_rejected,freshness_date,details)
  values
    ('IDX_OFFICIAL_BLOCK','BROKER_DIRECTORY',now(),now(),'OK',api_rows,affected,0,
     (now() at time zone 'Asia/Jakarta')::date,
     jsonb_build_object(
       'source','block.idx.id',
       'records_total',records_total,
       'active_brokers',active_count,
       'non_active_brokers',non_active_count,
       'removed_from_current_snapshot',removed_count,
       'phase','PHASE1B_BROKER_IDENTITY_QUALITY'
     ));

  return jsonb_build_object(
    'records_total',records_total,
    'rows_upserted',affected,
    'active_brokers',active_count,
    'non_active_brokers',non_active_count,
    'removed_from_current_snapshot',removed_count
  );
end;
$$;

revoke all on function public.flow_refresh_official_idx_broker_directory()
  from public, anon, authenticated;
grant execute on function public.flow_refresh_official_idx_broker_directory()
  to service_role;

-- Preserve contiguous broker-name periods exactly as observed in official Trading Summary.
-- This intentionally does not rewrite old names to the current directory name.
create or replace view public.flow_broker_identity_history as
with ordered as (
  select
    broker_code,
    trade_date,
    broker_name,
    upper(trim(regexp_replace(coalesce(broker_name,''),'\s+',' ','g'))) as normalized_name,
    lag(upper(trim(regexp_replace(coalesce(broker_name,''),'\s+',' ','g'))))
      over (partition by broker_code order by trade_date) as previous_name
  from public.flow_official_broker_activity
  where source='IDX_OFFICIAL_BROKER_SUMMARY'
    and source_verified
), marked as (
  select *,
    sum(case when previous_name is distinct from normalized_name then 1 else 0 end)
      over (partition by broker_code order by trade_date rows unbounded preceding) as identity_segment
  from ordered
), segments as (
  select
    broker_code,
    identity_segment,
    min(trade_date) valid_from,
    max(trade_date) valid_to,
    (array_agg(broker_name order by trade_date desc))[1] broker_name,
    count(*)::bigint sessions
  from marked
  group by broker_code, identity_segment
)
select
  s.broker_code,
  s.broker_name,
  s.valid_from,
  s.valid_to,
  s.sessions,
  (row_number() over (partition by s.broker_code order by s.valid_from desc) = 1) as latest_historical_identity,
  d.broker_name as current_directory_name,
  d.status_name as current_directory_status,
  d.is_active as current_directory_active,
  case
    when d.broker_code is null then 'HISTORICAL_ONLY'
    when upper(trim(regexp_replace(coalesce(s.broker_name,''),'\s+',' ','g'))) =
         upper(trim(regexp_replace(coalesce(d.broker_name,''),'\s+',' ','g'))) then 'EXACT_NAME_MATCH'
    else 'NAME_VARIANT_OR_RENAME'
  end as identity_reconciliation_state
from segments s
left join public.flow_official_broker_directory d using (broker_code);

revoke all on public.flow_broker_identity_history from public, anon, authenticated;
grant select on public.flow_broker_identity_history to service_role;

create or replace view public.flow_broker_identity_reconciliation as
with hist as (
  select
    broker_code,
    min(trade_date) first_seen,
    max(trade_date) last_seen,
    count(distinct trade_date)::bigint sessions,
    count(distinct upper(trim(regexp_replace(coalesce(broker_name,''),'\s+',' ','g'))))::integer name_variants,
    (array_agg(broker_name order by trade_date desc))[1] latest_historical_name
  from public.flow_official_broker_activity
  where source='IDX_OFFICIAL_BROKER_SUMMARY' and source_verified
  group by broker_code
), latest_date as (
  select max(trade_date) trade_date
  from public.flow_official_broker_activity
  where source='IDX_OFFICIAL_BROKER_SUMMARY' and source_verified
), latest_codes as (
  select distinct a.broker_code
  from public.flow_official_broker_activity a
  cross join latest_date l
  where a.source='IDX_OFFICIAL_BROKER_SUMMARY'
    and a.source_verified
    and a.trade_date=l.trade_date
)
select
  coalesce(d.broker_code,h.broker_code) broker_code,
  d.broker_name current_directory_name,
  h.latest_historical_name,
  d.status_name,
  d.is_active,
  d.city,
  d.license_text,
  h.first_seen,
  h.last_seen,
  h.sessions,
  coalesce(h.name_variants,0) name_variants,
  (l.broker_code is not null) seen_latest_trading_session,
  case
    when d.broker_code is null then 'HISTORICAL_ONLY'
    when h.broker_code is null then 'DIRECTORY_ONLY'
    when not d.is_active then 'DIRECTORY_NON_ACTIVE'
    when l.broker_code is null then 'ACTIVE_DIRECTORY_NOT_IN_LATEST_SESSION'
    when upper(trim(regexp_replace(coalesce(d.broker_name,''),'\s+',' ','g'))) =
         upper(trim(regexp_replace(coalesce(h.latest_historical_name,''),'\s+',' ','g'))) then 'MATCHED_CURRENT'
    else 'NAME_VARIANT_CURRENT'
  end as reconciliation_state
from public.flow_official_broker_directory d
full join hist h using (broker_code)
left join latest_codes l on l.broker_code=coalesce(d.broker_code,h.broker_code);

revoke all on public.flow_broker_identity_reconciliation from public, anon, authenticated;
grant select on public.flow_broker_identity_reconciliation to service_role;

-- Training-session quality is source/integrity based. Historical sessions are not
-- forced to equal today's 88 active members because membership changes over time.
create or replace view public.flow_broker_session_quality as
with session_stats as (
  select
    trade_date,
    count(*)::integer rows_seen,
    count(distinct broker_code)::integer broker_count,
    count(*) filter (where not source_verified)::integer unverified_rows,
    count(*) filter (where source_url is null or source_url not like 'https://block.idx.id/%')::integer bad_source_url_rows,
    count(*) filter (where broker_name is null or trim(broker_name)='')::integer missing_name_rows,
    count(*) filter (where traded_value < 0 or volume < 0 or frequency < 0)::integer negative_metric_rows
  from public.flow_official_broker_activity
  where source='IDX_OFFICIAL_BROKER_SUMMARY'
  group by trade_date
), active_directory as (
  select count(*)::integer active_brokers
  from public.flow_official_broker_directory
  where source_verified and is_active
), membership_overlap as (
  select
    a.trade_date,
    count(distinct a.broker_code) filter (where d.broker_code is not null)::integer current_directory_overlap,
    count(distinct a.broker_code) filter (where d.broker_code is null)::integer historical_only_codes
  from public.flow_official_broker_activity a
  left join public.flow_official_broker_directory d using (broker_code)
  where a.source='IDX_OFFICIAL_BROKER_SUMMARY' and a.source_verified
  group by a.trade_date
)
select
  s.trade_date,
  s.rows_seen,
  s.broker_count,
  a.active_brokers as current_active_directory_brokers,
  m.current_directory_overlap,
  m.historical_only_codes,
  round(100.0*s.broker_count/nullif(a.active_brokers,0),2) as count_vs_current_active_pct,
  s.unverified_rows,
  s.bad_source_url_rows,
  s.missing_name_rows,
  s.negative_metric_rows,
  case
    when s.unverified_rows > 0
      or s.bad_source_url_rows > 0
      or s.missing_name_rows > 0
      or s.negative_metric_rows > 0
      or s.rows_seen <> s.broker_count
      or s.broker_count < 80
      or s.broker_count > 100
      then 'FAIL'
    when s.broker_count < 85 or s.broker_count > 95 then 'WARN'
    else 'PASS'
  end as training_quality_state,
  case
    when s.unverified_rows > 0 then 'UNVERIFIED_SOURCE'
    when s.bad_source_url_rows > 0 then 'NON_OFFICIAL_SOURCE_URL'
    when s.missing_name_rows > 0 then 'MISSING_BROKER_NAME'
    when s.negative_metric_rows > 0 then 'NEGATIVE_ACTIVITY_METRIC'
    when s.rows_seen <> s.broker_count then 'DUPLICATE_BROKER_CODE'
    when s.broker_count < 80 then 'BROKER_COUNT_TOO_LOW'
    when s.broker_count > 100 then 'BROKER_COUNT_TOO_HIGH'
    when s.broker_count < 85 or s.broker_count > 95 then 'BROKER_COUNT_OUTSIDE_PREFERRED_RANGE'
    else 'CLEAN_OFFICIAL_SESSION'
  end as quality_reason
from session_stats s
cross join active_directory a
join membership_overlap m using (trade_date);

revoke all on public.flow_broker_session_quality from public, anon, authenticated;
grant select on public.flow_broker_session_quality to service_role;

create or replace view public.flow_phase1b_broker_quality_summary as
with d as (
  select
    count(*)::integer directory_total,
    count(*) filter (where is_active)::integer directory_active,
    count(*) filter (where not is_active)::integer directory_non_active,
    count(*) filter (where not source_verified)::integer directory_unverified,
    count(*) filter (where source_url not like 'https://block.idx.id/%')::integer directory_bad_url
  from public.flow_official_broker_directory
), h as (
  select count(distinct broker_code)::integer historical_codes
  from public.flow_official_broker_activity
  where source='IDX_OFFICIAL_BROKER_SUMMARY' and source_verified
), r as (
  select
    count(*) filter (where reconciliation_state='HISTORICAL_ONLY')::integer historical_only_codes,
    count(*) filter (where name_variants > 1)::integer multi_name_codes
  from public.flow_broker_identity_reconciliation
), q as (
  select
    count(*)::integer sessions,
    count(*) filter (where training_quality_state='PASS')::integer pass_sessions,
    count(*) filter (where training_quality_state='WARN')::integer warn_sessions,
    count(*) filter (where training_quality_state='FAIL')::integer fail_sessions,
    min(trade_date) first_session,
    max(trade_date) last_session
  from public.flow_broker_session_quality
)
select d.*,h.*,r.*,q.*,
  case
    when d.directory_total between 80 and 100
      and d.directory_active >= 80
      and d.directory_unverified=0
      and d.directory_bad_url=0
      and q.pass_sessions >= 250
      and q.fail_sessions=0
      then 'PHASE1B_READY'
    else 'PHASE1B_NOT_READY'
  end as phase1b_gate_state
from d cross join h cross join r cross join q;

revoke all on public.flow_phase1b_broker_quality_summary from public, anon, authenticated;
grant select on public.flow_phase1b_broker_quality_summary to service_role;

do $$
declare r record;
begin
  for r in select jobid from cron.job where jobname='flow-official-idx-broker-directory-daily' loop
    perform cron.unschedule(r.jobid);
  end loop;
  perform cron.schedule(
    'flow-official-idx-broker-directory-daily',
    '35 10 * * *',
    $cron$select public.flow_refresh_official_idx_broker_directory();$cron$
  );
end $$;
