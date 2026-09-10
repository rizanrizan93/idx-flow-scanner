-- Storage remediation: flow_stock_residual_activity_v2 is a deterministic derived
-- panel. Its raw OHLCV/foreign fields duplicate flow_official_stock_summary and its
-- provenance fields are constant across every row. Preserve the full logical/PIT
-- contract while storing only residual-specific fields physically.
--
-- This migration is fail closed. It will not compact unless every residual row has
-- an exact verified official counterpart, all duplicated raw fields match exactly,
-- provenance constants are uniform, there are no FK/user-trigger dependencies, and
-- all dependent views can be rebound before the legacy physical table is dropped.

do $do$
declare
  v_relkind "char";
  v_fk_refs integer;
  v_user_triggers integer;
  v_bad_constants bigint;
  v_missing_canonical bigint;
  v_raw_mismatches bigint;
begin
  select c.relkind into v_relkind
  from pg_class c join pg_namespace n on n.oid=c.relnamespace
  where n.nspname='public' and c.relname='flow_stock_residual_activity_v2';
  if v_relkind is distinct from 'r'::"char" then
    raise exception 'flow_stock_residual_activity_v2 must be a physical table before compact-view V1';
  end if;

  if to_regclass('public.flow_stock_residual_activity_compact_v1') is not null
     or to_regclass('public.flow_stock_residual_activity_legacy_v2') is not null then
    raise exception 'residual compact-view V1 target/legacy relation already exists';
  end if;

  select count(*)::integer into v_fk_refs
  from pg_constraint
  where contype='f'
    and (conrelid='public.flow_stock_residual_activity_v2'::regclass
      or confrelid='public.flow_stock_residual_activity_v2'::regclass);
  if v_fk_refs<>0 then
    raise exception 'residual compaction denied: % FK references exist',v_fk_refs;
  end if;

  select count(*)::integer into v_user_triggers
  from pg_trigger
  where tgrelid='public.flow_stock_residual_activity_v2'::regclass and not tgisinternal;
  if v_user_triggers<>0 then
    raise exception 'residual compaction denied: % user triggers exist',v_user_triggers;
  end if;

  select count(*)::bigint into v_bad_constants
  from public.flow_stock_residual_activity_v2 r
  where r.residualization_basis<>'DAILY_SECTOR_X_VOLATILITY_QUINTILE_ROBUST_LOG_ACTIVITY'
     or r.source<>'DERIVED_IDX_OFFICIAL_STOCK_RESIDUAL_V2'
     or not r.source_verified
     or r.source_dataset<>'flow_official_stock_summary'
     or r.provenance_state<>'SHADOW_DERIVED_FROM_VERIFIED_OFFICIAL_IDX_STOCK_SUMMARY';
  if v_bad_constants<>0 then
    raise exception 'residual compaction denied: % rows violate frozen provenance constants',v_bad_constants;
  end if;

  select
    count(*) filter(where s.ticker is null)::bigint,
    count(*) filter(where s.ticker is not null and (
      r.previous is distinct from s.previous
      or r.close is distinct from s.close
      or r.high is distinct from s.high
      or r.low is distinct from s.low
      or r.traded_value is distinct from s.traded_value
      or r.volume is distinct from s.volume
      or r.frequency is distinct from s.frequency
      or r.foreign_buy is distinct from s.foreign_buy
      or r.foreign_sell is distinct from s.foreign_sell
      or r.foreign_net is distinct from (s.foreign_buy-s.foreign_sell)::numeric
    ))::bigint
  into v_missing_canonical,v_raw_mismatches
  from public.flow_stock_residual_activity_v2 r
  left join public.flow_official_stock_summary s
    on s.trade_date=r.trade_date and s.ticker=r.ticker
   and s.source='IDX_OFFICIAL_STOCK_SUMMARY' and s.source_verified;
  if v_missing_canonical<>0 or v_raw_mismatches<>0 then
    raise exception 'residual compaction denied: missing canonical %, raw mismatches %',
      v_missing_canonical,v_raw_mismatches;
  end if;
end
$do$;

create temporary table flow_stock_residual_compaction_stats_v1 on commit drop as
select
  count(*)::bigint before_rows,
  pg_total_relation_size('public.flow_stock_residual_activity_v2'::regclass)::bigint before_bytes,
  encode(extensions.digest(convert_to(coalesce(string_agg(
    encode(extensions.digest(convert_to(concat_ws('|',
      trade_date::text,ticker,coalesce(sector,''),coalesce(subsector,''),
      coalesce(return_pct::text,''),coalesce(volatility_range_pct::text,''),coalesce(volatility_bucket::text,''),
      coalesce(market_turnover_share_pct::text,''),coalesce(sector_turnover_share_pct::text,''),coalesce(foreign_net_volume_pct::text,''),
      peer_group_size::text,coalesce(turnover_residual_z::text,''),coalesce(volume_residual_z::text,''),
      coalesce(frequency_residual_z::text,''),coalesce(stock_residual_activity_z::text,''),residual_quality_state,computed_at::text
    ),'UTF8'),'sha256'),'hex'),'' order by trade_date,ticker),''),'UTF8'),'sha256'),'hex') dynamic_sha256
from public.flow_stock_residual_activity_v2;

create temporary table flow_stock_residual_dependent_views_v1 on commit drop as
select v.schemaname,v.viewname,v.definition,
  coalesce('security_invoker=true'=any(c.reloptions),false) as security_invoker
from pg_views v
join pg_class c on c.relname=v.viewname
join pg_namespace n on n.oid=c.relnamespace and n.nspname=v.schemaname
where v.schemaname='public'
  and v.definition ilike '%flow_stock_residual_activity_v2%';

create table public.flow_stock_residual_activity_compact_v1(
  trade_date date not null,
  ticker text not null,
  sector text,
  subsector text,
  return_pct numeric,
  volatility_range_pct numeric,
  volatility_bucket integer,
  market_turnover_share_pct numeric,
  sector_turnover_share_pct numeric,
  foreign_net_volume_pct numeric,
  peer_group_size integer not null,
  turnover_residual_z numeric,
  volume_residual_z numeric,
  frequency_residual_z numeric,
  stock_residual_activity_z numeric,
  residual_quality_state text not null,
  computed_at timestamptz not null,
  constraint flow_stock_residual_activity_compact_v1_pkey primary key(trade_date,ticker),
  constraint flow_stock_residual_activity_compact_v1_bucket_ck
    check(volatility_bucket between 1 and 5),
  constraint flow_stock_residual_activity_compact_v1_peer_ck
    check(peer_group_size>=1),
  constraint flow_stock_residual_activity_compact_v1_quality_ck
    check(residual_quality_state in('FULL','SECTOR_FALLBACK','MARKET_FALLBACK'))
);

create index flow_stock_residual_activity_compact_v1_date_quality_idx
  on public.flow_stock_residual_activity_compact_v1(trade_date desc,residual_quality_state);
create index flow_stock_residual_activity_compact_v1_sector_date_idx
  on public.flow_stock_residual_activity_compact_v1(sector,trade_date desc);
create index flow_stock_residual_activity_compact_v1_ticker_date_idx
  on public.flow_stock_residual_activity_compact_v1(ticker,trade_date desc);

insert into public.flow_stock_residual_activity_compact_v1(
  trade_date,ticker,sector,subsector,return_pct,volatility_range_pct,volatility_bucket,
  market_turnover_share_pct,sector_turnover_share_pct,foreign_net_volume_pct,
  peer_group_size,turnover_residual_z,volume_residual_z,frequency_residual_z,
  stock_residual_activity_z,residual_quality_state,computed_at
)
select
  trade_date,ticker,sector,subsector,return_pct,volatility_range_pct,volatility_bucket,
  market_turnover_share_pct,sector_turnover_share_pct,foreign_net_volume_pct,
  peer_group_size,turnover_residual_z,volume_residual_z,frequency_residual_z,
  stock_residual_activity_z,residual_quality_state,computed_at
from public.flow_stock_residual_activity_v2
order by trade_date,ticker;

analyze public.flow_stock_residual_activity_compact_v1;

do $do$
declare
  v_before_rows bigint;
  v_after_rows bigint;
  v_before_sha text;
  v_after_sha text;
begin
  select before_rows,dynamic_sha256 into v_before_rows,v_before_sha
  from flow_stock_residual_compaction_stats_v1;
  select count(*)::bigint,
    encode(extensions.digest(convert_to(coalesce(string_agg(
      encode(extensions.digest(convert_to(concat_ws('|',
        trade_date::text,ticker,coalesce(sector,''),coalesce(subsector,''),
        coalesce(return_pct::text,''),coalesce(volatility_range_pct::text,''),coalesce(volatility_bucket::text,''),
        coalesce(market_turnover_share_pct::text,''),coalesce(sector_turnover_share_pct::text,''),coalesce(foreign_net_volume_pct::text,''),
        peer_group_size::text,coalesce(turnover_residual_z::text,''),coalesce(volume_residual_z::text,''),
        coalesce(frequency_residual_z::text,''),coalesce(stock_residual_activity_z::text,''),residual_quality_state,computed_at::text
      ),'UTF8'),'sha256'),'hex'),'' order by trade_date,ticker),''),'UTF8'),'sha256'),'hex')
  into v_after_rows,v_after_sha
  from public.flow_stock_residual_activity_compact_v1;
  if v_before_rows<>v_after_rows or v_before_sha is distinct from v_after_sha then
    raise exception 'residual compact copy verification failed: rows %/%, digest %/%',
      v_before_rows,v_after_rows,v_before_sha,v_after_sha;
  end if;
end
$do$;

alter table public.flow_stock_residual_activity_v2
  rename to flow_stock_residual_activity_legacy_v2;

create view public.flow_stock_residual_activity_v2
with (security_invoker=true)
as
select
  c.trade_date,
  c.ticker,
  c.sector,
  c.subsector,
  s.previous,
  s.close,
  s.high,
  s.low,
  s.traded_value,
  s.volume,
  s.frequency,
  s.foreign_buy,
  s.foreign_sell,
  (s.foreign_buy-s.foreign_sell)::numeric as foreign_net,
  c.return_pct,
  c.volatility_range_pct,
  c.volatility_bucket,
  c.market_turnover_share_pct,
  c.sector_turnover_share_pct,
  c.foreign_net_volume_pct,
  c.peer_group_size,
  c.turnover_residual_z,
  c.volume_residual_z,
  c.frequency_residual_z,
  c.stock_residual_activity_z,
  c.residual_quality_state,
  'DAILY_SECTOR_X_VOLATILITY_QUINTILE_ROBUST_LOG_ACTIVITY'::text as residualization_basis,
  'DERIVED_IDX_OFFICIAL_STOCK_RESIDUAL_V2'::text as source,
  true::boolean as source_verified,
  'flow_official_stock_summary'::text as source_dataset,
  'SHADOW_DERIVED_FROM_VERIFIED_OFFICIAL_IDX_STOCK_SUMMARY'::text as provenance_state,
  c.computed_at
from public.flow_stock_residual_activity_compact_v1 c
join public.flow_official_stock_summary s
  on s.trade_date=c.trade_date and s.ticker=c.ticker
 and s.source='IDX_OFFICIAL_STOCK_SUMMARY' and s.source_verified;

create function public.flow_stock_residual_activity_v2_compat_iud_v1()
returns trigger
language plpgsql
security invoker
set search_path to ''
as $fn$
declare
  v_previous numeric;
  v_close numeric;
  v_high numeric;
  v_low numeric;
  v_traded_value numeric;
  v_volume numeric;
  v_frequency numeric;
  v_foreign_buy numeric;
  v_foreign_sell numeric;
begin
  if tg_op='DELETE' then
    delete from public.flow_stock_residual_activity_compact_v1
    where trade_date=old.trade_date and ticker=old.ticker;
    return old;
  end if;

  select s.previous,s.close,s.high,s.low,s.traded_value,s.volume,s.frequency,
         s.foreign_buy,s.foreign_sell
  into v_previous,v_close,v_high,v_low,v_traded_value,v_volume,v_frequency,
       v_foreign_buy,v_foreign_sell
  from public.flow_official_stock_summary s
  where s.trade_date=new.trade_date and s.ticker=new.ticker
    and s.source='IDX_OFFICIAL_STOCK_SUMMARY' and s.source_verified;
  if not found then
    raise exception 'residual compatibility insert denied: canonical official row missing for % %',
      new.trade_date,new.ticker;
  end if;

  if new.previous is distinct from v_previous
     or new.close is distinct from v_close
     or new.high is distinct from v_high
     or new.low is distinct from v_low
     or new.traded_value is distinct from v_traded_value
     or new.volume is distinct from v_volume
     or new.frequency is distinct from v_frequency
     or new.foreign_buy is distinct from v_foreign_buy
     or new.foreign_sell is distinct from v_foreign_sell
     or new.foreign_net is distinct from (v_foreign_buy-v_foreign_sell)::numeric then
    raise exception 'residual compatibility insert denied: raw official fields differ for % %',
      new.trade_date,new.ticker;
  end if;

  if (new.residualization_basis is not null and new.residualization_basis<>'DAILY_SECTOR_X_VOLATILITY_QUINTILE_ROBUST_LOG_ACTIVITY')
     or (new.source is not null and new.source<>'DERIVED_IDX_OFFICIAL_STOCK_RESIDUAL_V2')
     or (new.source_verified is not null and not new.source_verified)
     or (new.source_dataset is not null and new.source_dataset<>'flow_official_stock_summary')
     or (new.provenance_state is not null and new.provenance_state<>'SHADOW_DERIVED_FROM_VERIFIED_OFFICIAL_IDX_STOCK_SUMMARY') then
    raise exception 'residual compatibility insert denied: provenance contract mismatch for % %',
      new.trade_date,new.ticker;
  end if;

  insert into public.flow_stock_residual_activity_compact_v1(
    trade_date,ticker,sector,subsector,return_pct,volatility_range_pct,volatility_bucket,
    market_turnover_share_pct,sector_turnover_share_pct,foreign_net_volume_pct,
    peer_group_size,turnover_residual_z,volume_residual_z,frequency_residual_z,
    stock_residual_activity_z,residual_quality_state,computed_at
  ) values(
    new.trade_date,new.ticker,new.sector,new.subsector,new.return_pct,new.volatility_range_pct,
    new.volatility_bucket,new.market_turnover_share_pct,new.sector_turnover_share_pct,
    new.foreign_net_volume_pct,new.peer_group_size,new.turnover_residual_z,new.volume_residual_z,
    new.frequency_residual_z,new.stock_residual_activity_z,new.residual_quality_state,
    coalesce(new.computed_at,statement_timestamp())
  );
  return new;
end
$fn$;

create trigger flow_stock_residual_activity_v2_compat_iud_v1
instead of insert or delete on public.flow_stock_residual_activity_v2
for each row execute function public.flow_stock_residual_activity_v2_compat_iud_v1();

alter table public.flow_stock_residual_activity_compact_v1 enable row level security;
revoke all on table public.flow_stock_residual_activity_compact_v1,
  public.flow_stock_residual_activity_v2 from public,anon,authenticated;
grant select,insert,update,delete on table public.flow_stock_residual_activity_compact_v1 to service_role;
grant select,insert,delete on table public.flow_stock_residual_activity_v2 to service_role;
revoke all on function public.flow_stock_residual_activity_v2_compat_iud_v1()
  from public,anon,authenticated;
grant execute on function public.flow_stock_residual_activity_v2_compat_iud_v1() to service_role;

-- Rename-time dependency tracking binds pre-existing views to the legacy physical
-- table. Recompile the exact saved definitions so they bind to the compatibility
-- view with the same name, then restore security_invoker where it was set.
do $do$
declare r record;
begin
  for r in select * from flow_stock_residual_dependent_views_v1 order by viewname loop
    execute format('create or replace view %I.%I as %s',r.schemaname,r.viewname,r.definition);
    if r.security_invoker then
      execute format('alter view %I.%I set (security_invoker=true)',r.schemaname,r.viewname);
    end if;
  end loop;
end
$do$;

-- RESTRICT is intentional: any dependency that was not rebound aborts the entire
-- migration instead of cascading away research/runtime objects.
drop table public.flow_stock_residual_activity_legacy_v2 restrict;

create table public.flow_stock_residual_compaction_manifest_v1(
  compaction_contract text primary key,
  before_rows bigint not null,
  logical_view_rows bigint not null,
  before_bytes bigint not null,
  compact_bytes bigint not null,
  dynamic_sha256_before text not null check(length(dynamic_sha256_before)=64),
  dynamic_sha256_after text not null check(length(dynamic_sha256_after)=64),
  missing_canonical_rows bigint not null check(missing_canonical_rows=0),
  raw_mismatch_rows bigint not null check(raw_mismatch_rows=0),
  provenance_mismatch_rows bigint not null check(provenance_mismatch_rows=0),
  details jsonb not null,
  compacted_at timestamptz not null default statement_timestamp(),
  production_influence_enabled boolean not null default false
    check(production_influence_enabled=false)
);

alter table public.flow_stock_residual_compaction_manifest_v1 enable row level security;
revoke all on table public.flow_stock_residual_compaction_manifest_v1 from public,anon,authenticated;
grant select on table public.flow_stock_residual_compaction_manifest_v1 to service_role;

insert into public.flow_stock_residual_compaction_manifest_v1(
  compaction_contract,before_rows,logical_view_rows,before_bytes,compact_bytes,
  dynamic_sha256_before,dynamic_sha256_after,missing_canonical_rows,raw_mismatch_rows,
  provenance_mismatch_rows,details,production_influence_enabled
)
select
  'STOCK_RESIDUAL_COMPACT_VIEW_V1',
  s.before_rows,
  (select count(*) from public.flow_stock_residual_activity_v2),
  s.before_bytes,
  pg_total_relation_size('public.flow_stock_residual_activity_compact_v1'::regclass),
  s.dynamic_sha256,
  encode(extensions.digest(convert_to(coalesce((select string_agg(
    encode(extensions.digest(convert_to(concat_ws('|',
      c.trade_date::text,c.ticker,coalesce(c.sector,''),coalesce(c.subsector,''),
      coalesce(c.return_pct::text,''),coalesce(c.volatility_range_pct::text,''),coalesce(c.volatility_bucket::text,''),
      coalesce(c.market_turnover_share_pct::text,''),coalesce(c.sector_turnover_share_pct::text,''),coalesce(c.foreign_net_volume_pct::text,''),
      c.peer_group_size::text,coalesce(c.turnover_residual_z::text,''),coalesce(c.volume_residual_z::text,''),
      coalesce(c.frequency_residual_z::text,''),coalesce(c.stock_residual_activity_z::text,''),c.residual_quality_state,c.computed_at::text
    ),'UTF8'),'sha256'),'hex'),'' order by c.trade_date,c.ticker)
    from public.flow_stock_residual_activity_compact_v1 c),''),'UTF8'),'sha256'),'hex'),
  0,0,0,
  jsonb_build_object(
    'canonical_raw_source','flow_official_stock_summary',
    'full_pit_row_count_preserved',true,
    'raw_ohlcv_foreign_reconstructed_from_verified_canonical',true,
    'constant_provenance_projected_by_compatibility_view',true,
    'sector_subsector_retained_physically_for_pit_integrity',true,
    'derived_metrics_retained_physically_without_recomputation',true,
    'compatibility_view','flow_stock_residual_activity_v2',
    'physical_backing','flow_stock_residual_activity_compact_v1',
    'producer_compatibility_trigger','flow_stock_residual_activity_v2_compat_iud_v1',
    'no_production_scoring_change',true
  ),false
from flow_stock_residual_compaction_stats_v1 s;

-- Final logical verification: exact row count, exact derived digest, exact raw
-- canonical fields, and frozen provenance constants.
do $do$
declare
  v_before_rows bigint;
  v_view_rows bigint;
  v_sha_before text;
  v_sha_after text;
  v_missing bigint;
  v_raw_mismatch bigint;
  v_bad_constants bigint;
begin
  select before_rows,dynamic_sha256_before,dynamic_sha256_after
  into v_before_rows,v_sha_before,v_sha_after
  from public.flow_stock_residual_compaction_manifest_v1
  where compaction_contract='STOCK_RESIDUAL_COMPACT_VIEW_V1';
  select count(*)::bigint into v_view_rows from public.flow_stock_residual_activity_v2;
  if v_before_rows<>v_view_rows or v_sha_before is distinct from v_sha_after then
    raise exception 'residual logical verification failed: rows %/%, digest %/%',
      v_before_rows,v_view_rows,v_sha_before,v_sha_after;
  end if;

  select
    count(*) filter(where s.ticker is null)::bigint,
    count(*) filter(where s.ticker is not null and (
      r.previous is distinct from s.previous or r.close is distinct from s.close
      or r.high is distinct from s.high or r.low is distinct from s.low
      or r.traded_value is distinct from s.traded_value or r.volume is distinct from s.volume
      or r.frequency is distinct from s.frequency or r.foreign_buy is distinct from s.foreign_buy
      or r.foreign_sell is distinct from s.foreign_sell
      or r.foreign_net is distinct from (s.foreign_buy-s.foreign_sell)::numeric
    ))::bigint,
    count(*) filter(where
      r.residualization_basis<>'DAILY_SECTOR_X_VOLATILITY_QUINTILE_ROBUST_LOG_ACTIVITY'
      or r.source<>'DERIVED_IDX_OFFICIAL_STOCK_RESIDUAL_V2'
      or not r.source_verified
      or r.source_dataset<>'flow_official_stock_summary'
      or r.provenance_state<>'SHADOW_DERIVED_FROM_VERIFIED_OFFICIAL_IDX_STOCK_SUMMARY'
    )::bigint
  into v_missing,v_raw_mismatch,v_bad_constants
  from public.flow_stock_residual_activity_v2 r
  left join public.flow_official_stock_summary s
    on s.trade_date=r.trade_date and s.ticker=r.ticker
   and s.source='IDX_OFFICIAL_STOCK_SUMMARY' and s.source_verified;
  if v_missing<>0 or v_raw_mismatch<>0 or v_bad_constants<>0 then
    raise exception 'residual logical verification failed: missing %, raw mismatch %, provenance mismatch %',
      v_missing,v_raw_mismatch,v_bad_constants;
  end if;
end
$do$;

-- Storage registry follows physical residency. Historical measurements migrate
-- through the ON UPDATE CASCADE FK established by the preceding storage fix.
delete from public.flow_storage_dependency_v1
where object_name='flow_stock_residual_activity_v2';
update public.flow_storage_object_registry_v1 set
  object_name='flow_stock_residual_activity_compact_v1',
  object_kind='TABLE',
  storage_class='DERIVABLE',
  operational_dependency='PHYSICAL_BACKING_FOR_FLOW_STOCK_RESIDUAL_ACTIVITY_V2_COMPATIBILITY_VIEW',
  research_dependency='PROSPECTIVE_SIGNAL_AND_MARKET_MEMORY_TRANSITIVE_DEPENDENCY',
  reproducibility_state='DERIVED_METRICS_RETAINED_EXACTLY; RAW_FIELDS_RECONSTRUCTED_FROM_VERIFIED_CANONICAL_SOURCE',
  retention_requirement='RETAIN_FULL_PIT_DERIVED_PANEL; DO_NOT_REMOVE WITHOUT OBJECT_SPECIFIC_PROOF',
  canonical_state='NONPRIMARY_DERIVED_PIT_EVIDENCE',
  derivation_state='COMPACT_DERIVED_MATERIALIZATION_WITH_CANONICAL_RAW_JOIN',
  reviewed_at=statement_timestamp()
where object_name='flow_stock_residual_activity_v2';

select public.flow_refresh_storage_registry_v1();
select public.flow_refresh_storage_date_ranges_v1();
