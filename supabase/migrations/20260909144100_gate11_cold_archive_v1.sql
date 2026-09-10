-- Lossless cold representation for formally closed Gate 11 V1/V2 raw panels.
-- Source tables are only truncated by the separate finalizer after every chunk,
-- hash, row count, closure manifest, and JSON recordset shape has been verified.
create table if not exists public.flow_cold_archive_contract_v1(
  archive_contract text primary key,
  purpose text not null,
  source_contracts text[] not null,
  restore_policy text not null,
  production_dependency_state text not null,
  created_at timestamptz not null default statement_timestamp()
);

insert into public.flow_cold_archive_contract_v1(
  archive_contract,purpose,source_contracts,restore_policy,production_dependency_state
) values(
  'GATE11_CLOSED_PANEL_ARCHIVE_V1',
  'Lossless compact archive of frozen Gate 11 V1/V2 feature, signal, and V2 lineage rows after Gate 12/13 formal closure.',
  array['IDX_DRIVER_WEEKLY_PIT_PANEL_V1','IDX_DRIVER_WEEKLY_PIT_PANEL_V2'],
  'Restore only for an explicit versioned research rerun after capacity preflight. Daily production and prospective Gate 14/15 do not require these closed raw rows.',
  'NO_ACTIVE_PRODUCTION_SCORE_RANK_ACTION_OR_EXECUTION_DEPENDENCY'
) on conflict(archive_contract) do nothing;

create table if not exists public.flow_cold_archive_chunk_v1(
  archive_contract text not null references public.flow_cold_archive_contract_v1(archive_contract),
  source_table text not null,
  source_contract text not null,
  partition_key text not null,
  source_schema_sha256 text not null,
  row_count integer not null check(row_count>0),
  min_observed_date date,
  max_observed_date date,
  payload jsonb not null,
  payload_sha256 text not null,
  archived_at timestamptz not null default statement_timestamp(),
  production_influence_enabled boolean not null default false check(production_influence_enabled=false),
  primary key(archive_contract,source_table,source_contract,partition_key),
  check(jsonb_typeof(payload)='array'),
  check(jsonb_array_length(payload)=row_count)
);

alter table public.flow_cold_archive_chunk_v1 alter column payload set compression lz4;

create index if not exists flow_cold_archive_chunk_v1_source_idx
  on public.flow_cold_archive_chunk_v1(source_table,source_contract,partition_key);

create table if not exists public.flow_cold_archive_manifest_v1(
  archive_contract text not null references public.flow_cold_archive_contract_v1(archive_contract),
  source_table text not null,
  source_row_count bigint not null,
  archived_row_count bigint not null,
  chunk_count integer not null,
  source_bytes_before bigint not null,
  source_bytes_after bigint,
  archive_relation_bytes bigint,
  aggregate_payload_sha256 text not null,
  closure_evidence jsonb not null,
  archive_state text not null check(archive_state in(
    'STAGED_VERIFIED','ARCHIVED_SOURCE_TRUNCATED','RESTORED_EXPLICITLY','FAIL_CLOSED'
  )),
  source_truncated boolean not null default false,
  verified_at timestamptz not null default statement_timestamp(),
  production_influence_enabled boolean not null default false check(production_influence_enabled=false),
  primary key(archive_contract,source_table)
);

create or replace function public.flow_archive_gate11_table_v1(
  p_source_table text,
  p_source_contract text
)
returns jsonb
language plpgsql
security invoker
set search_path=''
set work_mem='64MB'
as $fn$
declare v_schema_sha text; v_rows bigint; v_chunks integer; v_archived bigint;
begin
  if p_source_table not in('flow_driver_feature_panel_v1','flow_driver_signal_panel_v1',
    'flow_driver_panel_lineage_v2') then
    raise exception 'source table is not approved for Gate11 cold archive';
  end if;
  if p_source_contract not in('IDX_DRIVER_WEEKLY_PIT_PANEL_V1','IDX_DRIVER_WEEKLY_PIT_PANEL_V2') then
    raise exception 'source contract is not a frozen Gate11 panel contract';
  end if;
  if p_source_table='flow_driver_panel_lineage_v2'
    and p_source_contract<>'IDX_DRIVER_WEEKLY_PIT_PANEL_V2' then
    raise exception 'lineage V2 only belongs to the V2 panel contract';
  end if;

  execute format('select count(*) from public.%I where panel_contract=$1',p_source_table)
    into v_rows using p_source_contract;
  if v_rows=0 then
    if exists(select 1 from public.flow_cold_archive_chunk_v1
      where archive_contract='GATE11_CLOSED_PANEL_ARCHIVE_V1'
        and source_table=p_source_table and source_contract=p_source_contract) then
      return jsonb_build_object('status','ALREADY_STAGED_OR_SOURCE_TRUNCATED',
        'source_table',p_source_table,'source_contract',p_source_contract);
    end if;
    raise exception 'approved source contract has no rows and no archive';
  end if;

  select encode(extensions.digest(convert_to(string_agg(
    c.column_name||':'||c.data_type||':'||c.is_nullable,'|' order by c.ordinal_position
  ),'UTF8'),'sha256'),'hex') into v_schema_sha
  from information_schema.columns c
  where c.table_schema='public' and c.table_name=p_source_table;

  delete from public.flow_cold_archive_chunk_v1
  where archive_contract='GATE11_CLOSED_PANEL_ARCHIVE_V1'
    and source_table=p_source_table and source_contract=p_source_contract;

  execute format($sql$
    with grouped as (
      select panel_contract,signal_date,
        jsonb_agg(to_jsonb(t) order by ticker) payload,
        count(*)::int row_count
      from public.%I t
      where panel_contract=$1
      group by panel_contract,signal_date
    ), hashed as (
      select *,encode(extensions.digest(convert_to(payload::text,'UTF8'),'sha256'),'hex') payload_hash
      from grouped
    )
    insert into public.flow_cold_archive_chunk_v1(
      archive_contract,source_table,source_contract,partition_key,source_schema_sha256,
      row_count,min_observed_date,max_observed_date,payload,payload_sha256,
      production_influence_enabled
    )
    select 'GATE11_CLOSED_PANEL_ARCHIVE_V1',$2,panel_contract,signal_date::text,$3,
      row_count,signal_date,signal_date,payload,payload_hash,false
    from hashed order by signal_date
  $sql$,p_source_table) using p_source_contract,p_source_table,v_schema_sha;

  select count(*)::int,coalesce(sum(row_count),0)::bigint into v_chunks,v_archived
  from public.flow_cold_archive_chunk_v1
  where archive_contract='GATE11_CLOSED_PANEL_ARCHIVE_V1'
    and source_table=p_source_table and source_contract=p_source_contract
    and payload_sha256=encode(extensions.digest(convert_to(payload::text,'UTF8'),'sha256'),'hex')
    and jsonb_array_length(payload)=row_count;
  if v_archived<>v_rows then
    raise exception 'archive verification failed for %.%: source %, archived %',
      p_source_table,p_source_contract,v_rows,v_archived;
  end if;
  return jsonb_build_object('status','STAGED_VERIFIED','source_table',p_source_table,
    'source_contract',p_source_contract,'rows',v_rows,'chunks',v_chunks,
    'schema_sha256',v_schema_sha,'production_influence_enabled',false);
end
$fn$;

create or replace function public.flow_finalize_gate11_cold_archive_v1()
returns jsonb
language plpgsql
security invoker
set search_path=''
as $fn$
declare v_table text; v_source_rows bigint; v_archived_rows bigint; v_chunks integer;
  v_before bigint; v_after bigint; v_digest text; v_total_before bigint:=0; v_total_after bigint:=0;
  v_panel_ok boolean; v_gate12_ok boolean; v_gate13_ok boolean;
begin
  select exists(select 1 from public.flow_driver_panel_manifest_v1
    where panel_contract='IDX_DRIVER_WEEKLY_PIT_PANEL_V2' and build_state='COMPLETE'
      and leakage_count=0 and revision_leakage_count=0 and target_leakage_count=0)
    into v_panel_ok;
  select exists(select 1 from public.flow_driver_gate12_manifest_v1
    where validation_contract='IDX_DRIVER_PURGED_EXPANDING_WF_V2' and gate_state='PASS'
      and evaluated_drivers=37 and invalid_metric_cells=0 and training_target_overlap_leaks=0)
    into v_gate12_ok;
  select exists(select 1 from public.flow_driver_gate13_manifest_v1
    where validation_contract='IDX_DRIVER_BOUNDED_CONFLUENCE_WF_V2' and gate_state='PASS'
      and registered_interactions=12 and target_leakage_count=0 and posthoc_mining_count=0)
    into v_gate13_ok;
  if not(v_panel_ok and v_gate12_ok and v_gate13_ok) then
    raise exception 'Gate11/12/13 closure evidence is incomplete; archive finalization denied';
  end if;

  lock table public.flow_driver_signal_panel_v1,public.flow_driver_feature_panel_v1,
    public.flow_driver_panel_lineage_v2 in access exclusive mode;

  foreach v_table in array array['flow_driver_signal_panel_v1','flow_driver_feature_panel_v1',
    'flow_driver_panel_lineage_v2'] loop
    execute format('select count(*),pg_total_relation_size(%L::regclass) from public.%I',
      'public.'||v_table,v_table) into v_source_rows,v_before;
    select coalesce(sum(row_count),0)::bigint,count(*)::int,
      encode(extensions.digest(convert_to(string_agg(payload_sha256,'|' order by source_contract,partition_key),
        'UTF8'),'sha256'),'hex')
      into v_archived_rows,v_chunks,v_digest
    from public.flow_cold_archive_chunk_v1
    where archive_contract='GATE11_CLOSED_PANEL_ARCHIVE_V1' and source_table=v_table
      and payload_sha256=encode(extensions.digest(convert_to(payload::text,'UTF8'),'sha256'),'hex')
      and jsonb_array_length(payload)=row_count;
    if v_source_rows=0 and exists(select 1 from public.flow_cold_archive_manifest_v1
      where archive_contract='GATE11_CLOSED_PANEL_ARCHIVE_V1' and source_table=v_table
        and source_truncated and archive_state='ARCHIVED_SOURCE_TRUNCATED') then
      continue;
    end if;
    if v_source_rows=0 or v_archived_rows<>v_source_rows or v_digest is null then
      raise exception 'lossless archive finalization failed for %: source %, archive %',
        v_table,v_source_rows,v_archived_rows;
    end if;
    insert into public.flow_cold_archive_manifest_v1(
      archive_contract,source_table,source_row_count,archived_row_count,chunk_count,
      source_bytes_before,aggregate_payload_sha256,closure_evidence,archive_state,
      source_truncated,production_influence_enabled
    ) values(
      'GATE11_CLOSED_PANEL_ARCHIVE_V1',v_table,v_source_rows,v_archived_rows,v_chunks,
      v_before,v_digest,jsonb_build_object(
        'panel_v2_complete',v_panel_ok,'gate12_v2_pass',v_gate12_ok,'gate13_v2_pass',v_gate13_ok,
        'recordset_shape_verified',true,'archive_is_only_cold_representation',true
      ),'STAGED_VERIFIED',false,false
    ) on conflict(archive_contract,source_table) do update set
      source_row_count=excluded.source_row_count,archived_row_count=excluded.archived_row_count,
      chunk_count=excluded.chunk_count,source_bytes_before=excluded.source_bytes_before,
      aggregate_payload_sha256=excluded.aggregate_payload_sha256,
      closure_evidence=excluded.closure_evidence,archive_state='STAGED_VERIFIED',
      source_truncated=false,verified_at=statement_timestamp();
    v_total_before:=v_total_before+v_before;
  end loop;

  -- FK order is signal parent + feature child; truncating the full set is atomic.
  truncate table public.flow_driver_feature_panel_v1,public.flow_driver_signal_panel_v1,
    public.flow_driver_panel_lineage_v2;

  foreach v_table in array array['flow_driver_signal_panel_v1','flow_driver_feature_panel_v1',
    'flow_driver_panel_lineage_v2'] loop
    execute format('select pg_total_relation_size(%L::regclass)','public.'||v_table) into v_after;
    update public.flow_cold_archive_manifest_v1 set source_bytes_after=v_after,
      archive_relation_bytes=pg_total_relation_size('public.flow_cold_archive_chunk_v1'::regclass),
      archive_state='ARCHIVED_SOURCE_TRUNCATED',source_truncated=true,
      verified_at=statement_timestamp()
    where archive_contract='GATE11_CLOSED_PANEL_ARCHIVE_V1' and source_table=v_table;
    v_total_after:=v_total_after+v_after;
  end loop;
  update public.flow_storage_object_registry_v1 set
    storage_class='COLD_RESEARCH',
    derivation_state='LOSSLESS_LZ4_JSONB_ARCHIVE_WITH_EXPLICIT_RESTORE_PATH',
    retention_requirement='COLD_ARCHIVE RETAINED; HOT SOURCE TRUNCATED AFTER HASH_AND_ROWCOUNT_VERIFICATION',
    removal_authorized=false,reviewed_at=statement_timestamp()
  where object_name in('flow_driver_feature_panel_v1','flow_driver_signal_panel_v1',
    'flow_driver_panel_lineage_v2');
  return jsonb_build_object('status','ARCHIVED_SOURCE_TRUNCATED',
    'source_bytes_before',v_total_before,'source_bytes_after',v_total_after,
    'gross_source_bytes_reclaimed',v_total_before-v_total_after,
    'archive_relation_bytes',pg_total_relation_size('public.flow_cold_archive_chunk_v1'::regclass),
    'production_influence_enabled',false);
end
$fn$;

create or replace function public.flow_restore_gate11_cold_archive_v1(
  p_confirm_capacity boolean default false
)
returns jsonb
language plpgsql
security invoker
set search_path=''
set work_mem='64MB'
as $fn$
declare v_table text; v_expected bigint; v_restored bigint;
begin
  if not coalesce(p_confirm_capacity,false) then
    raise exception 'explicit capacity confirmation is required before restoring cold Gate11 panels';
  end if;
  if exists(select 1 from public.flow_cold_archive_manifest_v1
    where archive_contract='GATE11_CLOSED_PANEL_ARCHIVE_V1'
      and archive_state<>'ARCHIVED_SOURCE_TRUNCATED') then
    raise exception 'archive manifest is not in a restorable state';
  end if;
  if (select count(*) from public.flow_driver_signal_panel_v1)>0
    or (select count(*) from public.flow_driver_feature_panel_v1)>0
    or (select count(*) from public.flow_driver_panel_lineage_v2)>0 then
    raise exception 'restore target tables must be empty';
  end if;
  foreach v_table in array array['flow_driver_signal_panel_v1','flow_driver_feature_panel_v1',
    'flow_driver_panel_lineage_v2'] loop
    execute format($sql$
      insert into public.%I
      select x.*
      from public.flow_cold_archive_chunk_v1 c
      cross join lateral jsonb_populate_recordset(null::public.%I,c.payload) x
      where c.archive_contract='GATE11_CLOSED_PANEL_ARCHIVE_V1'
        and c.source_table=$1
      order by c.source_contract,c.partition_key
    $sql$,v_table,v_table) using v_table;
    execute format('select count(*) from public.%I',v_table) into v_restored;
    select source_row_count into v_expected from public.flow_cold_archive_manifest_v1
    where archive_contract='GATE11_CLOSED_PANEL_ARCHIVE_V1' and source_table=v_table;
    if v_restored<>v_expected then raise exception 'restore count mismatch for %',v_table; end if;
  end loop;
  update public.flow_cold_archive_manifest_v1 set archive_state='RESTORED_EXPLICITLY',
    source_truncated=false,verified_at=statement_timestamp()
  where archive_contract='GATE11_CLOSED_PANEL_ARCHIVE_V1';
  return jsonb_build_object('status','RESTORED_EXPLICITLY','production_influence_enabled',false);
end
$fn$;

alter table public.flow_cold_archive_contract_v1 enable row level security;
alter table public.flow_cold_archive_chunk_v1 enable row level security;
alter table public.flow_cold_archive_manifest_v1 enable row level security;
revoke all on table public.flow_cold_archive_contract_v1,public.flow_cold_archive_chunk_v1,
  public.flow_cold_archive_manifest_v1 from public,anon,authenticated;
grant select,insert,update,delete on table public.flow_cold_archive_contract_v1,
  public.flow_cold_archive_chunk_v1,public.flow_cold_archive_manifest_v1 to service_role;
revoke all on function public.flow_archive_gate11_table_v1(text,text),
  public.flow_finalize_gate11_cold_archive_v1(),public.flow_restore_gate11_cold_archive_v1(boolean)
  from public,anon,authenticated;
grant execute on function public.flow_archive_gate11_table_v1(text,text),
  public.flow_finalize_gate11_cold_archive_v1(),public.flow_restore_gate11_cold_archive_v1(boolean)
  to service_role;
