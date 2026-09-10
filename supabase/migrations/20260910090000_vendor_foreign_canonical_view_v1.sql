-- Storage remediation: the verified IDX Stock Summary foreign-flow fields are
-- already canonical in flow_official_stock_summary.  flow_vendor_foreign_flows
-- historically materialized the same official rows a second time.  Preserve the
-- public read contract as a security-invoker view, retain alternate-vendor and
-- unmatched historical transport rows physically, and keep per-session official
-- transport metadata so provenance remains auditable.
--
-- Preconditions are fail-closed.  No overlapping row is compacted unless the
-- foreign buy/sell, volume and traded value are exactly equal to the canonical
-- official stock-summary row.  There must be no FK dependency on the physical
-- table and no unknown source class.

do $do$
declare
  v_relkind "char";
  v_fk_refs integer;
  v_unknown_sources integer;
  v_mismatch_rows bigint;
begin
  select c.relkind into v_relkind
  from pg_class c join pg_namespace n on n.oid=c.relnamespace
  where n.nspname='public' and c.relname='flow_vendor_foreign_flows';
  if v_relkind is distinct from 'r'::"char" then
    raise exception 'flow_vendor_foreign_flows must be a physical table before V1 compaction';
  end if;

  select count(*)::integer into v_fk_refs
  from pg_constraint
  where contype='f'
    and (conrelid='public.flow_vendor_foreign_flows'::regclass
      or confrelid='public.flow_vendor_foreign_flows'::regclass);
  if v_fk_refs<>0 then
    raise exception 'vendor foreign compaction denied: % FK references exist',v_fk_refs;
  end if;

  select count(*)::integer into v_unknown_sources
  from public.flow_vendor_foreign_flows
  where source not in('IDX_OFFICIAL_STOCK_SUMMARY','ZAPI_IDX_FOREIGN_FLOW','ZAPI_IDX_STOCK_SUMMARY');
  if v_unknown_sources<>0 then
    raise exception 'vendor foreign compaction denied: % rows use unknown sources',v_unknown_sources;
  end if;

  select count(*)::bigint into v_mismatch_rows
  from public.flow_vendor_foreign_flows v
  join public.flow_official_stock_summary s
    on s.ticker=v.ticker and s.trade_date=v.trade_date
   and s.source='IDX_OFFICIAL_STOCK_SUMMARY' and s.source_verified
  where v.source='IDX_OFFICIAL_STOCK_SUMMARY' and v.source_verified
    and (v.foreign_buy is distinct from s.foreign_buy
      or v.foreign_sell is distinct from s.foreign_sell
      or v.volume is distinct from s.volume
      or v.traded_value is distinct from s.traded_value);
  if v_mismatch_rows<>0 then
    raise exception 'vendor foreign compaction denied: % overlapping official rows differ',v_mismatch_rows;
  end if;
end
$do$;

create table if not exists public.flow_vendor_foreign_official_transport_meta_v1(
  trade_date date primary key,
  source_url text not null,
  provenance_state text not null,
  retrieved_at timestamptz not null,
  source_row_count integer not null check(source_row_count>0),
  captured_at timestamptz not null default statement_timestamp()
);

insert into public.flow_vendor_foreign_official_transport_meta_v1(
  trade_date,source_url,provenance_state,retrieved_at,source_row_count
)
select trade_date,min(source_url),min(provenance_state),min(retrieved_at),count(*)::integer
from public.flow_vendor_foreign_flows
where source='IDX_OFFICIAL_STOCK_SUMMARY' and source_verified
group by trade_date
on conflict(trade_date) do update set
  source_url=excluded.source_url,
  provenance_state=excluded.provenance_state,
  retrieved_at=excluded.retrieved_at,
  source_row_count=excluded.source_row_count,
  captured_at=statement_timestamp();

-- Every official transport date historically had exactly one retrieval/provenance
-- tuple, so one compact metadata row per date is lossless for these fields.
do $do$
declare v_bad_dates integer;
begin
  select count(*)::integer into v_bad_dates
  from(
    select trade_date
    from public.flow_vendor_foreign_flows
    where source='IDX_OFFICIAL_STOCK_SUMMARY' and source_verified
    group by trade_date
    having count(distinct retrieved_at)<>1
       or count(distinct source_url)<>1
       or count(distinct provenance_state)<>1
  ) x;
  if v_bad_dates<>0 then
    raise exception 'official foreign transport metadata is not date-constant for % dates',v_bad_dates;
  end if;
end
$do$;

create table if not exists public.flow_vendor_foreign_compaction_manifest_v1(
  compaction_contract text primary key,
  before_rows bigint not null,
  retained_physical_rows bigint not null,
  reconstructed_official_rows bigint not null,
  logical_view_rows bigint not null,
  removed_redundant_rows bigint not null,
  mismatch_rows bigint not null check(mismatch_rows=0),
  before_bytes bigint not null,
  after_transport_bytes bigint not null,
  metadata_bytes bigint not null,
  retained_sha256 text not null check(length(retained_sha256)=64),
  details jsonb not null,
  compacted_at timestamptz not null default statement_timestamp(),
  production_influence_enabled boolean not null default false
    check(production_influence_enabled=false)
);

create temporary table flow_vendor_foreign_compaction_stats_v1 on commit drop as
select
  count(*)::bigint before_rows,
  pg_total_relation_size('public.flow_vendor_foreign_flows'::regclass)::bigint before_bytes,
  count(*) filter(
    where v.source='IDX_OFFICIAL_STOCK_SUMMARY' and v.source_verified
      and exists(
        select 1 from public.flow_official_stock_summary s
        where s.ticker=v.ticker and s.trade_date=v.trade_date
          and s.source='IDX_OFFICIAL_STOCK_SUMMARY' and s.source_verified
          and s.foreign_buy is not distinct from v.foreign_buy
          and s.foreign_sell is not distinct from v.foreign_sell
          and s.volume is not distinct from v.volume
          and s.traded_value is not distinct from v.traded_value
      )
  )::bigint removed_redundant_rows
from public.flow_vendor_foreign_flows v;

create temporary table flow_vendor_foreign_transport_keep_v1 on commit drop as
select v.*
from public.flow_vendor_foreign_flows v
where v.source<>'IDX_OFFICIAL_STOCK_SUMMARY'
   or not v.source_verified
   or not exists(
      select 1 from public.flow_official_stock_summary s
      where s.ticker=v.ticker and s.trade_date=v.trade_date
        and s.source='IDX_OFFICIAL_STOCK_SUMMARY' and s.source_verified
        and s.foreign_buy is not distinct from v.foreign_buy
        and s.foreign_sell is not distinct from v.foreign_sell
        and s.volume is not distinct from v.volume
        and s.traded_value is not distinct from v.traded_value
   );

create temporary table flow_vendor_foreign_keep_digest_v1 on commit drop as
select encode(extensions.digest(convert_to(coalesce(string_agg(
  concat_ws('|',ticker,trade_date::text,foreign_buy::text,foreign_sell::text,
    foreign_net::text,flow_unit,market_type,source,source_verified::text,
    coalesce(source_url,''),coalesce(provenance_state,''),retrieved_at::text,
    volume::text,traded_value::text),E'\n' order by ticker,trade_date,source,market_type),''),
  'UTF8'),'sha256'),'hex') retained_sha256
from flow_vendor_foreign_transport_keep_v1;

alter table public.flow_vendor_foreign_flows
  rename to flow_vendor_foreign_transport_v1;

truncate table public.flow_vendor_foreign_transport_v1;
insert into public.flow_vendor_foreign_transport_v1(
  ticker,trade_date,foreign_buy,foreign_sell,foreign_net,flow_unit,market_type,
  source,source_verified,source_url,provenance_state,retrieved_at,volume,traded_value
)
select ticker,trade_date,foreign_buy,foreign_sell,foreign_net,flow_unit,market_type,
  source,source_verified,source_url,provenance_state,retrieved_at,volume,traded_value
from flow_vendor_foreign_transport_keep_v1
order by ticker,trade_date,source,market_type;

analyze public.flow_vendor_foreign_transport_v1;

create view public.flow_vendor_foreign_flows
with (security_invoker=true)
as
select
  s.ticker,
  s.trade_date,
  s.foreign_buy,
  s.foreign_sell,
  (s.foreign_buy-s.foreign_sell)::numeric as foreign_net,
  'SHARES'::text as flow_unit,
  'ALL'::text as market_type,
  'IDX_OFFICIAL_STOCK_SUMMARY'::text as source,
  true as source_verified,
  coalesce(m.source_url,s.source_url) as source_url,
  coalesce(m.provenance_state,'VERIFIED_OFFICIAL_IDX_STOCK_SUMMARY_SHARE_FLOW'::text) as provenance_state,
  coalesce(m.retrieved_at,s.ingested_at) as retrieved_at,
  s.volume,
  s.traded_value
from public.flow_official_stock_summary s
join public.flow_issuers i on i.ticker=s.ticker
left join public.flow_vendor_foreign_official_transport_meta_v1 m
  on m.trade_date=s.trade_date
where s.source='IDX_OFFICIAL_STOCK_SUMMARY' and s.source_verified
union all
select
  t.ticker,t.trade_date,t.foreign_buy,t.foreign_sell,t.foreign_net,t.flow_unit,
  t.market_type,t.source,t.source_verified,t.source_url,t.provenance_state,
  t.retrieved_at,t.volume,t.traded_value
from public.flow_vendor_foreign_transport_v1 t;

revoke all on table public.flow_vendor_foreign_flows from public,anon,authenticated;
grant select on table public.flow_vendor_foreign_flows to service_role;

alter table public.flow_vendor_foreign_official_transport_meta_v1 enable row level security;
alter table public.flow_vendor_foreign_compaction_manifest_v1 enable row level security;
revoke all on table public.flow_vendor_foreign_official_transport_meta_v1,
  public.flow_vendor_foreign_compaction_manifest_v1 from public,anon,authenticated;
grant select,insert,update,delete on table public.flow_vendor_foreign_official_transport_meta_v1
  to service_role;
grant select on table public.flow_vendor_foreign_compaction_manifest_v1 to service_role;

-- Keep the historical function signature, but stop materializing a second copy
-- of official IDX foreign-flow facts.  If the canonical stock-summary session is
-- absent, populate it once through its canonical ingestion function, then retain
-- only one compact per-session transport metadata record.
create or replace function public.flow_refresh_official_idx_foreign(
  p_date date default ((now() at time zone 'Asia/Jakarta')::date)
)
returns integer
language plpgsql
security definer
set search_path to 'pg_catalog','public','extensions'
as $fn$
declare
  v_rows integer;
  v_url text;
begin
  if extract(isodow from p_date) not between 1 and 5 then return 0; end if;

  select count(*)::integer into v_rows
  from public.flow_official_stock_summary s
  join public.flow_issuers i on i.ticker=s.ticker
  where s.trade_date=p_date and s.source='IDX_OFFICIAL_STOCK_SUMMARY'
    and s.source_verified;

  if v_rows=0 then
    perform public.flow_refresh_official_idx_stock_summary(p_date);
    select count(*)::integer into v_rows
    from public.flow_official_stock_summary s
    join public.flow_issuers i on i.ticker=s.ticker
    where s.trade_date=p_date and s.source='IDX_OFFICIAL_STOCK_SUMMARY'
      and s.source_verified;
  end if;
  if v_rows=0 then return 0; end if;

  v_url:='https://block.idx.id/primary/TradingSummary/GetStockSummary?length=1000&start=0&date='
    ||to_char(p_date,'YYYYMMDD');
  insert into public.flow_vendor_foreign_official_transport_meta_v1(
    trade_date,source_url,provenance_state,retrieved_at,source_row_count
  ) values(
    p_date,v_url,'VERIFIED_OFFICIAL_IDX_STOCK_SUMMARY_SHARE_FLOW',now(),v_rows
  ) on conflict(trade_date) do update set
    source_url=excluded.source_url,
    provenance_state=excluded.provenance_state,
    retrieved_at=excluded.retrieved_at,
    source_row_count=excluded.source_row_count,
    captured_at=statement_timestamp();
  return v_rows;
end
$fn$;

-- Alternate ZAPI transports remain physically retained because their provenance
-- is distinct even when their metrics happen to equal the official source.
create or replace function public.flow_sync_zapi_foreign_cache()
returns integer
language plpgsql
security definer
set search_path to 'public','extensions','pg_temp'
as $fn$
declare
    v_status integer;
    v_content text;
    v_payload jsonb;
    v_upserted integer := 0;
begin
    select (r).status,(r).content into v_status,v_content
    from(select extensions.http_get(
      'https://raw.githubusercontent.com/rizanrizan93/idx-flow-scanner/refs/heads/main/data/cache/zapi_idx_foreign_60d.json') as r) s;
    if v_status<>200 then raise exception 'ZAPI foreign mirror HTTP status %',v_status; end if;
    begin v_payload:=v_content::jsonb;
    exception when others then raise exception 'ZAPI foreign mirror is not valid JSON'; end;
    if jsonb_typeof(v_payload)<>'array' then
      raise exception 'ZAPI foreign mirror root must be a JSON array';
    end if;

    with normalized as(
      select upper(x->>'ticker') ticker,(x->>'trade_date')::date trade_date,
        greatest(coalesce((x->>'foreign_buy')::numeric,0),0) foreign_buy,
        greatest(coalesce((x->>'foreign_sell')::numeric,0),0) foreign_sell,
        coalesce((x->>'foreign_net')::numeric,0) foreign_net,
        greatest(coalesce((x->>'volume')::numeric,0),0) volume,
        greatest(coalesce((x->>'traded_value')::numeric,0),0) traded_value,
        upper(coalesce(x->>'flow_unit','')) flow_unit,
        upper(coalesce(x->>'market_type','ALL')) market_type,
        x->>'source' source,coalesce((x->>'source_verified')::boolean,false) source_verified,
        x->>'source_url' source_url,x->>'provenance_state' provenance_state
      from jsonb_array_elements(v_payload) x
      where x?'ticker' and x?'trade_date' and x?'source'
    ), eligible as(
      select * from normalized
      where ticker~'^[A-Z0-9]{1,10}$'
        and trade_date between(current_date-120) and current_date
        and flow_unit='SHARES' and market_type='ALL'
        and source in('ZAPI_IDX_FOREIGN_FLOW','ZAPI_IDX_STOCK_SUMMARY')
        and source_verified
        and provenance_state='VERIFIED_ZAPI_IDX_SHARE_FLOW_NOT_BROKER_IDENTITY'
        and source_url in(
          'https://api.zpi.web.id/v1/finance:idx/foreign-flow',
          'https://api.zpi.web.id/v1/finance:idx/stock-summary')
    ), upserted as(
      insert into public.flow_vendor_foreign_transport_v1(
        ticker,trade_date,foreign_buy,foreign_sell,foreign_net,volume,traded_value,
        flow_unit,market_type,source,source_verified,source_url,provenance_state,retrieved_at
      )
      select ticker,trade_date,foreign_buy,foreign_sell,foreign_net,volume,traded_value,
        flow_unit,market_type,source,source_verified,source_url,provenance_state,now()
      from eligible
      on conflict(ticker,trade_date,source,market_type) do update set
        foreign_buy=excluded.foreign_buy,foreign_sell=excluded.foreign_sell,
        foreign_net=excluded.foreign_net,volume=excluded.volume,
        traded_value=excluded.traded_value,source_verified=excluded.source_verified,
        source_url=excluded.source_url,provenance_state=excluded.provenance_state,
        retrieved_at=now()
      returning 1
    )
    select count(*)::integer into v_upserted from upserted;
    return v_upserted;
end
$fn$;

-- Rebind the telemetry function explicitly to the compatibility view rather
-- than relying on rename-time plan invalidation semantics.
create or replace function public.flow_populate_run_evidence_telemetry()
returns trigger
language plpgsql
set search_path to 'public'
as $fn$
declare
  v_foreign_tickers integer:=0;
  v_foreign_days integer:=0;
  v_sources jsonb:='{}'::jsonb;
  v_asof date;
begin
  if new.status not in('COMPLETED','COMPLETED_PARTIAL','FAILED','CANCELLED') then
    return new;
  end if;
  select count(*) filter(where coalesce((diagnostics->>'foreign_evidence_coverage_pct')::numeric,0)>0),
    max(as_of_date)
  into v_foreign_tickers,v_asof
  from public.flow_scan_results where run_id=new.id;
  select coalesce(jsonb_object_agg(source_name,source_count),'{}'::jsonb) into v_sources
  from(
    select diagnostics->>'foreign_evidence_source' source_name,count(*)::int source_count
    from public.flow_scan_results
    where run_id=new.id and coalesce(diagnostics->>'foreign_evidence_source','')<>''
      and coalesce((diagnostics->>'foreign_evidence_coverage_pct')::numeric,0)>0
    group by diagnostics->>'foreign_evidence_source'
  ) s;
  if v_asof is not null then
    select count(distinct trade_date)::int into v_foreign_days
    from(
      select v.trade_date from public.flow_vendor_foreign_flows v
      where v.trade_date between(v_asof-45) and v_asof
        and exists(select 1 from public.flow_scan_results r
          where r.run_id=new.id and r.ticker=v.ticker)
      union
      select o.trade_date from public.flow_official_stock_flows o
      where o.trade_date between(v_asof-45) and v_asof
        and exists(select 1 from public.flow_scan_results r
          where r.run_id=new.id and r.ticker=o.ticker)
    ) d;
  end if;
  update public.flow_scan_runs set
    foreign_evidence_tickers=coalesce(v_foreign_tickers,0),
    foreign_evidence_days=coalesce(v_foreign_days,0),
    foreign_evidence_sources=coalesce(v_sources,'{}'::jsonb)
  where id=new.id;
  return new;
end
$fn$;

-- Rename-time dependency tracking points the pre-existing view at the compact
-- transport table.  Recreate it so historical coverage continues to represent
-- the logical compatibility relation.
create or replace view public.flow_phase1_historical_coverage as
with stock_daily as(
  select trade_date,count(*) entities
  from public.flow_official_stock_summary
  where source='IDX_OFFICIAL_STOCK_SUMMARY' and source_verified group by trade_date
), broker_daily as(
  select trade_date,count(*) entities
  from public.flow_official_broker_activity
  where source='IDX_OFFICIAL_BROKER_SUMMARY' and source_verified group by trade_date
), index_daily as(
  select trade_date,count(*) entities
  from public.flow_official_index_summary
  where source='IDX_OFFICIAL_INDEX_SUMMARY' and source_verified group by trade_date
), foreign_daily as(
  select trade_date,count(*) entities
  from public.flow_vendor_foreign_flows
  where source='IDX_OFFICIAL_STOCK_SUMMARY' and source_verified group by trade_date
)
select 'STOCK_SUMMARY_RAW'::text dataset,count(*) sessions,min(trade_date) first_date,
  max(trade_date) last_date,min(entities) min_entities_per_session,
  max(entities) max_entities_per_session,round(avg(entities),2) avg_entities_per_session
from stock_daily
union all
select 'STOCK_SUMMARY_FOREIGN',count(*),min(trade_date),max(trade_date),min(entities),
  max(entities),round(avg(entities),2) from foreign_daily
union all
select 'BROKER_SUMMARY',count(*),min(trade_date),max(trade_date),min(entities),
  max(entities),round(avg(entities),2) from broker_daily
union all
select 'INDEX_SUMMARY',count(*),min(trade_date),max(trade_date),min(entities),
  max(entities),round(avg(entities),2) from index_daily;

-- Storage registry follows physical residency, not the compatibility-view name.
delete from public.flow_storage_dependency_v1
where object_name='flow_vendor_foreign_flows';
update public.flow_storage_object_registry_v1 set
  object_name='flow_vendor_foreign_transport_v1',
  storage_class='HOT_OPERATIONAL',
  operational_dependency='ALTERNATE_VENDOR_TRANSPORT_OR_UNMATCHED_OFFICIAL_HISTORY_ONLY',
  research_dependency='PROVENANCE_FALLBACK_AUDIT_DEPENDENCY',
  reproducibility_state='OFFICIAL_DUPLICATES_RECONSTRUCTED_FROM_CANONICAL_STOCK_SUMMARY_PLUS_SESSION_METADATA',
  retention_requirement='RETAIN ONLY DISTINCT TRANSPORT PROVENANCE OR ROWS WITHOUT CANONICAL OFFICIAL COUNTERPART',
  canonical_state='NONPRIMARY_TRANSPORT_EVIDENCE',
  derivation_state='OFFICIAL_PRIMARY_ROWS_LOGICALLY_RECONSTRUCTED_BY_VIEW',
  reviewed_at=statement_timestamp()
where object_name='flow_vendor_foreign_flows';

insert into public.flow_vendor_foreign_compaction_manifest_v1(
  compaction_contract,before_rows,retained_physical_rows,reconstructed_official_rows,
  logical_view_rows,removed_redundant_rows,mismatch_rows,before_bytes,
  after_transport_bytes,metadata_bytes,retained_sha256,details,
  production_influence_enabled
)
select
  'VENDOR_FOREIGN_CANONICAL_VIEW_V1',
  s.before_rows,
  (select count(*) from public.flow_vendor_foreign_transport_v1),
  (select count(*) from public.flow_official_stock_summary x
     join public.flow_issuers i on i.ticker=x.ticker
     where x.source='IDX_OFFICIAL_STOCK_SUMMARY' and x.source_verified),
  (select count(*) from public.flow_vendor_foreign_flows),
  s.removed_redundant_rows,
  0,
  s.before_bytes,
  pg_total_relation_size('public.flow_vendor_foreign_transport_v1'::regclass),
  pg_total_relation_size('public.flow_vendor_foreign_official_transport_meta_v1'::regclass),
  d.retained_sha256,
  jsonb_build_object(
    'compaction_semantics','ONLY_DUPLICATED_IDX_OFFICIAL_ROWS_REMOVED_FROM_PHYSICAL_TRANSPORT',
    'zapi_transport_rows_preserved',
      (select count(*) from public.flow_vendor_foreign_transport_v1 where source like 'ZAPI_%'),
    'unmatched_official_transport_rows_preserved',
      (select count(*) from public.flow_vendor_foreign_transport_v1
        where source='IDX_OFFICIAL_STOCK_SUMMARY'),
    'logical_compatibility_view','flow_vendor_foreign_flows',
    'canonical_primary_source','flow_official_stock_summary',
    'foreign_values_exact_match_precondition',true,
    'volume_value_exact_match_precondition',true,
    'transport_provenance_preserved',true
  ),false
from flow_vendor_foreign_compaction_stats_v1 s
cross join flow_vendor_foreign_keep_digest_v1 d
on conflict(compaction_contract) do nothing;

do $do$
declare
  v_before bigint;
  v_logical bigint;
  v_removed bigint;
  v_transport bigint;
  v_meta integer;
begin
  select before_rows,logical_view_rows,removed_redundant_rows,retained_physical_rows
    into v_before,v_logical,v_removed,v_transport
  from public.flow_vendor_foreign_compaction_manifest_v1
  where compaction_contract='VENDOR_FOREIGN_CANONICAL_VIEW_V1';
  select count(*)::integer into v_meta
  from public.flow_vendor_foreign_official_transport_meta_v1;
  if v_before<>v_logical then
    raise exception 'logical compatibility row count changed: before %, view %',v_before,v_logical;
  end if;
  if v_removed<=0 or v_transport<=0 or v_meta<=0 then
    raise exception 'vendor foreign compaction verification failed';
  end if;
end
$do$;

select public.flow_refresh_storage_registry_v1();
select public.flow_refresh_storage_date_ranges_v1();

revoke all on function public.flow_refresh_official_idx_foreign(date),
  public.flow_sync_zapi_foreign_cache() from public,anon,authenticated;
grant execute on function public.flow_refresh_official_idx_foreign(date),
  public.flow_sync_zapi_foreign_cache() to service_role;
