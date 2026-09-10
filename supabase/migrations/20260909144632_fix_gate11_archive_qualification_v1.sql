-- Qualify archive grouping columns to avoid PL/pgSQL name resolution ambiguity.
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

  execute format('select count(*) from public.%I t where t.panel_contract=$1',p_source_table)
    into v_rows using p_source_contract;
  if v_rows=0 then
    if exists(select 1 from public.flow_cold_archive_chunk_v1 c
      where c.archive_contract='GATE11_CLOSED_PANEL_ARCHIVE_V1'
        and c.source_table=p_source_table and c.source_contract=p_source_contract) then
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

  delete from public.flow_cold_archive_chunk_v1 c
  where c.archive_contract='GATE11_CLOSED_PANEL_ARCHIVE_V1'
    and c.source_table=p_source_table and c.source_contract=p_source_contract;

  execute format($sql$
    with grouped as (
      select t.panel_contract,t.signal_date,
        jsonb_agg(to_jsonb(t) order by t.ticker) payload,
        count(*)::int row_count
      from public.%I t
      where t.panel_contract=$1
      group by t.panel_contract,t.signal_date
    ), hashed as (
      select g.*,encode(extensions.digest(convert_to(g.payload::text,'UTF8'),'sha256'),'hex') payload_hash
      from grouped g
    )
    insert into public.flow_cold_archive_chunk_v1(
      archive_contract,source_table,source_contract,partition_key,source_schema_sha256,
      row_count,min_observed_date,max_observed_date,payload,payload_sha256,
      production_influence_enabled
    )
    select 'GATE11_CLOSED_PANEL_ARCHIVE_V1',$2,h.panel_contract,h.signal_date::text,$3,
      h.row_count,h.signal_date,h.signal_date,h.payload,h.payload_hash,false
    from hashed h order by h.signal_date
  $sql$,p_source_table) using p_source_contract,p_source_table,v_schema_sha;

  select count(*)::int,coalesce(sum(c.row_count),0)::bigint into v_chunks,v_archived
  from public.flow_cold_archive_chunk_v1 c
  where c.archive_contract='GATE11_CLOSED_PANEL_ARCHIVE_V1'
    and c.source_table=p_source_table and c.source_contract=p_source_contract
    and c.payload_sha256=encode(extensions.digest(convert_to(c.payload::text,'UTF8'),'sha256'),'hex')
    and jsonb_array_length(c.payload)=c.row_count;
  if v_archived<>v_rows then
    raise exception 'archive verification failed for %.%: source %, archived %',
      p_source_table,p_source_contract,v_rows,v_archived;
  end if;
  return jsonb_build_object('status','STAGED_VERIFIED','source_table',p_source_table,
    'source_contract',p_source_contract,'rows',v_rows,'chunks',v_chunks,
    'schema_sha256',v_schema_sha,'production_influence_enabled',false);
end
$fn$;

revoke all on function public.flow_archive_gate11_table_v1(text,text)
  from public,anon,authenticated;
grant execute on function public.flow_archive_gate11_table_v1(text,text) to service_role;
