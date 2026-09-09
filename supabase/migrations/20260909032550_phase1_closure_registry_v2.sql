do $do$
declare
  v_frozen timestamptz := clock_timestamp();
  v_hash text;
begin
  delete from public.flow_driver_dependency_matrix_v1 where registry_version='IDX_DRIVER_REGISTRY_GATE10_V2';
  delete from public.flow_driver_interaction_registry_v1 where registry_version='IDX_DRIVER_REGISTRY_GATE10_V2';
  delete from public.flow_driver_registry_v1 where registry_version='IDX_DRIVER_REGISTRY_GATE10_V2';
  delete from public.flow_driver_research_policy_v1 where registry_version='IDX_DRIVER_REGISTRY_GATE10_V2';

  insert into public.flow_driver_registry_v1(
    registry_version,driver_id,family,description,raw_source,source_table,source_fields,
    mathematical_definition,direction_hypothesis,threshold_definition,update_frequency,
    source_timestamp,effective_availability_rule,pit_safe,revision_safe,historical_availability,
    minimum_history_sessions,sector_applicability,liquidity_applicability,missing_data_semantics,
    stale_definition,invalid_definition,not_applicable_rule,horizon_candidates,expected_relationship,
    promotion_eligibility,interaction_eligibility,evaluation_eligible,frozen_at,production_influence_enabled
  )
  select
    'IDX_DRIVER_REGISTRY_GATE10_V2',driver_id,family,description,raw_source,source_table,source_fields,
    mathematical_definition,direction_hypothesis,threshold_definition,update_frequency,
    source_timestamp,effective_availability_rule,pit_safe,revision_safe,historical_availability,
    minimum_history_sessions,sector_applicability,liquidity_applicability,missing_data_semantics,
    stale_definition,invalid_definition,not_applicable_rule,horizon_candidates,expected_relationship,
    promotion_eligibility,interaction_eligibility,evaluation_eligible,v_frozen,false
  from public.flow_driver_registry_v1
  where registry_version='IDX_DRIVER_REGISTRY_GATE10_V1';

  update public.flow_driver_registry_v1
  set description='Bounded confluence of trailing PIT IHSG 20D-return percentile and same-date market breadth.',
      mathematical_definition='mean(trailing_252_session_percentile_rank(ihsg_return_20d),market_breadth_20d)',
      source_fields='["COMPOSITE.close","flow_market_learning_panel_v4.close"]'::jsonb,
      expected_relationship='Risk-on context supports positive forward alpha; market-level percentile is trailing-time-series PIT, never same-date cross-sectional.'
  where registry_version='IDX_DRIVER_REGISTRY_GATE10_V2' and driver_id='MKT_RISK_ON_CONTEXT';

  update public.flow_driver_registry_v1
  set source_table='flow_official_stock_summary+flow_market_learning_panel_v4',
      source_fields='["flow_official_stock_summary.close","flow_official_stock_summary.high","flow_official_stock_summary.trade_date","flow_market_learning_panel_v4.return_20d_pct"]'::jsonb,
      description='Five-session break following negative 20-session trend; return_20d dependency is explicit.'
  where registry_version='IDX_DRIVER_REGISTRY_GATE10_V2' and driver_id='TECH_CHOCH';

  insert into public.flow_driver_dependency_matrix_v1(
    registry_version,driver_id,dependency_no,source_relation,source_fields,equivalent_existing_object,
    reuse_decision,pit_risk,dependency_state
  )
  select 'IDX_DRIVER_REGISTRY_GATE10_V2',driver_id,dependency_no,source_relation,source_fields,
    equivalent_existing_object,reuse_decision,pit_risk,dependency_state
  from public.flow_driver_dependency_matrix_v1
  where registry_version='IDX_DRIVER_REGISTRY_GATE10_V1';

  update public.flow_driver_dependency_matrix_v1
  set source_relation='flow_official_stock_summary+flow_market_learning_panel_v4',
      source_fields='["flow_official_stock_summary.close","flow_official_stock_summary.high","flow_official_stock_summary.trade_date","flow_market_learning_panel_v4.return_20d_pct"]'::jsonb,
      equivalent_existing_object='flow_official_stock_summary+flow_market_learning_panel_v4'
  where registry_version='IDX_DRIVER_REGISTRY_GATE10_V2' and driver_id='TECH_CHOCH' and dependency_no=1;

  update public.flow_driver_dependency_matrix_v1
  set source_fields='["flow_official_index_summary.COMPOSITE.close","flow_market_learning_panel_v4.close"]'::jsonb,
      pit_risk='TRAILING_252_SESSION_MARKET_RANK_NO_FUTURE_DATES'
  where registry_version='IDX_DRIVER_REGISTRY_GATE10_V2' and driver_id='MKT_RISK_ON_CONTEXT' and dependency_no=1;

  insert into public.flow_driver_interaction_registry_v1(
    registry_version,interaction_id,family,component_driver_ids,economic_rationale,deterministic_formula,
    direction_hypothesis,threshold_definition,minimum_coverage_pct,minimum_sample_size,sector_applicability,
    horizon_candidates,preregistered_acceptance_rule,frozen_at,production_influence_enabled
  )
  select 'IDX_DRIVER_REGISTRY_GATE10_V2',interaction_id,family,component_driver_ids,economic_rationale,
    deterministic_formula,direction_hypothesis,threshold_definition,minimum_coverage_pct,minimum_sample_size,
    sector_applicability,horizon_candidates,preregistered_acceptance_rule,v_frozen,false
  from public.flow_driver_interaction_registry_v1
  where registry_version='IDX_DRIVER_REGISTRY_GATE10_V1';

  select encode(extensions.digest(convert_to((jsonb_build_object(
    'drivers',(select jsonb_agg(to_jsonb(r) - 'frozen_at' - 'production_influence_enabled' order by r.driver_id)
               from public.flow_driver_registry_v1 r where r.registry_version='IDX_DRIVER_REGISTRY_GATE10_V2'),
    'interactions',(select jsonb_agg(to_jsonb(i) - 'frozen_at' - 'production_influence_enabled' order by i.interaction_id)
                    from public.flow_driver_interaction_registry_v1 i where i.registry_version='IDX_DRIVER_REGISTRY_GATE10_V2'),
    'dependencies',(select jsonb_agg(to_jsonb(d) order by d.driver_id,d.dependency_no)
                    from public.flow_driver_dependency_matrix_v1 d where d.registry_version='IDX_DRIVER_REGISTRY_GATE10_V2')
  ))::text,'UTF8'),'sha256'),'hex') into v_hash;

  insert into public.flow_driver_research_policy_v1(
    registry_version,panel_contract,walkforward_contract,benchmark_contract,normalization_contract,purge_rule,
    horizons,fold_count_per_horizon,acceptance_criteria,max_interaction_budget,driver_count,interaction_count,
    registry_sha256,frozen_at,candidate_registry_frozen_before_evaluation,production_influence_enabled
  )
  select
    'IDX_DRIVER_REGISTRY_GATE10_V2','IDX_DRIVER_WEEKLY_PIT_PANEL_V2','IDX_DRIVER_PURGED_EXPANDING_WF_V2',
    benchmark_contract,
    'SIGNAL_DATE_CROSS_SECTIONAL_PERCENT_RANK_NO_FUTURE_ROWS__MARKET_LEVEL_TRAILING_252_SESSION_RANK',
    purge_rule,horizons,fold_count_per_horizon,
    jsonb_set(
      jsonb_set(
        acceptance_criteria,
        '{single_driver}',
        to_jsonb('valid_oos_cells>=15;direction_agreement>=66.67%;heldout_mean_alpha>0;forward_mean_alpha>0;positive_horizons=3;coverage>=60%;regime_consistency measured and >=50%;liquidity_consistency measured and >=50%'::text),
        true
      ),
      '{interaction,rule}',
      to_jsonb('valid_oos_cells>=12;direction_agreement>=66.67%;heldout_and_forward_incremental_lift>0;minimum_samples_from_registry;regime_consistency measured and >=50%;liquidity_consistency measured and >=50%;FIN_BALANCE overlap can never qualify as independent confirmation'::text),
      true
    ) || jsonb_build_object('closure_hardening','V2 fixes market-level rank scope, explicit TECH_CHOCH dependency, computed leakage controls, fail-closed robustness, and executable FIN_BALANCE replay guard'),
    max_interaction_budget,69,12,v_hash,v_frozen,true,false
  from public.flow_driver_research_policy_v1
  where registry_version='IDX_DRIVER_REGISTRY_GATE10_V1';
end
$do$;

create table if not exists public.flow_driver_contract_supersession_v1(
  superseded_registry text primary key,
  active_registry text not null,
  superseded_panel_contract text not null,
  active_panel_contract text not null,
  superseded_walkforward_contract text not null,
  active_walkforward_contract text not null,
  reason text not null,
  created_at timestamptz not null default now(),
  production_influence_enabled boolean not null default false check(production_influence_enabled=false)
);

insert into public.flow_driver_contract_supersession_v1(
  superseded_registry,active_registry,superseded_panel_contract,active_panel_contract,
  superseded_walkforward_contract,active_walkforward_contract,reason,production_influence_enabled
) values(
  'IDX_DRIVER_REGISTRY_GATE10_V1','IDX_DRIVER_REGISTRY_GATE10_V2',
  'IDX_DRIVER_WEEKLY_PIT_PANEL_V1','IDX_DRIVER_WEEKLY_PIT_PANEL_V2',
  'IDX_DRIVER_PURGED_EXPANDING_WF_V1','IDX_DRIVER_PURGED_EXPANDING_WF_V2',
  'Phase-1 closure audit: preserve V1 immutable history while correcting MKT_RISK_ON_CONTEXT rank scope and TECH_CHOCH dependency metadata; V2 is research-only.',false
) on conflict(superseded_registry) do update set
  active_registry=excluded.active_registry,
  active_panel_contract=excluded.active_panel_contract,
  active_walkforward_contract=excluded.active_walkforward_contract,
  reason=excluded.reason,
  production_influence_enabled=false;

alter table public.flow_driver_contract_supersession_v1 enable row level security;
revoke all on table public.flow_driver_contract_supersession_v1 from public,anon,authenticated;
grant select,insert,update,delete on table public.flow_driver_contract_supersession_v1 to service_role;
