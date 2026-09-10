-- Storage observability for the canonical IDX Flow database.
-- The quota value below is sourced from the Supabase Management API and official
-- Free-plan documentation on 2026-09-09; it is policy data, not an inferred constant.
create table if not exists public.flow_storage_policy_v1(
  policy_version text primary key,
  organization_plan text not null,
  database_quota_bytes bigint,
  quota_source text not null,
  warning_ratio numeric not null check(warning_ratio between 0 and 1),
  critical_ratio numeric not null check(critical_ratio>=warning_ratio),
  measurement_retention_days integer not null check(measurement_retention_days>=30),
  frozen_at timestamptz not null default statement_timestamp()
);

insert into public.flow_storage_policy_v1(
  policy_version,organization_plan,database_quota_bytes,quota_source,
  warning_ratio,critical_ratio,measurement_retention_days
) values(
  'IDX_FLOW_STORAGE_POLICY_V1','free',524288000,
  'SUPABASE_MANAGEMENT_API_PLAN_FREE_AND_OFFICIAL_DATABASE_SIZE_DOCS_VERIFIED_20260909',
  0.80,1.00,180
) on conflict(policy_version) do nothing;

create table if not exists public.flow_storage_object_registry_v1(
  object_name text primary key,
  object_kind text not null,
  storage_class text not null check(storage_class in(
    'HOT_OPERATIONAL','WARM_VALIDATION','COLD_RESEARCH','DERIVABLE',
    'REDUNDANT_CANDIDATE_FOR_REMOVAL','UNKNOWN_DO_NOT_TOUCH'
  )),
  operational_dependency text not null,
  research_dependency text not null,
  reproducibility_state text not null,
  retention_requirement text not null,
  canonical_state text not null,
  derivation_state text not null,
  write_frequency text not null,
  date_column text,
  min_observed_at timestamptz,
  max_observed_at timestamptz,
  date_range_state text not null default 'NOT_MEASURED',
  removal_authorized boolean not null default false check(removal_authorized=false),
  reviewed_at timestamptz not null default statement_timestamp()
);

create table if not exists public.flow_storage_measurement_v1(
  measurement_id uuid primary key default gen_random_uuid(),
  policy_version text not null references public.flow_storage_policy_v1(policy_version),
  measured_at timestamptz not null default statement_timestamp(),
  database_bytes bigint not null,
  public_schema_bytes bigint not null,
  flow_relation_bytes bigint not null,
  estimated_live_rows bigint not null,
  estimated_dead_rows bigint not null,
  database_growth_bytes bigint,
  elapsed_hours numeric,
  projected_days_to_quota numeric,
  quota_bytes bigint,
  quota_ratio numeric,
  storage_status text not null check(storage_status in('NORMAL','WARNING','CRITICAL','UNKNOWN')),
  read_only_state text not null
);

create index if not exists flow_storage_measurement_v1_time_idx
  on public.flow_storage_measurement_v1(measured_at desc);

create table if not exists public.flow_storage_relation_measurement_v1(
  measurement_id uuid not null references public.flow_storage_measurement_v1(measurement_id) on delete cascade,
  object_name text not null references public.flow_storage_object_registry_v1(object_name),
  total_bytes bigint not null,
  heap_bytes bigint not null,
  index_bytes bigint not null,
  toast_bytes bigint not null,
  estimated_live_rows bigint not null,
  estimated_dead_rows bigint not null,
  inserts_since_stats_reset bigint not null,
  updates_since_stats_reset bigint not null,
  deletes_since_stats_reset bigint not null,
  primary key(measurement_id,object_name)
);

create index if not exists flow_storage_relation_measurement_v1_object_idx
  on public.flow_storage_relation_measurement_v1(object_name,measurement_id);

create table if not exists public.flow_storage_dependency_v1(
  object_name text not null references public.flow_storage_object_registry_v1(object_name) on delete cascade,
  dependency_type text not null,
  dependent_name text not null,
  dependency_detail text not null,
  captured_at timestamptz not null default statement_timestamp(),
  primary key(object_name,dependency_type,dependent_name)
);

create or replace function public.flow_refresh_storage_registry_v1()
returns jsonb
language plpgsql
security invoker
set search_path=''
as $fn$
declare v_objects integer; v_dependencies integer;
begin
  insert into public.flow_storage_object_registry_v1(
    object_name,object_kind,storage_class,operational_dependency,research_dependency,
    reproducibility_state,retention_requirement,canonical_state,derivation_state,
    write_frequency,date_range_state,removal_authorized
  )
  select c.relname,
    case c.relkind when 'm' then 'MATERIALIZED_VIEW' else 'TABLE' end,
    case
      when c.relname in(
        'flow_scan_runs','flow_scan_results','flow_signal_outcomes','flow_daily_prices',
        'flow_official_stock_summary','flow_official_index_summary','flow_vendor_foreign_flows',
        'flow_official_stock_flows','flow_issuers','flow_capital_action_evidence',
        'flow_official_risk_events','flow_official_shareholder_profiles',
        'flow_sector_membership_snapshot_v1','flow_ownership_snapshot_v1',
        'flow_universe_snapshot_v1','flow_universe_capture_manifest_v1',
        'flow_operational_universe_contract_v1'
      ) then 'HOT_OPERATIONAL'
      when c.relname like 'flow_attribution_%'
        or c.relname like 'flow_shadow_predictive_%'
        or c.relname like 'flow_shadow_rank_%'
        or c.relname like 'flow_thesis_%'
        or c.relname like 'flow_gate15_%'
        or c.relname like 'flow_component_forward_%'
        then 'WARM_VALIDATION'
      when c.relname in(
        'flow_driver_feature_panel_v1','flow_driver_signal_panel_v1',
        'flow_driver_panel_lineage_v2','flow_financial_shadow_panel_v5',
        'flow_stock_residual_activity_v2','flow_financial_filing_feature_v5'
      ) then 'DERIVABLE'
      when c.relname like 'flow_driver_%'
        or c.relname like 'flow_financial_shadow_%'
        or c.relname like 'flow_phase4d_%'
        or c.relname like 'flow_phase4e_%'
        or c.relname like 'flow_factor_%'
        then 'COLD_RESEARCH'
      else 'UNKNOWN_DO_NOT_TOUCH'
    end,
    case
      when c.relname in('flow_scan_runs','flow_scan_results','flow_signal_outcomes',
        'flow_official_stock_summary','flow_official_index_summary','flow_vendor_foreign_flows',
        'flow_issuers','flow_capital_action_evidence','flow_official_risk_events',
        'flow_official_shareholder_profiles','flow_universe_snapshot_v1')
      then 'DIRECT_OR_CANONICAL_RUNTIME_DEPENDENCY'
      when c.relname like 'flow_attribution_%' or c.relname like 'flow_shadow_%'
      then 'SCHEDULED_SHADOW_PIPELINE_DEPENDENCY'
      else 'NO_DIRECT_PRODUCTION_DEPENDENCY_PROVEN'
    end,
    case
      when c.relname like 'flow_driver_%' or c.relname like 'flow_financial_%'
        or c.relname like 'flow_factor_%' or c.relname like 'flow_phase4%'
      then 'HISTORICAL_OR_VALIDATION_CONTRACT_DEPENDENCY'
      when c.relname like 'flow_attribution_%' or c.relname like 'flow_shadow_%'
        or c.relname like 'flow_thesis_%'
      then 'PROSPECTIVE_VALIDATION_DEPENDENCY'
      else 'NO_RESEARCH_DEPENDENCY_PROVEN'
    end,
    case
      when c.relname in('flow_driver_feature_panel_v1','flow_driver_signal_panel_v1',
        'flow_driver_panel_lineage_v2','flow_financial_shadow_panel_v5',
        'flow_stock_residual_activity_v2','flow_financial_filing_feature_v5')
      then 'DETERMINISTIC_REBUILD_FUNCTION_EXISTS'
      when c.relname like '%manifest%' or c.relname like '%policy%' or c.relname like '%registry%'
      then 'CANONICAL_CONTRACT_NOT_DERIVED'
      else 'REQUIRES_OBJECT_SPECIFIC_REVIEW'
    end,
    case
      when c.relname in('flow_driver_feature_panel_v1','flow_driver_signal_panel_v1','flow_driver_panel_lineage_v2')
      then 'ARCHIVE_LOSSLESS_AFTER_GATE10_13_CLOSURE; RESTORE_ON_EXPLICIT_RESEARCH_RERUN'
      when c.relname like 'flow_attribution_%' or c.relname like 'flow_shadow_%'
        or c.relname like 'flow_thesis_%'
      then 'RETAIN_UNTIL_FORWARD_CONFIRMATION_AND_PROMOTION_MONITORING_COMPLETE'
      when c.relname like '%policy%' or c.relname like '%manifest%' or c.relname like '%registry%'
      then 'RETAIN_PERMANENTLY'
      when c.relname in('flow_official_stock_summary','flow_vendor_foreign_flows',
        'flow_financial_fact_evidence_v5','flow_financial_filing_evidence_v5')
      then 'RETAIN_CANONICAL_PIT_SOURCE; COMPACT_ONLY_WITH_VERIFIED_ARCHIVE'
      else 'DO_NOT_REMOVE_WITHOUT_OBJECT_SPECIFIC_PROOF'
    end,
    case
      when c.relname in('flow_official_stock_summary','flow_official_index_summary',
        'flow_vendor_foreign_flows','flow_financial_fact_evidence_v5',
        'flow_financial_filing_evidence_v5','flow_official_shareholder_profiles',
        'flow_capital_action_evidence') then 'CANONICAL_PIT_EVIDENCE'
      when c.relname like '%policy%' or c.relname like '%manifest%' or c.relname like '%registry%'
      then 'CANONICAL_CONTROL_OR_AUDIT_STATE'
      else 'NOT_CLASSIFIED_AS_CANONICAL_SOURCE'
    end,
    case
      when c.relname in('flow_driver_feature_panel_v1','flow_driver_signal_panel_v1',
        'flow_driver_panel_lineage_v2','flow_financial_shadow_panel_v5',
        'flow_stock_residual_activity_v2','flow_financial_filing_feature_v5')
      then 'DERIVED_MATERIALIZATION'
      else 'NOT_PROVEN_DERIVABLE'
    end,
    case
      when exists(select 1 from cron.job j where j.active and j.command ilike '%'||c.relname||'%')
      then 'SCHEDULED_DIRECT'
      when coalesce(s.n_tup_ins,0)+coalesce(s.n_tup_upd,0)+coalesce(s.n_tup_del,0)>0
      then 'OBSERVED_WRITES_SINCE_STATS_RESET'
      else 'NO_RECENT_WRITE_OBSERVED'
    end,
    'NOT_MEASURED',false
  from pg_class c
  join pg_namespace n on n.oid=c.relnamespace
  left join pg_stat_user_tables s on s.relid=c.oid
  where n.nspname='public' and c.relkind in('r','m') and c.relname like 'flow_%'
  on conflict(object_name) do nothing;
  get diagnostics v_objects=row_count;

  delete from public.flow_storage_dependency_v1;

  insert into public.flow_storage_dependency_v1(object_name,dependency_type,dependent_name,dependency_detail)
  select r.object_name,'INDEX',i.indexname,i.indexdef
  from public.flow_storage_object_registry_v1 r
  join pg_indexes i on i.schemaname='public' and i.tablename=r.object_name;

  insert into public.flow_storage_dependency_v1(object_name,dependency_type,dependent_name,dependency_detail)
  select distinct r.object_name,'FUNCTION',p.proname,
    left(pg_get_function_identity_arguments(p.oid),1000)
  from public.flow_storage_object_registry_v1 r
  cross join pg_proc p
  join pg_namespace n on n.oid=p.pronamespace and n.nspname='public'
  where p.prokind in('f','p') and pg_get_functiondef(p.oid) ilike '%'||r.object_name||'%'
  on conflict do nothing;

  insert into public.flow_storage_dependency_v1(object_name,dependency_type,dependent_name,dependency_detail)
  select distinct r.object_name,'CRON',j.jobname,j.schedule||' | '||j.command
  from public.flow_storage_object_registry_v1 r
  cross join cron.job j
  where j.command ilike '%'||r.object_name||'%'
  on conflict do nothing;

  insert into public.flow_storage_dependency_v1(object_name,dependency_type,dependent_name,dependency_detail)
  select distinct r.object_name,'VIEW',v.table_name,left(v.view_definition,2000)
  from public.flow_storage_object_registry_v1 r
  cross join information_schema.views v
  where v.table_schema='public' and v.view_definition ilike '%'||r.object_name||'%'
  on conflict do nothing;

  insert into public.flow_storage_dependency_v1(object_name,dependency_type,dependent_name,dependency_detail)
  select r.object_name,'FOREIGN_KEY',con.conname,
    con.conrelid::regclass::text||' -> '||con.confrelid::regclass::text
  from public.flow_storage_object_registry_v1 r
  join pg_class c on c.relname=r.object_name
  join pg_namespace n on n.oid=c.relnamespace and n.nspname='public'
  join pg_constraint con on con.contype='f' and (con.conrelid=c.oid or con.confrelid=c.oid)
  on conflict do nothing;

  select count(*)::int into v_dependencies from public.flow_storage_dependency_v1;
  return jsonb_build_object('status','OK','new_objects',v_objects,
    'registered_objects',(select count(*) from public.flow_storage_object_registry_v1),
    'dependencies',v_dependencies,'removal_authorized',false);
end
$fn$;

create or replace function public.flow_refresh_storage_date_ranges_v1()
returns jsonb
language plpgsql
security invoker
set search_path=''
as $fn$
declare r record; v_min timestamptz; v_max timestamptz; v_column text; v_measured integer:=0;
begin
  for r in select object_name from public.flow_storage_object_registry_v1 order by object_name loop
    select c.column_name into v_column
    from information_schema.columns c
    where c.table_schema='public' and c.table_name=r.object_name
      and c.column_name in('trade_date','signal_date','as_of_date','snapshot_date','observed_on',
        'report_period_end','effective_from','created_at','captured_at','built_at','assessed_at')
    order by array_position(array['trade_date','signal_date','as_of_date','snapshot_date','observed_on',
      'report_period_end','effective_from','created_at','captured_at','built_at','assessed_at'],c.column_name)
    limit 1;
    if v_column is null then
      update public.flow_storage_object_registry_v1 set date_column=null,
        date_range_state='NO_DATE_COLUMN',reviewed_at=statement_timestamp()
      where object_name=r.object_name;
    else
      execute format('select min(%I)::timestamptz,max(%I)::timestamptz from public.%I',
        v_column,v_column,r.object_name) into v_min,v_max;
      update public.flow_storage_object_registry_v1 set date_column=v_column,
        min_observed_at=v_min,max_observed_at=v_max,
        date_range_state=case when v_min is null then 'EMPTY' else 'MEASURED' end,
        reviewed_at=statement_timestamp()
      where object_name=r.object_name;
      v_measured:=v_measured+1;
    end if;
    v_column:=null; v_min:=null; v_max:=null;
  end loop;
  return jsonb_build_object('status','OK','date_ranged_objects',v_measured,
    'removal_authorized',false);
end
$fn$;

create or replace function public.flow_capture_storage_observability_v1()
returns jsonb
language plpgsql
security invoker
set search_path=''
as $fn$
declare v_id uuid:=gen_random_uuid(); v_db bigint; v_public bigint; v_flow bigint;
  v_live bigint; v_dead bigint; v_quota bigint; v_warning numeric; v_critical numeric;
  v_prev_bytes bigint; v_prev_at timestamptz; v_growth bigint; v_hours numeric; v_days numeric;
  v_ratio numeric; v_status text; v_retention integer;
begin
  perform public.flow_refresh_storage_registry_v1();
  select database_quota_bytes,warning_ratio,critical_ratio,measurement_retention_days
    into v_quota,v_warning,v_critical,v_retention
  from public.flow_storage_policy_v1 where policy_version='IDX_FLOW_STORAGE_POLICY_V1';
  v_db:=pg_database_size(current_database());
  select coalesce(sum(pg_total_relation_size(c.oid)),0)::bigint into v_public
  from pg_class c join pg_namespace n on n.oid=c.relnamespace
  where n.nspname='public' and c.relkind in('r','m');
  select coalesce(sum(pg_total_relation_size(c.oid)),0)::bigint into v_flow
  from pg_class c join pg_namespace n on n.oid=c.relnamespace
  where n.nspname='public' and c.relkind in('r','m') and c.relname like 'flow_%';
  select coalesce(sum(n_live_tup),0)::bigint,coalesce(sum(n_dead_tup),0)::bigint
    into v_live,v_dead from pg_stat_user_tables where schemaname='public' and relname like 'flow_%';
  select database_bytes,measured_at into v_prev_bytes,v_prev_at
  from public.flow_storage_measurement_v1 order by measured_at desc limit 1;
  if v_prev_at is not null then
    v_growth:=v_db-v_prev_bytes;
    v_hours:=extract(epoch from(statement_timestamp()-v_prev_at))/3600.0;
    if v_growth>0 and v_hours>=1 and v_quota>v_db then
      v_days:=(v_quota-v_db)/(v_growth/v_hours)/24.0;
    elsif v_quota<=v_db then v_days:=0;
    end if;
  end if;
  v_ratio:=case when v_quota is null or v_quota=0 then null else v_db::numeric/v_quota end;
  v_status:=case when v_ratio is null then 'UNKNOWN' when v_ratio>=v_critical then 'CRITICAL'
    when v_ratio>=v_warning then 'WARNING' else 'NORMAL' end;
  insert into public.flow_storage_measurement_v1(
    measurement_id,policy_version,database_bytes,public_schema_bytes,flow_relation_bytes,
    estimated_live_rows,estimated_dead_rows,database_growth_bytes,elapsed_hours,
    projected_days_to_quota,quota_bytes,quota_ratio,storage_status,read_only_state
  ) values(v_id,'IDX_FLOW_STORAGE_POLICY_V1',v_db,v_public,v_flow,v_live,v_dead,v_growth,v_hours,
    v_days,v_quota,v_ratio,v_status,current_setting('default_transaction_read_only'));
  insert into public.flow_storage_relation_measurement_v1(
    measurement_id,object_name,total_bytes,heap_bytes,index_bytes,toast_bytes,
    estimated_live_rows,estimated_dead_rows,inserts_since_stats_reset,
    updates_since_stats_reset,deletes_since_stats_reset
  )
  select v_id,c.relname,pg_total_relation_size(c.oid),pg_relation_size(c.oid),
    pg_indexes_size(c.oid),case when c.reltoastrelid=0 then 0 else pg_total_relation_size(c.reltoastrelid) end,
    coalesce(s.n_live_tup,0),coalesce(s.n_dead_tup,0),coalesce(s.n_tup_ins,0),
    coalesce(s.n_tup_upd,0),coalesce(s.n_tup_del,0)
  from pg_class c join pg_namespace n on n.oid=c.relnamespace
  join public.flow_storage_object_registry_v1 r on r.object_name=c.relname
  left join pg_stat_user_tables s on s.relid=c.oid
  where n.nspname='public' and c.relkind in('r','m');
  delete from public.flow_storage_measurement_v1
  where measured_at<statement_timestamp()-make_interval(days=>v_retention);
  return jsonb_build_object('status',v_status,'measurement_id',v_id,'database_bytes',v_db,
    'flow_relation_bytes',v_flow,'quota_bytes',v_quota,'quota_ratio',round(v_ratio,4),
    'growth_bytes',v_growth,'projected_days_to_quota',round(v_days,2),
    'estimated_dead_rows',v_dead,'read_only_state',current_setting('default_transaction_read_only'));
end
$fn$;

create or replace function public.flow_storage_status_v1()
returns jsonb
language sql
stable
security invoker
set search_path=''
as $fn$
  with latest as (
    select * from public.flow_storage_measurement_v1 order by measured_at desc limit 1
  ), largest as (
    select coalesce(jsonb_agg(jsonb_build_object(
      'object_name',r.object_name,'storage_class',o.storage_class,
      'total_bytes',r.total_bytes,'heap_bytes',r.heap_bytes,'index_bytes',r.index_bytes,
      'estimated_live_rows',r.estimated_live_rows,'estimated_dead_rows',r.estimated_dead_rows
    ) order by r.total_bytes desc),'[]'::jsonb) payload
    from (select * from public.flow_storage_relation_measurement_v1
      where measurement_id=(select measurement_id from latest)
      order by total_bytes desc limit 15) r
    join public.flow_storage_object_registry_v1 o using(object_name)
  )
  select jsonb_build_object(
    'measurement_id',l.measurement_id,'measured_at',l.measured_at,'storage_status',l.storage_status,
    'database_bytes',l.database_bytes,'public_schema_bytes',l.public_schema_bytes,
    'flow_relation_bytes',l.flow_relation_bytes,'quota_bytes',l.quota_bytes,
    'quota_ratio',l.quota_ratio,'database_growth_bytes',l.database_growth_bytes,
    'projected_days_to_quota',l.projected_days_to_quota,'estimated_dead_rows',l.estimated_dead_rows,
    'read_only_state',l.read_only_state,'largest_relations',g.payload
  ) from latest l cross join largest g;
$fn$;

alter table public.flow_storage_policy_v1 enable row level security;
alter table public.flow_storage_object_registry_v1 enable row level security;
alter table public.flow_storage_measurement_v1 enable row level security;
alter table public.flow_storage_relation_measurement_v1 enable row level security;
alter table public.flow_storage_dependency_v1 enable row level security;

revoke all on table public.flow_storage_policy_v1,public.flow_storage_object_registry_v1,
  public.flow_storage_measurement_v1,public.flow_storage_relation_measurement_v1,
  public.flow_storage_dependency_v1 from public,anon,authenticated;
grant select,insert,update,delete on table public.flow_storage_policy_v1,
  public.flow_storage_object_registry_v1,public.flow_storage_measurement_v1,
  public.flow_storage_relation_measurement_v1,public.flow_storage_dependency_v1 to service_role;

revoke all on function public.flow_refresh_storage_registry_v1(),
  public.flow_refresh_storage_date_ranges_v1(),public.flow_capture_storage_observability_v1(),
  public.flow_storage_status_v1() from public,anon,authenticated;
grant execute on function public.flow_refresh_storage_registry_v1(),
  public.flow_refresh_storage_date_ranges_v1(),public.flow_capture_storage_observability_v1(),
  public.flow_storage_status_v1() to service_role;

do $do$
declare r record;
begin
  for r in select jobid from cron.job where jobname='flow-storage-observability-v1' loop
    perform cron.unschedule(r.jobid);
  end loop;
  perform cron.schedule('flow-storage-observability-v1','5 12 * * 1-5',
    'select public.flow_capture_storage_observability_v1();');
end
$do$;
