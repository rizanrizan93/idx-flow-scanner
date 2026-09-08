-- Gate 11 finalizer fix: aggregate states from the compact payload without sorting the long view.

create or replace function public.flow_finalize_driver_panel_v1()
returns jsonb language plpgsql security invoker set search_path='' set work_mem='32MB' as $fn$
declare
  v_contract constant text:='IDX_DRIVER_WEEKLY_PIT_PANEL_V1';
  v_registry constant text:='IDX_DRIVER_REGISTRY_GATE10_V1';
  v_built_at timestamptz;v_signals bigint;v_features bigint;v_observations bigint;v_available bigint;
  v_future bigint;v_revision bigint;v_target bigint:=0;v_sector bigint:=0;
begin
  select frozen_at into strict v_built_at from public.flow_driver_research_policy_v1 where registry_version=v_registry;
  select count(*) into v_signals from public.flow_driver_signal_panel_v1 where panel_contract=v_contract;
  select count(*) into v_features from public.flow_driver_feature_panel_v1 where panel_contract=v_contract;
  if v_signals=0 or v_features<>v_signals then raise exception 'Gate11 stages incomplete: signals %, features %',v_signals,v_features; end if;
  delete from public.flow_driver_panel_manifest_v1 where panel_contract=v_contract;
  delete from public.flow_driver_coverage_v1 where panel_contract=v_contract;

  drop table if exists pg_temp.flow_gate11_state_counts;
  create temp table flow_gate11_state_counts on commit drop as
  with state_rows as (
    select r.driver_id,r.family,
      case when r.family='FINANCIAL' then
        case when f.financial_available_from_date>f.signal_date then 'INVALID'
          when r.driver_id='FIN_GROWTH' then coalesce(f.financial_feature_states->>'growth',f.financial_state,'MISSING')
          when r.driver_id='FIN_CASHFLOW' then coalesce(f.financial_feature_states->>'cashflow',f.financial_state,'MISSING')
          when nullif(f.raw_values->>r.driver_id,'') is not null and f.financial_state='AVAILABLE' then 'AVAILABLE'
          else coalesce(f.financial_state,'MISSING') end
        when f.history_count<r.minimum_history_sessions then 'INSUFFICIENT_HISTORY'
        when nullif(f.raw_values->>r.driver_id,'') is null then 'MISSING'
        else 'AVAILABLE' end driver_state
    from public.flow_driver_feature_panel_v1 f
    join public.flow_driver_registry_v1 r on r.registry_version=v_registry and r.evaluation_eligible
    where f.panel_contract=v_contract
  )
  select driver_id,family,count(*) total_rows,count(*) filter(where driver_state='AVAILABLE') available_rows,
    count(*) filter(where driver_state='MISSING') missing_rows,count(*) filter(where driver_state='STALE') stale_rows,
    count(*) filter(where driver_state='INVALID') invalid_rows,count(*) filter(where driver_state='NOT_APPLICABLE') not_applicable_rows,
    count(*) filter(where driver_state='INSUFFICIENT_HISTORY') insufficient_history_rows
  from state_rows group by driver_id,family;

  insert into public.flow_driver_coverage_v1
  select v_contract,'DRIVER',r.driver_id,coalesce(c.total_rows,0),coalesce(c.available_rows,0),coalesce(c.missing_rows,0),
    coalesce(c.stale_rows,0),coalesce(c.invalid_rows,0),coalesce(c.not_applicable_rows,0),coalesce(c.insufficient_history_rows,0),
    coalesce(round(100.0*c.available_rows/nullif(c.total_rows,0),4),0),
    coalesce(round(100.0*c.stale_rows/nullif(c.total_rows,0),4),0),
    coalesce(round(100.0*c.invalid_rows/nullif(c.total_rows,0),4),0),v_built_at
  from public.flow_driver_registry_v1 r left join pg_temp.flow_gate11_state_counts c on c.driver_id=r.driver_id
  where r.registry_version=v_registry;

  insert into public.flow_driver_coverage_v1
  select v_contract,'FAMILY',r.family,coalesce(sum(c.total_rows),0),coalesce(sum(c.available_rows),0),coalesce(sum(c.missing_rows),0),
    coalesce(sum(c.stale_rows),0),coalesce(sum(c.invalid_rows),0),coalesce(sum(c.not_applicable_rows),0),coalesce(sum(c.insufficient_history_rows),0),
    coalesce(round(100.0*sum(c.available_rows)/nullif(sum(c.total_rows),0),4),0),
    coalesce(round(100.0*sum(c.stale_rows)/nullif(sum(c.total_rows),0),4),0),
    coalesce(round(100.0*sum(c.invalid_rows)/nullif(sum(c.total_rows),0),4),0),v_built_at
  from public.flow_driver_registry_v1 r left join pg_temp.flow_gate11_state_counts c on c.driver_id=r.driver_id
  where r.registry_version=v_registry group by r.family;

  select coalesce(sum(total_rows),0),coalesce(sum(available_rows),0) into v_observations,v_available
  from pg_temp.flow_gate11_state_counts;
  select 4*count(*) filter(where financial_available_from_date>signal_date),
    4*count(*) filter(where financial_available_from_date>signal_date and current_filing_id is not null)
  into v_future,v_revision from public.flow_driver_feature_panel_v1 where panel_contract=v_contract;

  insert into public.flow_driver_panel_manifest_v1
  select v_contract,v_registry,v_signals,v_observations,count(distinct signal_date),count(distinct ticker),count(distinct sector),
    v_available,round(100.0*v_available/nullif(v_observations,0),4),
    coalesce((select round(100.0*sum(missing_rows)/nullif(sum(total_rows),0),4) from pg_temp.flow_gate11_state_counts),0),
    coalesce((select round(100.0*sum(stale_rows)/nullif(sum(total_rows),0),4) from pg_temp.flow_gate11_state_counts),0),
    coalesce((select round(100.0*sum(invalid_rows)/nullif(sum(total_rows),0),4) from pg_temp.flow_gate11_state_counts),0),
    jsonb_build_object('future_evidence',v_future,'future_financial',v_future,'future_flow',0,'future_benchmark',0,
      'future_sector_membership_feature_rows',v_sector,'future_ownership',0,'future_event',0,
      'lookahead_normalization',0,'forward_return_used_in_features',v_target),
    v_future+v_sector,v_revision,v_target,'COMPLETE',v_built_at,false
  from public.flow_driver_signal_panel_v1 where panel_contract=v_contract;
  return jsonb_build_object('status','PASS','signal_rows',v_signals,'feature_rows',v_features,
    'observation_rows',v_observations,'available_observations',v_available,'leakage_count',v_future+v_sector,
    'revision_leakage_count',v_revision,'target_leakage_count',v_target,'production_influence_enabled',false);
end;$fn$;

revoke all on function public.flow_finalize_driver_panel_v1() from public,anon,authenticated;
grant execute on function public.flow_finalize_driver_panel_v1() to service_role;
