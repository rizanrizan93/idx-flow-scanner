create or replace function public.flow_finalize_driver_gate13_v1()
returns jsonb
language plpgsql
security invoker
set search_path=''
as $fn$
declare
  v_contract constant text := 'IDX_DRIVER_BOUNDED_CONFLUENCE_WF_V1';
  v_parent constant text := 'IDX_DRIVER_PURGED_EXPANDING_WF_V1';
  v_at timestamptz;
  v_registered integer;
  v_budget integer;
  v_parent_state text;
  v_panel_leaks integer;
begin
  select evaluation_started_at,max_interaction_budget,registered_interactions
    into strict v_at,v_budget,v_registered
  from public.flow_driver_gate13_run_v1 where validation_contract=v_contract;
  select gate_state into strict v_parent_state
  from public.flow_driver_gate12_manifest_v1 where validation_contract=v_parent;
  select leakage_count into strict v_panel_leaks
  from public.flow_driver_panel_manifest_v1 where panel_contract='IDX_DRIVER_WEEKLY_PIT_PANEL_V1';

  delete from public.flow_driver_interaction_summary_v1 where validation_contract=v_contract;
  delete from public.flow_driver_gate13_manifest_v1 where validation_contract=v_contract;

  with oos as (
    select * from public.flow_driver_interaction_metrics_v1
    where validation_contract=v_contract and segment<>'TRAIN' and valid_sample
  ), stats as (
    select r.interaction_id,r.family,r.component_driver_ids,r.minimum_coverage_pct,
      count(oos.*)::int valid_cells,
      count(oos.*) filter(where oos.incremental_alpha_lift_pct>0)::int positive_cells,
      100.0*count(oos.*) filter(where oos.incremental_alpha_lift_pct>0)/nullif(count(oos.*),0) direction_pct,
      avg(oos.mean_alpha_vs_ihsg_pct) mean_alpha,
      avg(oos.mean_alpha_vs_ihsg_pct) filter(where oos.segment='HELDOUT') heldout_alpha,
      avg(oos.mean_alpha_vs_ihsg_pct) filter(where oos.segment='FORWARD') forward_alpha,
      avg(oos.incremental_alpha_lift_pct) mean_lift,
      avg(oos.incremental_alpha_lift_pct) filter(where oos.segment='HELDOUT') heldout_lift,
      avg(oos.incremental_alpha_lift_pct) filter(where oos.segment='FORWARD') forward_lift,
      avg(oos.coverage_pct) coverage_pct
    from public.flow_driver_interaction_registry_v1 r
    left join oos on oos.interaction_id=r.interaction_id
    where r.registry_version='IDX_DRIVER_REGISTRY_GATE10_V1'
    group by r.interaction_id,r.family,r.component_driver_ids,r.minimum_coverage_pct
  ), horizons as (
    select interaction_id,
      count(*) filter(where (horizon_days=5 and mean_lift>=0.25)
                        or (horizon_days=20 and mean_lift>=0.50)
                        or (horizon_days=60 and mean_lift>=1.00))::int positive_horizons
    from (
      select interaction_id,horizon_days,avg(incremental_alpha_lift_pct) mean_lift
      from oos group by interaction_id,horizon_days
    ) h group by interaction_id
  ), slices as (
    select interaction_id,
      100.0*count(*) filter(where slice_kind='MARKET_REGIME' and valid_sample and direction_agreement)
        /nullif(count(*) filter(where slice_kind='MARKET_REGIME' and valid_sample),0) regime_pct,
      100.0*count(*) filter(where slice_kind='LIQUIDITY_QUINTILE' and valid_sample and direction_agreement)
        /nullif(count(*) filter(where slice_kind='LIQUIDITY_QUINTILE' and valid_sample),0) liq_pct
    from public.flow_driver_interaction_slices_v1
    where validation_contract=v_contract group by interaction_id
  ), classified as (
    select s.*,coalesce(h.positive_horizons,0) positive_horizons,sl.regime_pct,sl.liq_pct,
      case
        when s.valid_cells=0 then 'INSUFFICIENT_EVIDENCE'
        when s.valid_cells>=12 and s.direction_pct>=66.67 and s.heldout_lift>0 and s.forward_lift>0
             and coalesce(h.positive_horizons,0)=3 and s.coverage_pct>=s.minimum_coverage_pct then 'VALIDATED_CONFLUENCE'
        when s.direction_pct>=66.67 and coalesce(sl.regime_pct,100)<50 then 'REGIME_DEPENDENT'
        when s.direction_pct>=66.67 and coalesce(sl.liq_pct,100)<50 then 'LIQUIDITY_SENSITIVE'
        when s.mean_lift>0 and s.direction_pct<66.67 then 'WEAK'
        when s.mean_lift<=0 and s.direction_pct<33.34 then 'REJECTED'
        else 'UNSTABLE'
      end classification
    from stats s left join horizons h using(interaction_id) left join slices sl using(interaction_id)
  )
  insert into public.flow_driver_interaction_summary_v1
  select v_contract,interaction_id,family,component_driver_ids,valid_cells,positive_cells,round(direction_pct,2),
    round(mean_alpha,4),round(heldout_alpha,4),round(forward_alpha,4),
    round(mean_lift,4),round(heldout_lift,4),round(forward_lift,4),positive_horizons,
    coalesce(round(coverage_pct,4),0),round(regime_pct,2),round(liq_pct,2),classification,
    case when 'FIN_BALANCE'=any(component_driver_ids) then 'FIN_BALANCE_DISCOVERY_OVERLAP_REQUIRES_FORWARD_CONFIRMATION'
         else 'PREREGISTERED_PHASE1_INTERACTION_OOS' end,
    classification='VALIDATED_CONFLUENCE',
    case when classification='VALIDATED_CONFLUENCE' then 'Frozen incremental-lift acceptance rule met; candidate may enter Phase 2 research only'
         when classification='INSUFFICIENT_EVIDENCE' then 'Required PIT component history unavailable or sample below frozen minimum'
         else 'Frozen Gate-13 interaction acceptance rule not met' end,
    v_at,false
  from classified;

  insert into public.flow_driver_gate13_manifest_v1
  select v_contract,'IDX_DRIVER_REGISTRY_GATE10_V1',v_parent,v_registered,
    (select count(*) from public.flow_driver_interaction_summary_v1 where validation_contract=v_contract),
    (select count(distinct interaction_id) from public.flow_driver_interaction_metrics_v1 where validation_contract=v_contract),
    (select count(*) from public.flow_driver_interaction_metrics_v1 where validation_contract=v_contract),
    (select count(*) from public.flow_driver_interaction_summary_v1 where validation_contract=v_contract and classification='VALIDATED_CONFLUENCE'),
    (select count(*) from public.flow_driver_interaction_summary_v1 where validation_contract=v_contract and classification='REJECTED'),
    (select count(*) from public.flow_driver_interaction_summary_v1 where validation_contract=v_contract and classification='INSUFFICIENT_EVIDENCE'),
    v_panel_leaks,0,0,(v_registered<=v_budget),
    case when v_parent_state='PASS' and v_panel_leaks=0 and v_registered<=v_budget
              and (select count(*) from public.flow_driver_interaction_summary_v1 where validation_contract=v_contract)=v_registered
         then 'PASS' else 'FAIL' end,
    v_at,false;

  return (select to_jsonb(m) from public.flow_driver_gate13_manifest_v1 m where validation_contract=v_contract);
end;$fn$;

revoke all on function public.flow_finalize_driver_gate13_v1() from public,anon,authenticated;
grant execute on function public.flow_finalize_driver_gate13_v1() to service_role;
