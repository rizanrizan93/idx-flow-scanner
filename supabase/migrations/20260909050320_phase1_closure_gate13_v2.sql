create or replace function public.flow_initialize_driver_gate13_v2()
returns jsonb language plpgsql security invoker set search_path='' as $fn$
declare
  v_contract constant text:='IDX_DRIVER_BOUNDED_CONFLUENCE_WF_V2'; v_parent constant text:='IDX_DRIVER_PURGED_EXPANDING_WF_V2'; v_registry constant text:='IDX_DRIVER_REGISTRY_GATE10_V2';
  v_frozen timestamptz; v_at timestamptz:=clock_timestamp(); v_budget int; v_registered int; v_parent_state text;
begin
  select frozen_at,max_interaction_budget into strict v_frozen,v_budget from public.flow_driver_research_policy_v1 where registry_version=v_registry;
  select count(*) into v_registered from public.flow_driver_interaction_registry_v1 where registry_version=v_registry;
  select gate_state into strict v_parent_state from public.flow_driver_gate12_manifest_v1 where validation_contract=v_parent;
  if v_parent_state<>'PASS' then raise exception 'Gate12 V2 parent not PASS: %',v_parent_state; end if;
  if v_frozen>=v_at then raise exception 'Registry not frozen before Gate13 evaluation'; end if;
  if v_registered>v_budget then raise exception 'Interaction budget exceeded: % > %',v_registered,v_budget; end if;
  delete from public.flow_driver_interaction_metrics_v1 where validation_contract=v_contract;
  delete from public.flow_driver_interaction_slices_v1 where validation_contract=v_contract;
  delete from public.flow_driver_interaction_summary_v1 where validation_contract=v_contract;
  delete from public.flow_driver_gate13_manifest_v1 where validation_contract=v_contract;
  delete from public.flow_driver_gate13_run_v1 where validation_contract=v_contract;
  insert into public.flow_driver_gate13_run_v1 values(v_contract,v_registry,v_parent,v_at,v_frozen,v_budget,v_registered,false);
  return jsonb_build_object('status','PASS','registered_interactions',v_registered,'max_interaction_budget',v_budget,
    'registry_frozen_before_evaluation',v_frozen<v_at,'production_influence_enabled',false);
end;$fn$;

create or replace function public.flow_run_interaction_oos_v2(p_interaction_id text)
returns jsonb language plpgsql security invoker set search_path='' set work_mem='24MB' as $fn$
declare
  v_contract constant text:='IDX_DRIVER_BOUNDED_CONFLUENCE_WF_V2'; v_parent constant text:='IDX_DRIVER_PURGED_EXPANDING_WF_V2';
  v_panel constant text:='IDX_DRIVER_WEEKLY_PIT_PANEL_V2'; v_registry constant text:='IDX_DRIVER_REGISTRY_GATE10_V2';
  v_components text[]; v_family text; v_min_coverage numeric; v_min_sample int; v_component_count int; v_ready_count int; v_at timestamptz; v_rows int;
begin
  select component_driver_ids,family,minimum_coverage_pct,minimum_sample_size into strict v_components,v_family,v_min_coverage,v_min_sample
  from public.flow_driver_interaction_registry_v1 where registry_version=v_registry and interaction_id=p_interaction_id;
  select evaluation_started_at into strict v_at from public.flow_driver_gate13_run_v1 where validation_contract=v_contract;
  v_component_count:=cardinality(v_components);
  select count(*) into v_ready_count from unnest(v_components) c(driver_id)
  join public.flow_driver_registry_v1 r on r.registry_version=v_registry and r.driver_id=c.driver_id and r.evaluation_eligible
  join public.flow_driver_coverage_v1 cv on cv.panel_contract=v_panel and cv.entity_type='DRIVER' and cv.entity_id=c.driver_id and cv.coverage_pct>0;
  delete from public.flow_driver_interaction_metrics_v1 where validation_contract=v_contract and interaction_id=p_interaction_id;
  delete from public.flow_driver_interaction_slices_v1 where validation_contract=v_contract and interaction_id=p_interaction_id;
  if v_ready_count<v_component_count then
    return jsonb_build_object('status','INSUFFICIENT_EVIDENCE','interaction_id',p_interaction_id,'ready_components',v_ready_count,'required_components',v_component_count,'production_influence_enabled',false);
  end if;

  insert into public.flow_driver_interaction_metrics_v1
  with comp_raw as (
    select f.signal_date,f.ticker,c.driver_id,r.family,r.direction_hypothesis,r.minimum_history_sessions,
      nullif(f.raw_values->>c.driver_id,'')::numeric raw_value,
      case when r.family='FINANCIAL' then
        case when f.financial_available_from_date>f.signal_date then 'INVALID'
          when c.driver_id='FIN_GROWTH' then coalesce(f.financial_feature_states->>'growth',f.financial_state,'MISSING')
          when c.driver_id='FIN_CASHFLOW' then coalesce(f.financial_feature_states->>'cashflow',f.financial_state,'MISSING')
          when nullif(f.raw_values->>c.driver_id,'') is not null and f.financial_state='AVAILABLE' then 'AVAILABLE'
          else coalesce(f.financial_state,'MISSING') end
        when f.history_count<r.minimum_history_sessions then 'INSUFFICIENT_HISTORY'
        when nullif(f.raw_values->>c.driver_id,'') is null then 'MISSING' else 'AVAILABLE' end driver_state
    from public.flow_driver_feature_panel_v1 f
    cross join unnest(v_components) c(driver_id)
    join public.flow_driver_registry_v1 r on r.registry_version=v_registry and r.driver_id=c.driver_id
    where f.panel_contract=v_panel
  ), comp_oriented as (
    select *,case when driver_state='AVAILABLE' then raw_value*direction_hypothesis end transformed_value from comp_raw
  ), comp_norm as (
    select *,case when driver_state='AVAILABLE' then percent_rank() over(partition by signal_date,driver_id,driver_state order by transformed_value) end normalized_value
    from comp_oriented
  ), grouped as (
    select signal_date,ticker,
      count(*) filter(where driver_state='AVAILABLE' and normalized_value is not null) available_components,
      min(normalized_value) filter(where driver_state='AVAILABLE') interaction_score,
      (count(*)=v_component_count and bool_and(driver_state='AVAILABLE' and normalized_value is not null)) component_available,
      (count(*)=v_component_count and bool_and(driver_state='AVAILABLE' and normalized_value>=0.80)) confluence_signal
    from comp_norm group by signal_date,ticker
  ), base as (
    select g.*,s.market_regime,
      percent_rank() over(partition by g.signal_date order by nullif(f.raw_values->>'LIQ_TURNOVER','')::numeric) liquidity_rank,
      s.target_date_5d,s.target_date_20d,s.target_date_60d,
      s.forward_return_5d_pct,s.forward_return_20d_pct,s.forward_return_60d_pct,
      s.alpha_vs_ihsg_5d_pct,s.alpha_vs_ihsg_20d_pct,s.alpha_vs_ihsg_60d_pct,
      s.mfe_5d_pct,s.mfe_20d_pct,s.mfe_60d_pct,s.mae_5d_pct,s.mae_20d_pct,s.mae_60d_pct
    from grouped g
    join public.flow_driver_signal_panel_v1 s on s.panel_contract=v_panel and s.signal_date=g.signal_date and s.ticker=g.ticker
    join public.flow_driver_feature_panel_v1 f on f.panel_contract=v_panel and f.signal_date=g.signal_date and f.ticker=g.ticker
  ), expanded as (
    select b.*,h.* from base b cross join lateral(values
      (5,b.target_date_5d,b.forward_return_5d_pct,b.alpha_vs_ihsg_5d_pct,b.mfe_5d_pct,b.mae_5d_pct),
      (20,b.target_date_20d,b.forward_return_20d_pct,b.alpha_vs_ihsg_20d_pct,b.mfe_20d_pct,b.mae_20d_pct),
      (60,b.target_date_60d,b.forward_return_60d_pct,b.alpha_vs_ihsg_60d_pct,b.mfe_60d_pct,b.mae_60d_pct)
    ) h(horizon_days,target_date,forward_return,alpha_ihsg,mfe,mae)
  ), segmented as (
    select e.*,wf.fold_no,x.segment
    from expanded e join public.flow_driver_walkforward_folds_v1 wf on wf.validation_contract=v_parent and wf.horizon_days=e.horizon_days
    cross join lateral(values('TRAIN'::text,wf.train_start,wf.train_end),('VALIDATION',wf.validation_start,wf.validation_end),
      ('HELDOUT',wf.heldout_start,wf.heldout_end),('FORWARD',wf.forward_start,wf.forward_end)) x(segment,start_date,end_date)
    where e.signal_date between x.start_date and x.end_date and e.target_date is not null and e.alpha_ihsg is not null
      and (x.segment<>'TRAIN' or e.target_date<=wf.train_end)
  ), agg as (
    select horizon_days,fold_no,segment,count(*)::int universe_count,
      count(*) filter(where component_available)::int component_available_count,
      count(*) filter(where confluence_signal)::int confluence_count,
      100.0*count(*) filter(where confluence_signal)/nullif(count(*),0) coverage_pct,
      avg(forward_return) filter(where confluence_signal) mean_return,
      avg(alpha_ihsg) filter(where confluence_signal) mean_alpha,
      100.0*avg((alpha_ihsg>0)::int) filter(where confluence_signal) hit_rate,
      avg(mfe) filter(where confluence_signal) mean_mfe,avg(mae) filter(where confluence_signal) mean_mae
    from segmented group by horizon_days,fold_no,segment
  )
  select v_contract,p_interaction_id,v_family,a.horizon_days,a.fold_no,a.segment,a.universe_count,a.component_available_count,a.confluence_count,
    round(a.coverage_pct,4),a.mean_return,a.mean_alpha,a.hit_rate,a.mean_mfe,a.mean_mae,
    sc.driver_id,sc.top_mean_alpha_vs_ihsg_pct,a.mean_alpha-sc.top_mean_alpha_vs_ihsg_pct,
    (a.confluence_count>=v_min_sample and a.coverage_pct>=v_min_coverage and a.mean_alpha is not null and sc.top_mean_alpha_vs_ihsg_pct is not null),
    v_at,false
  from agg a left join lateral (
    select m.driver_id,m.top_mean_alpha_vs_ihsg_pct
    from public.flow_driver_oos_metrics_v1 m
    where m.validation_contract=v_parent and m.driver_id=any(v_components) and m.horizon_days=a.horizon_days
      and m.fold_no=a.fold_no and m.segment=a.segment and m.top_mean_alpha_vs_ihsg_pct is not null
    order by m.top_mean_alpha_vs_ihsg_pct desc,m.driver_id limit 1
  ) sc on true;
  get diagnostics v_rows=row_count;

  insert into public.flow_driver_interaction_slices_v1
  with comp_raw as (
    select f.signal_date,f.ticker,c.driver_id,r.direction_hypothesis,r.minimum_history_sessions,
      nullif(f.raw_values->>c.driver_id,'')::numeric raw_value,
      case when r.family='FINANCIAL' then
        case when f.financial_available_from_date>f.signal_date then 'INVALID'
          when c.driver_id='FIN_GROWTH' then coalesce(f.financial_feature_states->>'growth',f.financial_state,'MISSING')
          when c.driver_id='FIN_CASHFLOW' then coalesce(f.financial_feature_states->>'cashflow',f.financial_state,'MISSING')
          when nullif(f.raw_values->>c.driver_id,'') is not null and f.financial_state='AVAILABLE' then 'AVAILABLE'
          else coalesce(f.financial_state,'MISSING') end
        when f.history_count<r.minimum_history_sessions then 'INSUFFICIENT_HISTORY'
        when nullif(f.raw_values->>c.driver_id,'') is null then 'MISSING' else 'AVAILABLE' end driver_state
    from public.flow_driver_feature_panel_v1 f cross join unnest(v_components) c(driver_id)
    join public.flow_driver_registry_v1 r on r.registry_version=v_registry and r.driver_id=c.driver_id
    where f.panel_contract=v_panel
  ), oriented as (
    select *,case when driver_state='AVAILABLE' then raw_value*direction_hypothesis end transformed_value from comp_raw
  ), norm as (
    select *,case when driver_state='AVAILABLE' then percent_rank() over(partition by signal_date,driver_id,driver_state order by transformed_value) end normalized_value from oriented
  ), grouped as (
    select signal_date,ticker,(count(*)=v_component_count and bool_and(driver_state='AVAILABLE' and normalized_value>=0.80)) confluence_signal
    from norm group by signal_date,ticker
  ), base as (
    select g.*,s.market_regime,
      percent_rank() over(partition by g.signal_date order by nullif(f.raw_values->>'LIQ_TURNOVER','')::numeric) liquidity_rank,
      s.target_date_5d,s.target_date_20d,s.target_date_60d,
      s.alpha_vs_ihsg_5d_pct,s.alpha_vs_ihsg_20d_pct,s.alpha_vs_ihsg_60d_pct
    from grouped g
    join public.flow_driver_signal_panel_v1 s on s.panel_contract=v_panel and s.signal_date=g.signal_date and s.ticker=g.ticker
    join public.flow_driver_feature_panel_v1 f on f.panel_contract=v_panel and f.signal_date=g.signal_date and f.ticker=g.ticker
  ), expanded as (
    select b.*,h.* from base b cross join lateral(values
      (5,b.target_date_5d,b.alpha_vs_ihsg_5d_pct),(20,b.target_date_20d,b.alpha_vs_ihsg_20d_pct),(60,b.target_date_60d,b.alpha_vs_ihsg_60d_pct)
    ) h(horizon_days,target_date,alpha_ihsg)
  ), oos as (
    select e.*,wf.fold_no from expanded e
    join public.flow_driver_walkforward_folds_v1 wf on wf.validation_contract=v_parent and wf.horizon_days=e.horizon_days
    where e.signal_date between wf.validation_start and wf.forward_end and e.target_date is not null and e.alpha_ihsg is not null
  ), sliced as (
    select o.*,'MARKET_REGIME'::text slice_kind,concat('F',fold_no,':',market_regime) slice_value from oos o
    union all select o.*,'LIQUIDITY_QUINTILE',concat('F',fold_no,':',least(5,floor(liquidity_rank*5)::int+1)) from oos o where liquidity_rank is not null
  )
  select v_contract,p_interaction_id,horizon_days,slice_kind,slice_value,count(*)::int,
    count(*) filter(where confluence_signal)::int,avg(alpha_ihsg) filter(where confluence_signal),
    100.0*avg((alpha_ihsg>0)::int) filter(where confluence_signal),
    count(*) filter(where confluence_signal)>=v_min_sample,
    (avg(alpha_ihsg) filter(where confluence_signal)>0),v_at
  from sliced group by horizon_days,slice_kind,slice_value;

  return jsonb_build_object('status','PASS','interaction_id',p_interaction_id,'metric_cells',v_rows,
    'robustness_folds',2,'production_influence_enabled',false);
end;$fn$;

create or replace function public.flow_finalize_driver_gate13_v2()
returns jsonb language plpgsql security invoker set search_path='' as $fn$
declare
  v_contract constant text:='IDX_DRIVER_BOUNDED_CONFLUENCE_WF_V2';
  v_parent constant text:='IDX_DRIVER_PURGED_EXPANDING_WF_V2';
  v_panel constant text:='IDX_DRIVER_WEEKLY_PIT_PANEL_V2';
  v_registry constant text:='IDX_DRIVER_REGISTRY_GATE10_V2';
  v_at timestamptz:=clock_timestamp(); v_registered int; v_budget int; v_parent_state text;
  v_panel_leaks int; v_target_leaks int; v_posthoc int; v_budget_ok boolean;
begin
  select registered_interactions,max_interaction_budget into strict v_registered,v_budget
  from public.flow_driver_gate13_run_v1 where validation_contract=v_contract;
  select gate_state into strict v_parent_state from public.flow_driver_gate12_manifest_v1 where validation_contract=v_parent;
  select leakage_count::int into strict v_panel_leaks from public.flow_driver_panel_manifest_v1 where panel_contract=v_panel;
  delete from public.flow_driver_interaction_summary_v1 where validation_contract=v_contract;
  delete from public.flow_driver_gate13_manifest_v1 where validation_contract=v_contract;

  with all_oos as (
    select * from public.flow_driver_interaction_metrics_v1 where validation_contract=v_contract and segment<>'TRAIN'
  ), valid_oos as (
    select * from all_oos where valid_sample
  ), raw_stats as (
    select r.interaction_id,r.family,r.component_driver_ids,r.minimum_coverage_pct,
      avg(a.mean_alpha_vs_ihsg_pct) mean_alpha,
      avg(a.mean_alpha_vs_ihsg_pct) filter(where a.segment='HELDOUT') heldout_alpha,
      avg(a.mean_alpha_vs_ihsg_pct) filter(where a.segment='FORWARD') forward_alpha,
      avg(a.incremental_alpha_lift_pct) mean_lift,
      avg(a.incremental_alpha_lift_pct) filter(where a.segment='HELDOUT') heldout_lift,
      avg(a.incremental_alpha_lift_pct) filter(where a.segment='FORWARD') forward_lift,
      avg(a.coverage_pct) coverage_pct
    from public.flow_driver_interaction_registry_v1 r
    left join all_oos a on a.interaction_id=r.interaction_id
    where r.registry_version=v_registry
    group by r.interaction_id,r.family,r.component_driver_ids,r.minimum_coverage_pct
  ), valid_stats as (
    select r.interaction_id,count(v.interaction_id)::int valid_cells,
      count(v.interaction_id) filter(where v.incremental_alpha_lift_pct>0)::int positive_cells,
      100.0*count(v.interaction_id) filter(where v.incremental_alpha_lift_pct>0)/nullif(count(v.interaction_id),0) direction_pct
    from public.flow_driver_interaction_registry_v1 r
    left join valid_oos v on v.interaction_id=r.interaction_id
    where r.registry_version=v_registry group by r.interaction_id
  ), horizons as (
    select interaction_id,count(*) filter(where (horizon_days=5 and mean_lift>=0.25)
      or (horizon_days=20 and mean_lift>=0.50) or (horizon_days=60 and mean_lift>=1.00))::int positive_horizons
    from (select interaction_id,horizon_days,avg(incremental_alpha_lift_pct) mean_lift from valid_oos group by interaction_id,horizon_days) h
    group by interaction_id
  ), slices as (
    select interaction_id,
      100.0*count(*) filter(where slice_kind='MARKET_REGIME' and valid_sample and direction_agreement)
        /nullif(count(*) filter(where slice_kind='MARKET_REGIME' and valid_sample),0) regime_pct,
      100.0*count(*) filter(where slice_kind='LIQUIDITY_QUINTILE' and valid_sample and direction_agreement)
        /nullif(count(*) filter(where slice_kind='LIQUIDITY_QUINTILE' and valid_sample),0) liq_pct
    from public.flow_driver_interaction_slices_v1 where validation_contract=v_contract group by interaction_id
  ), combined as (
    select rs.*,vs.valid_cells,vs.positive_cells,vs.direction_pct,coalesce(h.positive_horizons,0) positive_horizons,
      sl.regime_pct,sl.liq_pct
    from raw_stats rs join valid_stats vs using(interaction_id)
    left join horizons h using(interaction_id) left join slices sl using(interaction_id)
  ), classified as (
    select c.*,
      case when c.valid_cells=0 then 'INSUFFICIENT_EVIDENCE'
        when c.direction_pct>=66.67 and (c.regime_pct is null or c.liq_pct is null) then 'INSUFFICIENT_EVIDENCE'
        when c.valid_cells>=12 and c.direction_pct>=66.67 and c.heldout_lift>0 and c.forward_lift>0
          and c.positive_horizons=3 and c.coverage_pct>=c.minimum_coverage_pct and c.regime_pct>=50 and c.liq_pct>=50 then 'VALIDATED_CONFLUENCE'
        when c.direction_pct>=66.67 and c.regime_pct<50 then 'REGIME_DEPENDENT'
        when c.direction_pct>=66.67 and c.liq_pct<50 then 'LIQUIDITY_SENSITIVE'
        when c.mean_lift>0 and c.direction_pct<66.67 then 'WEAK'
        when c.mean_lift<=0 and c.direction_pct<33.34 then 'REJECTED'
        else 'UNSTABLE' end classification
    from combined c
  )
  insert into public.flow_driver_interaction_summary_v1
  select v_contract,interaction_id,family,component_driver_ids,valid_cells,positive_cells,round(direction_pct,2),
    round(mean_alpha,4),round(heldout_alpha,4),round(forward_alpha,4),round(mean_lift,4),round(heldout_lift,4),round(forward_lift,4),
    positive_horizons,coalesce(round(coverage_pct,4),0),round(regime_pct,2),round(liq_pct,2),classification,
    case when 'FIN_BALANCE'=any(component_driver_ids) then 'FIN_BALANCE_DISCOVERY_OVERLAP_REQUIRES_UNTOUCHED_FORWARD_CONFIRMATION'
         else 'PREREGISTERED_PHASE1_INTERACTION_OOS_V2' end,
    (classification='VALIDATED_CONFLUENCE' and not ('FIN_BALANCE'=any(component_driver_ids))),
    case when classification='VALIDATED_CONFLUENCE' and 'FIN_BALANCE'=any(component_driver_ids)
           then 'Confluence criteria met but FIN_BALANCE discovery overlap is executable hard block; independent untouched forward confirmation required'
         when classification='VALIDATED_CONFLUENCE' then 'Frozen V2 incremental-lift criteria met; candidate may enter Phase 2 research only'
         when classification='INSUFFICIENT_EVIDENCE' and mean_alpha is not null then 'Raw OOS metrics exist, but frozen V2 coverage/sample/robustness validity is not met'
         when classification='INSUFFICIENT_EVIDENCE' then 'Required PIT component history unavailable or sample below frozen minimum'
         else 'Frozen Gate13 V2 acceptance rule not met' end,
    v_at,false
  from classified;

  with registry_ids as (
    select interaction_id from public.flow_driver_interaction_registry_v1 where registry_version=v_registry
  ), extras as (
    select distinct interaction_id from public.flow_driver_interaction_metrics_v1 where validation_contract=v_contract
    union select distinct interaction_id from public.flow_driver_interaction_summary_v1 where validation_contract=v_contract
  )
  select count(*) into v_posthoc from extras e left join registry_ids r using(interaction_id) where r.interaction_id is null;

  with h as (
    select 5 horizon_days,signal_date,target_date_5d target_date,alpha_vs_ihsg_5d_pct alpha from public.flow_driver_signal_panel_v1 where panel_contract=v_panel
    union all select 20,signal_date,target_date_20d,alpha_vs_ihsg_20d_pct from public.flow_driver_signal_panel_v1 where panel_contract=v_panel
    union all select 60,signal_date,target_date_60d,alpha_vs_ihsg_60d_pct from public.flow_driver_signal_panel_v1 where panel_contract=v_panel
  ), expected as (
    select wf.horizon_days,wf.fold_no,count(*)::int expected_rows
    from public.flow_driver_walkforward_folds_v1 wf join h on h.horizon_days=wf.horizon_days
    where wf.validation_contract=v_parent and h.signal_date between wf.train_start and wf.train_end
      and h.target_date is not null and h.alpha is not null and h.target_date<=wf.train_end
    group by wf.horizon_days,wf.fold_no
  ), observed as (
    select interaction_id,horizon_days,fold_no,universe_count
    from public.flow_driver_interaction_metrics_v1 where validation_contract=v_contract and segment='TRAIN'
  )
  select count(*)::int into v_target_leaks
  from observed o join expected e using(horizon_days,fold_no) where o.universe_count<>e.expected_rows;

  v_budget_ok := (v_registered<=v_budget)
    and (select count(*) from public.flow_driver_interaction_registry_v1 where registry_version=v_registry)<=v_budget;

  insert into public.flow_driver_gate13_manifest_v1
  select v_contract,v_registry,v_parent,v_registered,
    (select count(*) from public.flow_driver_interaction_summary_v1 where validation_contract=v_contract),
    (select count(distinct interaction_id) from public.flow_driver_interaction_metrics_v1 where validation_contract=v_contract),
    (select count(*) from public.flow_driver_interaction_metrics_v1 where validation_contract=v_contract),
    (select count(*) from public.flow_driver_interaction_summary_v1 where validation_contract=v_contract and classification='VALIDATED_CONFLUENCE'),
    (select count(*) from public.flow_driver_interaction_summary_v1 where validation_contract=v_contract and classification='REJECTED'),
    (select count(*) from public.flow_driver_interaction_summary_v1 where validation_contract=v_contract and classification='INSUFFICIENT_EVIDENCE'),
    v_panel_leaks,v_target_leaks,v_posthoc,v_budget_ok,
    case when v_parent_state='PASS' and v_panel_leaks=0 and v_target_leaks=0 and v_posthoc=0 and v_budget_ok
      and (select count(*) from public.flow_driver_interaction_summary_v1 where validation_contract=v_contract)=v_registered
      then 'PASS' else 'FAIL' end,v_at,false;

  return jsonb_build_object('status',(select gate_state from public.flow_driver_gate13_manifest_v1 where validation_contract=v_contract),
    'registered_interactions',v_registered,
    'metric_interactions',(select metric_interactions from public.flow_driver_gate13_manifest_v1 where validation_contract=v_contract),
    'metric_cells',(select metric_cells from public.flow_driver_gate13_manifest_v1 where validation_contract=v_contract),
    'validated_interactions',(select validated_interactions from public.flow_driver_gate13_manifest_v1 where validation_contract=v_contract),
    'phase2_eligible_interactions',(select count(*) from public.flow_driver_interaction_summary_v1 where validation_contract=v_contract and eligible_to_enter_phase2),
    'target_leakage_count',v_target_leaks,'posthoc_mining_count',v_posthoc,'production_influence_enabled',false);
end;$fn$;

revoke all on function public.flow_initialize_driver_gate13_v2() from public,anon,authenticated;
revoke all on function public.flow_run_interaction_oos_v2(text) from public,anon,authenticated;
revoke all on function public.flow_finalize_driver_gate13_v2() from public,anon,authenticated;
grant execute on function public.flow_initialize_driver_gate13_v2() to service_role;
grant execute on function public.flow_run_interaction_oos_v2(text) to service_role;
grant execute on function public.flow_finalize_driver_gate13_v2() to service_role;
