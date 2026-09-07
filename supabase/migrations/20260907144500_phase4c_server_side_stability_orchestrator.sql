-- Phase 4C server-side stability orchestrator.
-- Runs the already-tested family-pruned temp path entirely inside one backend session,
-- avoiding client/upstream timeout during temp preparation. Direct ALL-history rows are
-- backed up and restored so their richer direct-slice decile+quintile bin_stats remain canonical.

create or replace function public.flow_run_phase4c_stability_family_v4(p_factor_family text)
returns jsonb
language plpgsql
security invoker
set search_path=pg_catalog,public
set statement_timeout='0'
as $$
declare
  v_asof date;
  v_prepared integer;
  v_factor text;
  v_factor_count integer:=0;
  v_rows_written integer:=0;
begin
  if p_factor_family not in ('PRICE_MOMENTUM','FLOW_LIQUIDITY','MARKET_REGIME','RISK_ACTION') then
    raise exception 'Unsupported Phase4C stability family %',p_factor_family;
  end if;

  select max(as_of_date) into v_asof
  from public.flow_market_memory_manifest_v4
  where feature_contract='MARKET_MEMORY_V4_1';

  drop table if exists pg_temp.flow_phase4c_all_backup;
  create temp table flow_phase4c_all_backup on commit drop as
  select *
  from public.flow_factor_discovery_v4
  where discovery_as_of=v_asof
    and discovery_contract='FACTOR_DISCOVERY_V4_1'
    and factor_family=p_factor_family
    and stability_window='ALL';

  v_prepared:=public.flow_prepare_phase4c_temp_family_v4(p_factor_family);

  for v_factor in
    select factor_name
    from public.flow_factor_catalog_v4
    where factor_family=p_factor_family
    order by factor_name
  loop
    v_rows_written:=v_rows_written+public.flow_refresh_factor_discovery_one_v4(v_factor);
    v_factor_count:=v_factor_count+1;
  end loop;

  -- Preserve the direct ALL-history aggregates and their decile+quintile bin_stats.
  delete from public.flow_factor_discovery_v4
  where discovery_as_of=v_asof
    and discovery_contract='FACTOR_DISCOVERY_V4_1'
    and factor_family=p_factor_family
    and stability_window='ALL';

  insert into public.flow_factor_discovery_v4
  select * from pg_temp.flow_phase4c_all_backup;

  return jsonb_build_object(
    'status','OK',
    'as_of_date',v_asof,
    'factor_family',p_factor_family,
    'temp_rows',v_prepared,
    'factor_count',v_factor_count,
    'stability_rows_written',v_rows_written-v_factor_count*5,
    'storage_policy','BACKEND_SESSION_TEMP_ONLY_NO_PERSISTENT_PANEL'
  );
end;
$$;

revoke all on function public.flow_run_phase4c_stability_family_v4(text) from public,anon,authenticated;
grant execute on function public.flow_run_phase4c_stability_family_v4(text) to service_role;

comment on function public.flow_run_phase4c_stability_family_v4(text) is
'Phase4C server-side family stability orchestration. Builds one family-pruned temp panel in the backend session, computes ALL/EARLY/MIDDLE/RECENT via existing discovery core, then restores richer direct ALL-history rows. No persistent duplicate market panel.';
