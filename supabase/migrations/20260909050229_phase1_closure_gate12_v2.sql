create or replace function public.flow_initialize_driver_gate12_v2()
returns jsonb language plpgsql security invoker set search_path='' as $fn$
declare v_contract constant text:='IDX_DRIVER_PURGED_EXPANDING_WF_V2'; v_registry constant text:='IDX_DRIVER_REGISTRY_GATE10_V2'; v_panel constant text:='IDX_DRIVER_WEEKLY_PIT_PANEL_V2'; v_frozen timestamptz; v_started timestamptz:=clock_timestamp(); v_rows integer;
begin
 if exists(select 1 from public.flow_driver_gate12_run_v1 where validation_contract=v_contract) then raise exception 'Gate12 V2 already initialized and frozen'; end if;
 select frozen_at into strict v_frozen from public.flow_driver_research_policy_v1 where registry_version=v_registry;
 if not exists(select 1 from public.flow_driver_panel_manifest_v1 where panel_contract=v_panel and build_state='COMPLETE' and leakage_count=0 and revision_leakage_count=0 and target_leakage_count=0) then raise exception 'Gate11 V2 panel is not closure-ready'; end if;
 insert into public.flow_driver_walkforward_folds_v1(validation_contract,horizon_days,fold_no,train_start,train_end,validation_start,validation_end,heldout_start,heldout_end,forward_start,forward_end,purge_rule,created_at)
 select v_contract,horizon_days,fold_no,train_start,train_end,validation_start,validation_end,heldout_start,heldout_end,forward_start,forward_end,purge_rule,v_started from public.flow_driver_walkforward_folds_v1 where validation_contract='IDX_DRIVER_PURGED_EXPANDING_WF_V1' order by horizon_days,fold_no;
 get diagnostics v_rows=row_count; if v_rows<>6 then raise exception 'Expected 6 frozen folds, got %',v_rows; end if;
 insert into public.flow_driver_gate12_run_v1(validation_contract,registry_version,panel_contract,evaluation_started_at,registry_frozen_at,candidate_registry_frozen_before_evaluation,result_read_before_freeze,production_influence_enabled)
 values(v_contract,v_registry,v_panel,v_started,v_frozen,v_frozen<v_started,false,false);
 return jsonb_build_object('status','PASS','fold_rows',v_rows,'registry_frozen_before_evaluation',v_frozen<v_started,'production_influence_enabled',false);
end;$fn$;

create or replace function public.flow_run_single_driver_oos_v2(p_driver_id text)
returns jsonb language plpgsql security invoker set search_path='' set work_mem='128MB' as $fn$
declare
  v_contract constant text:='IDX_DRIVER_PURGED_EXPANDING_WF_V2'; v_panel constant text:='IDX_DRIVER_WEEKLY_PIT_PANEL_V2'; v_registry constant text:='IDX_DRIVER_REGISTRY_GATE10_V2';
  v_family text; v_direction smallint; v_threshold text; v_min_history integer; v_at timestamptz; v_rows integer;
begin
  select family,direction_hypothesis,threshold_definition,minimum_history_sessions into strict v_family,v_direction,v_threshold,v_min_history
  from public.flow_driver_registry_v1 where registry_version=v_registry and driver_id=p_driver_id and evaluation_eligible;
  select evaluation_started_at into strict v_at from public.flow_driver_gate12_run_v1 where validation_contract=v_contract;
  delete from public.flow_driver_oos_metrics_v1 where validation_contract=v_contract and driver_id=p_driver_id;
  delete from public.flow_driver_oos_slices_v1 where validation_contract=v_contract and driver_id=p_driver_id;

  insert into public.flow_driver_oos_metrics_v1
  with raw as (
    select f.signal_date,f.ticker,
      case when p_driver_id='FLOW_FOREIGN_DISTRIBUTION' then -(f.raw_values->>'FLOW_FOREIGN_ACCUMULATION')::numeric else nullif(f.raw_values->>p_driver_id,'')::numeric end raw_value,
      case when v_family='FINANCIAL' then case when f.financial_available_from_date>f.signal_date then 'INVALID'
        when p_driver_id='FIN_GROWTH' then coalesce(f.financial_feature_states->>'growth',f.financial_state,'MISSING')
        when p_driver_id='FIN_CASHFLOW' then coalesce(f.financial_feature_states->>'cashflow',f.financial_state,'MISSING')
        when nullif(f.raw_values->>p_driver_id,'') is not null and f.financial_state='AVAILABLE' then 'AVAILABLE' else coalesce(f.financial_state,'MISSING') end
        when f.history_count<v_min_history then 'INSUFFICIENT_HISTORY' when nullif(f.raw_values->>p_driver_id,'') is null then 'MISSING' else 'AVAILABLE' end driver_state,
      s.target_date_5d,s.target_date_20d,s.target_date_60d,s.forward_return_5d_pct,s.forward_return_20d_pct,s.forward_return_60d_pct,
      s.alpha_vs_ihsg_5d_pct,s.alpha_vs_ihsg_20d_pct,s.alpha_vs_ihsg_60d_pct,s.mfe_5d_pct,s.mfe_20d_pct,s.mfe_60d_pct,s.mae_5d_pct,s.mae_20d_pct,s.mae_60d_pct
    from public.flow_driver_feature_panel_v1 f join public.flow_driver_signal_panel_v1 s using(panel_contract,signal_date,ticker) where f.panel_contract=v_panel
  ), oriented as (select *,case when driver_state='AVAILABLE' then raw_value*v_direction end transformed_value from raw),
  ranked as (select *,case when driver_state='AVAILABLE' then percent_rank() over(partition by signal_date,driver_state order by transformed_value) end normalized_value from oriented),
  flagged as (
    select *,
      case when driver_state<>'AVAILABLE' then false
        when v_threshold='RAW_BOTTOM_20_TOP_80' then raw_value<=20 when v_threshold='RAW_BOTTOM_0_35_TOP_0_65' then raw_value<=.35
        when v_threshold='RAW_BOTTOM_0_80_TOP_1_50' then raw_value<=.80 when v_threshold='RAW_BOTTOM_0_75_TOP_1_50' then raw_value<=.75
        when v_threshold='RAW_BOTTOM_LE_-3_TOP_GE_3_PCT' then raw_value<=-3 when v_threshold='RAW_TOP_GE_-0_25_PCT_BOTTOM_LE_-8_PCT' then raw_value<=-8
        when v_threshold='BINARY_TRUE_VS_FALSE' then (case when v_direction=1 then raw_value=0 else raw_value=1 end) else normalized_value<=.20 end bottom_signal,
      case when driver_state<>'AVAILABLE' then false
        when v_threshold='RAW_BOTTOM_20_TOP_80' then raw_value>=80 when v_threshold='RAW_BOTTOM_0_35_TOP_0_65' then raw_value>=.65
        when v_threshold='RAW_BOTTOM_0_80_TOP_1_50' then raw_value>=1.50 when v_threshold='RAW_BOTTOM_0_75_TOP_1_50' then raw_value>=1.50
        when v_threshold='RAW_BOTTOM_LE_-3_TOP_GE_3_PCT' then raw_value>=3 when v_threshold='RAW_TOP_GE_-0_25_PCT_BOTTOM_LE_-8_PCT' then raw_value>=-.25
        when v_threshold='BINARY_TRUE_VS_FALSE' then (case when v_direction=1 then raw_value=1 else raw_value=0 end) else normalized_value>=.80 end top_signal
    from ranked
  ), expanded as (
    select q.*,h.* from flagged q cross join lateral(values
      (5,q.target_date_5d,q.forward_return_5d_pct,q.alpha_vs_ihsg_5d_pct,q.mfe_5d_pct,q.mae_5d_pct),
      (20,q.target_date_20d,q.forward_return_20d_pct,q.alpha_vs_ihsg_20d_pct,q.mfe_20d_pct,q.mae_20d_pct),
      (60,q.target_date_60d,q.forward_return_60d_pct,q.alpha_vs_ihsg_60d_pct,q.mfe_60d_pct,q.mae_60d_pct)
    ) h(horizon_days,target_date,forward_return,alpha_ihsg,mfe,mae)
  ), segmented as (
    select e.*,f.fold_no,x.segment from expanded e join public.flow_driver_walkforward_folds_v1 f on f.validation_contract=v_contract and f.horizon_days=e.horizon_days
    cross join lateral(values('TRAIN'::text,f.train_start,f.train_end),('VALIDATION',f.validation_start,f.validation_end),('HELDOUT',f.heldout_start,f.heldout_end),('FORWARD',f.forward_start,f.forward_end)) x(segment,start_date,end_date)
    where e.signal_date between x.start_date and x.end_date and e.target_date is not null and e.alpha_ihsg is not null and (x.segment<>'TRAIN' or e.target_date<=f.train_end)
  )
  select v_contract,p_driver_id,v_family,horizon_days,fold_no,segment,count(*)::int,count(*) filter(where driver_state='AVAILABLE')::int,
    round(100.0*count(*) filter(where driver_state='AVAILABLE')/nullif(count(*),0),4),avg(forward_return) filter(where driver_state='AVAILABLE'),
    percentile_cont(.5) within group(order by forward_return) filter(where driver_state='AVAILABLE'),avg(alpha_ihsg) filter(where driver_state='AVAILABLE'),null::numeric,
    100.0*avg((alpha_ihsg>0)::int) filter(where driver_state='AVAILABLE'),count(*) filter(where top_signal)::int,count(*) filter(where bottom_signal)::int,
    avg(forward_return) filter(where top_signal),avg(forward_return) filter(where bottom_signal),avg(forward_return) filter(where top_signal)-avg(forward_return) filter(where bottom_signal),
    avg(alpha_ihsg) filter(where top_signal),avg(alpha_ihsg) filter(where bottom_signal),avg(alpha_ihsg) filter(where top_signal)-avg(alpha_ihsg) filter(where bottom_signal),
    null::numeric,null::numeric,null::numeric,corr(normalized_value::double precision,alpha_ihsg::double precision) filter(where driver_state='AVAILABLE'),
    avg(mfe) filter(where driver_state='AVAILABLE'),avg(mae) filter(where driver_state='AVAILABLE'),avg(alpha_ihsg) filter(where driver_state<>'AVAILABLE'),
    (avg(alpha_ihsg) filter(where top_signal)-avg(alpha_ihsg) filter(where bottom_signal))>0,
    count(*) filter(where top_signal)>=50 and count(*) filter(where bottom_signal)>=50,v_at,false
  from segmented group by horizon_days,fold_no,segment;
  get diagnostics v_rows=row_count;

  insert into public.flow_driver_oos_slices_v1
  with raw as (
    select f.signal_date,f.ticker,s.market_regime,
      percent_rank() over(partition by f.signal_date order by nullif(f.raw_values->>'LIQ_TURNOVER','')::numeric) liquidity_rank,
      case when p_driver_id='FLOW_FOREIGN_DISTRIBUTION' then -(f.raw_values->>'FLOW_FOREIGN_ACCUMULATION')::numeric else nullif(f.raw_values->>p_driver_id,'')::numeric end raw_value,
      case when v_family='FINANCIAL' then case when f.financial_available_from_date>f.signal_date then 'INVALID'
        when p_driver_id='FIN_GROWTH' then coalesce(f.financial_feature_states->>'growth',f.financial_state,'MISSING')
        when p_driver_id='FIN_CASHFLOW' then coalesce(f.financial_feature_states->>'cashflow',f.financial_state,'MISSING')
        when nullif(f.raw_values->>p_driver_id,'') is not null and f.financial_state='AVAILABLE' then 'AVAILABLE' else coalesce(f.financial_state,'MISSING') end
        when f.history_count<v_min_history then 'INSUFFICIENT_HISTORY' when nullif(f.raw_values->>p_driver_id,'') is null then 'MISSING' else 'AVAILABLE' end driver_state,
      s.target_date_5d,s.target_date_20d,s.target_date_60d,s.alpha_vs_ihsg_5d_pct,s.alpha_vs_ihsg_20d_pct,s.alpha_vs_ihsg_60d_pct
    from public.flow_driver_feature_panel_v1 f join public.flow_driver_signal_panel_v1 s using(panel_contract,signal_date,ticker) where f.panel_contract=v_panel
  ), oriented as (select *,case when driver_state='AVAILABLE' then raw_value*v_direction end transformed_value from raw),
  ranked as (select *,case when driver_state='AVAILABLE' then percent_rank() over(partition by signal_date,driver_state order by transformed_value) end normalized_value from oriented),
  flagged as (
    select *,
      case when driver_state<>'AVAILABLE' then false when v_threshold='RAW_BOTTOM_20_TOP_80' then raw_value<=20 when v_threshold='RAW_BOTTOM_0_35_TOP_0_65' then raw_value<=.35
        when v_threshold='RAW_BOTTOM_0_80_TOP_1_50' then raw_value<=.80 when v_threshold='RAW_BOTTOM_0_75_TOP_1_50' then raw_value<=.75
        when v_threshold='RAW_BOTTOM_LE_-3_TOP_GE_3_PCT' then raw_value<=-3 when v_threshold='RAW_TOP_GE_-0_25_PCT_BOTTOM_LE_-8_PCT' then raw_value<=-8
        when v_threshold='BINARY_TRUE_VS_FALSE' then (case when v_direction=1 then raw_value=0 else raw_value=1 end) else normalized_value<=.20 end bottom_signal,
      case when driver_state<>'AVAILABLE' then false when v_threshold='RAW_BOTTOM_20_TOP_80' then raw_value>=80 when v_threshold='RAW_BOTTOM_0_35_TOP_0_65' then raw_value>=.65
        when v_threshold='RAW_BOTTOM_0_80_TOP_1_50' then raw_value>=1.50 when v_threshold='RAW_BOTTOM_0_75_TOP_1_50' then raw_value>=1.50
        when v_threshold='RAW_BOTTOM_LE_-3_TOP_GE_3_PCT' then raw_value>=3 when v_threshold='RAW_TOP_GE_-0_25_PCT_BOTTOM_LE_-8_PCT' then raw_value>=-.25
        when v_threshold='BINARY_TRUE_VS_FALSE' then (case when v_direction=1 then raw_value=1 else raw_value=0 end) else normalized_value>=.80 end top_signal
    from ranked
  ), expanded as (
    select q.*,h.* from flagged q cross join lateral(values(5,q.target_date_5d,q.alpha_vs_ihsg_5d_pct),(20,q.target_date_20d,q.alpha_vs_ihsg_20d_pct),(60,q.target_date_60d,q.alpha_vs_ihsg_60d_pct)) h(horizon_days,target_date,alpha_ihsg)
  ), oos as (
    select e.*,f.fold_no from expanded e join public.flow_driver_walkforward_folds_v1 f on f.validation_contract=v_contract and f.horizon_days=e.horizon_days
    where e.signal_date between f.validation_start and f.forward_end and e.target_date is not null and e.alpha_ihsg is not null
  ), sliced as (
    select o.*,'MARKET_REGIME'::text slice_kind,concat('F',fold_no,':',market_regime) slice_value from oos o
    union all select o.*,'LIQUIDITY_QUINTILE',concat('F',fold_no,':',least(5,floor(liquidity_rank*5)::int+1)) from oos o where liquidity_rank is not null
  )
  select v_contract,p_driver_id,horizon_days,slice_kind,slice_value,count(*) filter(where driver_state='AVAILABLE')::int,
    count(*) filter(where top_signal)::int,count(*) filter(where bottom_signal)::int,
    avg(alpha_ihsg) filter(where top_signal)-avg(alpha_ihsg) filter(where bottom_signal),
    (avg(alpha_ihsg) filter(where top_signal)-avg(alpha_ihsg) filter(where bottom_signal))>0,
    count(*) filter(where top_signal)>=50 and count(*) filter(where bottom_signal)>=50,v_at
  from sliced group by horizon_days,slice_kind,slice_value;
  return jsonb_build_object('status','PASS','driver_id',p_driver_id,'metric_cells',v_rows,'materialization','STREAMED_CTE_NO_TEMP_TABLE','production_influence_enabled',false);
end;$fn$;

create or replace function public.flow_finalize_driver_gate12_v2()
returns jsonb language plpgsql security invoker set search_path='' as $fn$
declare
  v_contract constant text := 'IDX_DRIVER_PURGED_EXPANDING_WF_V2'; v_panel constant text := 'IDX_DRIVER_WEEKLY_PIT_PANEL_V2'; v_registry constant text := 'IDX_DRIVER_REGISTRY_GATE10_V2'; v_at timestamptz := clock_timestamp();
  v_panel_leaks bigint; v_panel_target bigint; v_panel_revision bigint; v_invalid integer; v_evaluated integer; v_training_leaks integer; v_training_mismatch integer; v_frozen_ok boolean;
begin
  delete from public.flow_driver_gate12_manifest_v1 where validation_contract=v_contract;
  delete from public.flow_driver_oos_summary_v1 where validation_contract=v_contract;
  with oos as (select * from public.flow_driver_oos_metrics_v1 where validation_contract=v_contract and segment<>'TRAIN' and valid_sample),
  stats as (
    select r.driver_id,r.family,c.coverage_pct,count(o.*) valid_cells,count(o.*) filter(where o.top_bottom_alpha_spread_pct>0) positive_cells,
      100.0*count(o.*) filter(where o.top_bottom_alpha_spread_pct>0)/nullif(count(o.*),0) direction_pct,
      avg(o.top_bottom_alpha_spread_pct) mean_spread,avg(o.top_bottom_alpha_spread_pct) filter(where o.segment='HELDOUT') heldout_spread,
      avg(o.top_bottom_alpha_spread_pct) filter(where o.segment='FORWARD') forward_spread,avg(o.rank_ic) mean_ic
    from public.flow_driver_registry_v1 r left join public.flow_driver_coverage_v1 c on c.panel_contract=v_panel and c.entity_type='DRIVER' and c.entity_id=r.driver_id
    left join oos o on o.driver_id=r.driver_id where r.registry_version=v_registry and r.evaluation_eligible group by r.driver_id,r.family,c.coverage_pct
  ), horizons as (
    select driver_id,count(*) filter(where mean_h>0) positive_horizons from (select driver_id,horizon_days,avg(top_bottom_alpha_spread_pct) mean_h from oos group by driver_id,horizon_days) h group by driver_id
  ), slices as (
    select driver_id,
      100.0*count(*) filter(where slice_kind='MARKET_REGIME' and valid_sample and direction_agreement)/nullif(count(*) filter(where slice_kind='MARKET_REGIME' and valid_sample),0) regime_pct,
      100.0*count(*) filter(where slice_kind='LIQUIDITY_QUINTILE' and valid_sample and direction_agreement)/nullif(count(*) filter(where slice_kind='LIQUIDITY_QUINTILE' and valid_sample),0) liq_pct
    from public.flow_driver_oos_slices_v1 where validation_contract=v_contract group by driver_id
  ), classified as (
    select s.*,coalesce(h.positive_horizons,0) positive_horizons,sl.regime_pct,sl.liq_pct,
      case when s.valid_cells=0 then 'INSUFFICIENT_EVIDENCE'
        when s.direction_pct>=66.67 and (sl.regime_pct is null or sl.liq_pct is null) then 'INSUFFICIENT_EVIDENCE'
        when s.direction_pct>=66.67 and sl.regime_pct<50 then 'REGIME_DEPENDENT'
        when s.direction_pct>=66.67 and sl.liq_pct<50 then 'LIQUIDITY_SENSITIVE'
        when s.valid_cells>=15 and s.direction_pct>=66.67 and s.heldout_spread>0 and s.forward_spread>0 and coalesce(h.positive_horizons,0)=3 and s.coverage_pct>=60 and sl.regime_pct>=50 and sl.liq_pct>=50 then 'PROMISING'
        when s.mean_spread<=0 and s.direction_pct<33.34 then 'REJECTED'
        when s.mean_spread>0 and s.direction_pct<66.67 then 'WEAK' else 'UNSTABLE' end classification
    from stats s left join horizons h using(driver_id) left join slices sl using(driver_id)
  )
  insert into public.flow_driver_oos_summary_v1
  select v_contract,driver_id,family,valid_cells,positive_cells,round(direction_pct,2),round(mean_spread,4),round(heldout_spread,4),round(forward_spread,4),round(mean_ic,4),positive_horizons,coalesce(coverage_pct,0),
    round(regime_pct,2),round(liq_pct,2),'INSUFFICIENT_PIT_SECTOR_HISTORY',classification,
    case when driver_id='FIN_BALANCE' then 'DISCOVERY_REPLAY_NOT_INDEPENDENT_CONFIRMATION' else 'PREREGISTERED_PHASE1_OOS_V2' end,
    (classification='PROMISING' and driver_id<>'FIN_BALANCE'),
    case when driver_id='FIN_BALANCE' then 'Gate 9 overlap prevents independent confirmation; untouched forward confirmation required in Phase 2'
      when classification='PROMISING' then 'V2 preregistered OOS criteria met; eligible only to enter Phase 2 research'
      when classification='INSUFFICIENT_EVIDENCE' and (regime_pct is null or liq_pct is null) then 'Robustness evidence missing; V2 fails closed'
      else 'No Phase 2 entry under frozen V2 acceptance criteria' end,v_at,false from classified;

  select leakage_count,target_leakage_count,revision_leakage_count into strict v_panel_leaks,v_panel_target,v_panel_revision from public.flow_driver_panel_manifest_v1 where panel_contract=v_panel;
  select count(*) into v_invalid from public.flow_driver_oos_metrics_v1 where validation_contract=v_contract and valid_sample and top_bottom_alpha_spread_pct is null;
  select count(distinct driver_id) into v_evaluated from public.flow_driver_oos_metrics_v1 where validation_contract=v_contract;
  with h as (
    select 5 horizon_days,signal_date,target_date_5d target_date,alpha_vs_ihsg_5d_pct alpha from public.flow_driver_signal_panel_v1 where panel_contract=v_panel
    union all select 20,signal_date,target_date_20d,alpha_vs_ihsg_20d_pct from public.flow_driver_signal_panel_v1 where panel_contract=v_panel
    union all select 60,signal_date,target_date_60d,alpha_vs_ihsg_60d_pct from public.flow_driver_signal_panel_v1 where panel_contract=v_panel
  ), expected as (
    select f.horizon_days,f.fold_no,count(*)::int expected_rows from public.flow_driver_walkforward_folds_v1 f join h on h.horizon_days=f.horizon_days
    where f.validation_contract=v_contract and h.signal_date between f.train_start and f.train_end and h.target_date is not null and h.alpha is not null and h.target_date<=f.train_end group by f.horizon_days,f.fold_no
  ), observed as (
    select horizon_days,fold_no,min(universe_count) min_u,max(universe_count) max_u,count(distinct universe_count) distinct_u from public.flow_driver_oos_metrics_v1 where validation_contract=v_contract and segment='TRAIN' group by horizon_days,fold_no
  )
  select coalesce(sum(greatest(o.max_u-e.expected_rows,0)),0)::int,
         count(*) filter(where o.distinct_u<>1 or o.min_u<>e.expected_rows or o.max_u<>e.expected_rows)::int
    into v_training_leaks,v_training_mismatch from expected e join observed o using(horizon_days,fold_no);
  select candidate_registry_frozen_before_evaluation into strict v_frozen_ok from public.flow_driver_gate12_run_v1 where validation_contract=v_contract;

  insert into public.flow_driver_gate12_manifest_v1
  select v_contract,v_registry,v_panel,
    (select count(*) from public.flow_driver_registry_v1 where registry_version=v_registry),
    (select count(*) from public.flow_driver_registry_v1 where registry_version=v_registry and evaluation_eligible),v_evaluated,
    (select count(*) from public.flow_driver_walkforward_folds_v1 where validation_contract=v_contract),
    (select count(*) from public.flow_driver_oos_metrics_v1 where validation_contract=v_contract),v_invalid,
    (select count(*) from public.flow_driver_oos_summary_v1 where validation_contract=v_contract and classification='PROMISING'),
    (select count(*) from public.flow_driver_oos_summary_v1 where validation_contract=v_contract and eligible_to_enter_phase2),
    v_training_leaks,v_panel_leaks,v_frozen_ok,
    case when v_panel_leaks=0 and v_panel_target=0 and v_panel_revision=0 and v_invalid=0
      and v_evaluated=(select count(*) from public.flow_driver_registry_v1 where registry_version=v_registry and evaluation_eligible)
      and v_training_leaks=0 and v_training_mismatch=0 and v_frozen_ok then 'PASS' else 'FAIL' end,v_at,false;
  return jsonb_build_object('status',(select gate_state from public.flow_driver_gate12_manifest_v1 where validation_contract=v_contract),
    'evaluated_drivers',v_evaluated,'invalid_metric_cells',v_invalid,'training_target_overlap_leaks',v_training_leaks,
    'training_universe_mismatch_cells',v_training_mismatch,
    'phase2_eligible_drivers',(select phase2_eligible_drivers from public.flow_driver_gate12_manifest_v1 where validation_contract=v_contract),
    'production_influence_enabled',false);
end;$fn$;

revoke all on function public.flow_initialize_driver_gate12_v2() from public,anon,authenticated;
revoke all on function public.flow_run_single_driver_oos_v2(text) from public,anon,authenticated;
revoke all on function public.flow_finalize_driver_gate12_v2() from public,anon,authenticated;
grant execute on function public.flow_initialize_driver_gate12_v2() to service_role;
grant execute on function public.flow_run_single_driver_oos_v2(text) to service_role;
grant execute on function public.flow_finalize_driver_gate12_v2() to service_role;
