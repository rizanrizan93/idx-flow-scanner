-- Promotion hardening is a new contract.  Frozen Gate-15 V1 research policy
-- and its historical assessment remain untouched and shadow-only.

create table if not exists public.flow_gate15_promotion_assessment_v2(
  assessment_contract text not null,
  policy_version text not null,
  candidate_id text not null,
  candidate_type text not null check(candidate_type in('DRIVER','INTERACTION')),
  assessment_state text not null check(assessment_state in(
    'INSUFFICIENT_EVIDENCE','CONTINUE_SHADOW',
    'READY_FOR_LIMITED_PROMOTION_EXPERIMENT','FAIL_CLOSED')),
  independent_matured_signal_dates integer not null,
  minimum_matured_sample_across_horizons integer not null,
  observed_metrics jsonb not null,
  gate_results jsonb not null,
  robustness_state text not null,
  assessed_at timestamptz not null default statement_timestamp(),
  production_influence_enabled boolean not null default false
    check(production_influence_enabled=false),
  primary key(assessment_contract,candidate_id),
  foreign key(policy_version,candidate_id)
    references public.flow_gate15_promotion_policy_v1(policy_version,candidate_id)
);

create table if not exists public.flow_strategy_lifecycle_policy_v3(
  lifecycle_policy_version text not null,
  gate15_policy_version text not null,
  candidate_id text not null,
  candidate_type text not null check(candidate_type in('DRIVER','INTERACTION')),
  limited_weight numeric not null check(limited_weight>0 and limited_weight<=0.05),
  full_weight numeric not null check(full_weight>=limited_weight and full_weight<=0.10),
  policy_payload jsonb not null,
  policy_hash text not null check(length(policy_hash)=64),
  frozen_before_first_matured_outcome boolean not null
    check(frozen_before_first_matured_outcome),
  matured_outcomes_at_freeze integer not null check(matured_outcomes_at_freeze=0),
  frozen_at timestamptz not null default statement_timestamp(),
  primary key(lifecycle_policy_version,candidate_id),
  foreign key(gate15_policy_version,candidate_id)
    references public.flow_gate15_promotion_policy_v1(policy_version,candidate_id)
);

create table if not exists public.flow_strategy_lifecycle_state_v3(
  lifecycle_policy_version text not null,
  candidate_id text not null,
  candidate_type text not null,
  promotion_state text not null check(promotion_state in(
    'SHADOW_ONLY','EVIDENCE_ACCUMULATING','READY_FOR_LIMITED_PROMOTION',
    'LIMITED_PRODUCTION','FULL_PRODUCTION','DEGRADED','SUSPENDED','FAIL_CLOSED')),
  previous_state text,
  effective_from date,
  limited_started_at timestamptz,
  full_started_at timestamptz,
  weight numeric not null default 0 check(weight between 0 and 0.10),
  maximum_weight numeric not null check(maximum_weight between 0 and 0.10),
  production_influence_enabled boolean not null default false,
  integrity_state text not null,
  evidence_snapshot jsonb not null default '{}'::jsonb,
  transition_reason text not null,
  assessed_at timestamptz not null default statement_timestamp(),
  last_transition_at timestamptz not null default statement_timestamp(),
  primary key(lifecycle_policy_version,candidate_id),
  foreign key(lifecycle_policy_version,candidate_id)
    references public.flow_strategy_lifecycle_policy_v3(lifecycle_policy_version,candidate_id),
  check((promotion_state in('LIMITED_PRODUCTION','FULL_PRODUCTION')
      and production_influence_enabled and weight>0 and effective_from is not null
      and limited_started_at is not null and integrity_state='PASS')
    or (promotion_state not in('LIMITED_PRODUCTION','FULL_PRODUCTION')
      and not production_influence_enabled and weight=0))
);

create table if not exists public.flow_strategy_lifecycle_history_v3(
  transition_id uuid primary key default extensions.gen_random_uuid(),
  lifecycle_policy_version text not null,
  candidate_id text not null,
  from_state text,
  to_state text not null,
  previous_weight numeric not null,
  new_weight numeric not null,
  effective_from date,
  limited_started_at timestamptz,
  full_started_at timestamptz,
  evidence_snapshot jsonb not null,
  transition_reason text not null,
  assessed_at timestamptz not null default statement_timestamp(),
  production_influence_enabled boolean not null,
  foreign key(lifecycle_policy_version,candidate_id)
    references public.flow_strategy_lifecycle_policy_v3(lifecycle_policy_version,candidate_id)
);

create index if not exists flow_strategy_lifecycle_state_v3_state_idx
  on public.flow_strategy_lifecycle_state_v3(promotion_state,assessed_at desc);
create index if not exists flow_strategy_lifecycle_history_v3_candidate_idx
  on public.flow_strategy_lifecycle_history_v3(candidate_id,assessed_at desc);

with policy_payload as(
  select p.*,
    jsonb_build_object(
      'assessment_contract','GATE15_PROSPECTIVE_ASSESSMENT_V2',
      'required_assessment_state','READY_FOR_LIMITED_PROMOTION_EXPERIMENT',
      'minimum_post_limited_signal_dates_for_full',60,
      'minimum_post_limited_samples_per_horizon_for_full',p.minimum_sample_size_per_horizon,
      'minimum_monitor_signal_dates_for_demotion',10,
      'minimum_monitor_samples_per_horizon_for_demotion',30,
      'demotion_minimum_coverage_pct',80,
      'demotion_minimum_mean_alpha_pct',jsonb_build_object('5',0,'20',0,'60',0),
      'demotion_minimum_median_alpha_pct',jsonb_build_object('5',0,'20',0,'60',0),
      'demotion_minimum_hit_rate_pct',50,
      'demotion_minimum_rank_ic',0,
      'demotion_minimum_incremental_lift_pct',jsonb_build_object('5',0,'20',0,'60',0),
      'demotion_maximum_mean_adverse_excursion_abs_pct',
        jsonb_build_object('5',7.5,'20',12,'60',18),
      'demotion_minimum_regime_consistency_pct',50,
      'demotion_minimum_liquidity_consistency_pct',50,
      'minimum_distinct_regimes',2,
      'minimum_distinct_liquidity_states',2,
      'minimum_regime_cells',6,
      'minimum_liquidity_cells',6,
      'overlay_combination_rule','MAX_NON_STACKING',
      'limited_max_score_points',2.5,
      'full_max_score_points',5.0,
      'automatic_activation_enabled',true,
      'critical_integrity_failure_action','FAIL_CLOSED'
    ) payload
  from public.flow_gate15_promotion_policy_v1 p
  where p.policy_version='GATE15_PROMOTION_POLICY_V1'
)
insert into public.flow_strategy_lifecycle_policy_v3(
  lifecycle_policy_version,gate15_policy_version,candidate_id,candidate_type,
  limited_weight,full_weight,policy_payload,policy_hash,
  frozen_before_first_matured_outcome,matured_outcomes_at_freeze
)
select 'STRATEGY_LIFECYCLE_POLICY_V3',policy_version,candidate_id,candidate_type,
  maximum_initial_production_weight,0.10,payload,
  encode(extensions.digest(convert_to(payload::text,'UTF8'),'sha256'),'hex'),
  true,(select count(*) from public.flow_attribution_forward_outcome_v1
    where outcome_state='MATURED')
from policy_payload
on conflict(lifecycle_policy_version,candidate_id) do nothing;

do $do$
begin
  if (select count(*) from public.flow_strategy_lifecycle_policy_v3
      where lifecycle_policy_version='STRATEGY_LIFECYCLE_POLICY_V3')<>13 then
    raise exception 'V3 policy must contain FIN_BALANCE and exactly 12 frozen interactions';
  end if;
  if exists(select 1 from public.flow_strategy_lifecycle_policy_v3
      where lifecycle_policy_version='STRATEGY_LIFECYCLE_POLICY_V3'
        and policy_hash<>encode(extensions.digest(
          convert_to(policy_payload::text,'UTF8'),'sha256'),'hex')) then
    raise exception 'V3 policy hash mismatch';
  end if;
end
$do$;

create or replace function public.flow_assess_gate15_promotion_v2()
returns jsonb
language plpgsql
security invoker
set search_path=''
set work_mem='64MB'
as $fn$
declare v_rows integer;v_integrity boolean;
begin
  select
    (select count(*)=13 from public.flow_gate15_promotion_policy_v1
      where policy_version='GATE15_PROMOTION_POLICY_V1'
        and frozen_before_first_matured_outcome and matured_outcomes_at_freeze=0)
    and not exists(select 1 from public.flow_attribution_forward_outcome_v1 o
      join public.flow_attribution_prospective_candidate_v1 c
        on c.attribution_contract=o.attribution_contract and c.signal_date=o.signal_date
        and c.ticker=o.ticker and c.candidate_id=o.candidate_id
      where o.attribution_contract='IDX_PREDICTIVE_ATTRIBUTION_SHADOW_V1'
        and (o.target_date<=o.signal_date or o.calculated_at<=c.captured_at))
    and not exists(select 1 from public.flow_attribution_prospective_driver_v1
      where production_influence_enabled)
    and not exists(select 1 from public.flow_attribution_prospective_candidate_v1
      where production_influence_enabled)
    and not exists(select 1 from public.flow_attribution_forward_outcome_v1
      where production_influence_enabled)
  into v_integrity;

  with policy_horizon as(
    select p.*,h.horizon_days
    from public.flow_gate15_promotion_policy_v1 p
    cross join(values(5),(20),(60)) h(horizon_days)
    where p.policy_version='GATE15_PROMOTION_POLICY_V1'
  ), active as(
    select c.attribution_contract,c.signal_date,c.ticker,c.candidate_id,
      c.candidate_type,c.component_ids,h.horizon_days,
      case when c.candidate_type='DRIVER'
        then nullif(c.component_percentiles->>c.candidate_id,'')::numeric
        else (select min(nullif(x.value,'')::numeric)
          from jsonb_each_text(c.component_percentiles) x) end signal_strength,
      (select i.trade_date from public.flow_official_index_summary i
        where i.index_code='COMPOSITE' and i.source_verified
          and i.trade_date>c.signal_date order by i.trade_date
        offset(h.horizon_days-1) limit 1) target_date
    from public.flow_attribution_prospective_candidate_v1 c
    cross join(values(5),(20),(60)) h(horizon_days)
    where c.attribution_contract='IDX_PREDICTIVE_ATTRIBUTION_SHADOW_V1'
      and c.active_signal
  ), expected as(
    select candidate_id,horizon_days,
      count(*) filter(where target_date is not null)::int expected_samples
    from active group by candidate_id,horizon_days
  ), matured_base as(
    select a.*,o.alpha_vs_ihsg_pct,o.max_adverse_excursion_pct
    from active a join public.flow_attribution_forward_outcome_v1 o
      on o.attribution_contract=a.attribution_contract and o.signal_date=a.signal_date
      and o.ticker=a.ticker and o.candidate_id=a.candidate_id
      and o.horizon_days=a.horizon_days and o.outcome_state='MATURED'
    where a.signal_strength is not null and o.alpha_vs_ihsg_pct is not null
  ), matured_ranked as(
    select m.*,percent_rank() over(partition by candidate_id,horizon_days
        order by signal_strength) strength_rank,
      percent_rank() over(partition by candidate_id,horizon_days
        order by alpha_vs_ihsg_pct) alpha_rank
    from matured_base m
  ), component_cell as(
    select m.candidate_id,m.horizon_days,d.driver_id,
      avg(d.alpha_vs_ihsg_pct) component_alpha
    from matured_base m
    join public.flow_component_forward_outcome_diagnostic_v1 d
      on d.attribution_contract=m.attribution_contract and d.signal_date=m.signal_date
      and d.ticker=m.ticker and d.horizon_days=m.horizon_days
      and d.driver_id=any(m.component_ids) and d.outcome_state='MATURED'
    group by m.candidate_id,m.horizon_days,d.driver_id
  ), incremental as(
    select m.candidate_id,m.horizon_days,avg(m.alpha_vs_ihsg_pct)-max(c.component_alpha) lift
    from matured_base m left join component_cell c
      on c.candidate_id=m.candidate_id and c.horizon_days=m.horizon_days
    group by m.candidate_id,m.horizon_days
  ), by_horizon as(
    select ph.candidate_id,ph.horizon_days,
      count(distinct m.signal_date)::int matured_signal_dates,
      coalesce(e.expected_samples,0)::int expected_samples,
      count(m.ticker)::int matured_samples,
      100.0*count(m.ticker)/nullif(e.expected_samples,0) coverage_pct,
      avg(m.alpha_vs_ihsg_pct) mean_alpha,
      percentile_cont(0.5) within group(order by m.alpha_vs_ihsg_pct) median_alpha,
      100.0*count(*) filter(where m.alpha_vs_ihsg_pct>0)/nullif(count(m.ticker),0) hit_rate,
      corr(m.strength_rank::double precision,m.alpha_rank::double precision) rank_ic,
      abs(avg(m.max_adverse_excursion_pct)) mean_adverse_abs,
      i.lift incremental_lift
    from policy_horizon ph left join matured_ranked m
      on m.candidate_id=ph.candidate_id and m.horizon_days=ph.horizon_days
    left join expected e on e.candidate_id=ph.candidate_id and e.horizon_days=ph.horizon_days
    left join incremental i on i.candidate_id=ph.candidate_id and i.horizon_days=ph.horizon_days
    group by ph.candidate_id,ph.horizon_days,e.expected_samples,i.lift
  ), robustness_base as(
    select m.*,
      u.liquidity_state,
      case when idx.close is null or prior.close is null or prior.close=0 then null
        when idx.close/prior.close-1>=0 then 'BULL_OR_FLAT' else 'BEAR' end regime
    from matured_base m
    left join public.flow_universe_snapshot_v1 u
      on u.universe_contract='TOP_900_UNIVERSE_V1' and u.snapshot_date=m.signal_date
      and u.ticker=m.ticker
    left join public.flow_official_index_summary idx
      on idx.index_code='COMPOSITE' and idx.source_verified and idx.trade_date=m.signal_date
    left join lateral(select z.close from public.flow_official_index_summary z
      where z.index_code='COMPOSITE' and z.source_verified and z.trade_date<m.signal_date
      order by z.trade_date desc offset 19 limit 1) prior on true
  ), regime_cell as(
    select candidate_id,horizon_days,regime,avg(alpha_vs_ihsg_pct) cell_alpha
    from robustness_base where regime is not null
    group by candidate_id,horizon_days,regime
  ), regime as(
    select candidate_id,count(*)::int cell_count,count(distinct regime)::int state_count,
      100.0*count(*) filter(where cell_alpha>0)/nullif(count(*),0) consistency
    from regime_cell group by candidate_id
  ), liquidity_cell as(
    select candidate_id,horizon_days,liquidity_state,avg(alpha_vs_ihsg_pct) cell_alpha
    from robustness_base where liquidity_state is not null
    group by candidate_id,horizon_days,liquidity_state
  ), liquidity as(
    select candidate_id,count(*)::int cell_count,
      count(distinct liquidity_state)::int state_count,
      100.0*count(*) filter(where cell_alpha>0)/nullif(count(*),0) consistency
    from liquidity_cell group by candidate_id
  ), discovery as(
    select p.candidate_id,case when p.candidate_type='DRIVER'
      then d.mean_heldout_alpha_spread_pct>0 and d.mean_forward_alpha_spread_pct>0
      else x.mean_heldout_incremental_lift_pct>0
        and x.mean_forward_incremental_lift_pct>0 end historical_gate
    from public.flow_gate15_promotion_policy_v1 p
    left join public.flow_driver_oos_summary_v1 d
      on p.candidate_type='DRIVER' and d.validation_contract='IDX_DRIVER_PURGED_EXPANDING_WF_V2'
      and d.driver_id=p.candidate_id
    left join public.flow_driver_interaction_summary_v1 x
      on p.candidate_type='INTERACTION'
      and x.validation_contract='IDX_DRIVER_BOUNDED_CONFLUENCE_WF_V2'
      and x.interaction_id=p.candidate_id
    where p.policy_version='GATE15_PROMOTION_POLICY_V1'
  ), summary as(
    select p.policy_version,p.candidate_id,p.candidate_type,
      coalesce(min(h.matured_signal_dates),0)::int independent_dates,
      coalesce(min(h.matured_samples),0)::int min_samples,
      jsonb_agg(jsonb_build_object('horizon_days',h.horizon_days,
        'matured_signal_dates',h.matured_signal_dates,
        'expected_samples',h.expected_samples,'matured_samples',h.matured_samples,
        'coverage_pct',h.coverage_pct,'mean_alpha_pct',h.mean_alpha,
        'median_alpha_pct',h.median_alpha,'hit_rate_pct',h.hit_rate,
        'rank_ic',h.rank_ic,'mean_adverse_excursion_abs_pct',h.mean_adverse_abs,
        'incremental_lift_pct',h.incremental_lift) order by h.horizon_days) metrics,
      count(*)=3 horizon_count_gate,
      bool_and(coalesce(h.matured_signal_dates>=p.minimum_independent_signal_dates,false)) dates_gate,
      bool_and(coalesce(h.matured_samples>=p.minimum_sample_size_per_horizon,false)) sample_gate,
      bool_and(coalesce(h.coverage_pct>=p.minimum_forward_coverage_pct,false)) coverage_gate,
      bool_and(coalesce(h.mean_alpha>=(p.minimum_mean_alpha_pct->>h.horizon_days::text)::numeric,false)) mean_gate,
      bool_and(coalesce(h.median_alpha>=(p.minimum_median_alpha_pct->>h.horizon_days::text)::numeric,false)) median_gate,
      bool_and(coalesce(h.hit_rate>=p.minimum_direction_agreement_pct,false)) direction_gate,
      bool_and(coalesce(h.rank_ic>=p.minimum_rank_ic,false)) rank_gate,
      bool_and(coalesce(h.mean_adverse_abs<=
        (p.maximum_mean_adverse_excursion_abs_pct->>h.horizon_days::text)::numeric,false)) adverse_gate,
      bool_and(case when p.candidate_type='DRIVER' then true else coalesce(
        h.incremental_lift>=(p.minimum_incremental_lift_pct->>h.horizon_days::text)::numeric,false) end) lift_gate,
      count(*) filter(where h.mean_alpha>0)::int positive_horizons,
      coalesce(r.cell_count,0)::int regime_cells,coalesce(r.state_count,0)::int regimes,
      r.consistency regime_consistency,coalesce(l.cell_count,0)::int liquidity_cells,
      coalesce(l.state_count,0)::int liquidity_states,l.consistency liquidity_consistency,
      coalesce(d.historical_gate,false) historical_gate
    from public.flow_gate15_promotion_policy_v1 p
    join by_horizon h on h.candidate_id=p.candidate_id
    left join regime r on r.candidate_id=p.candidate_id
    left join liquidity l on l.candidate_id=p.candidate_id
    left join discovery d on d.candidate_id=p.candidate_id
    where p.policy_version='GATE15_PROMOTION_POLICY_V1'
    group by p.policy_version,p.candidate_id,p.candidate_type,r.cell_count,r.state_count,
      r.consistency,l.cell_count,l.state_count,l.consistency,d.historical_gate
  )
  insert into public.flow_gate15_promotion_assessment_v2(
    assessment_contract,policy_version,candidate_id,candidate_type,assessment_state,
    independent_matured_signal_dates,minimum_matured_sample_across_horizons,
    observed_metrics,gate_results,robustness_state,production_influence_enabled
  )
  select 'GATE15_PROSPECTIVE_ASSESSMENT_V2',s.policy_version,s.candidate_id,s.candidate_type,
    case when not v_integrity then 'FAIL_CLOSED'
      when s.min_samples=0 or s.independent_dates=0 then 'INSUFFICIENT_EVIDENCE'
      when s.horizon_count_gate and s.dates_gate and s.sample_gate and s.coverage_gate
        and s.mean_gate and s.median_gate and s.direction_gate and s.rank_gate
        and s.adverse_gate and s.lift_gate and s.positive_horizons=3
        and s.regimes>=2 and s.regime_cells>=6
        and s.regime_consistency>=60 and s.liquidity_states>=2
        and s.liquidity_cells>=6 and s.liquidity_consistency>=60
        and s.historical_gate then 'READY_FOR_LIMITED_PROMOTION_EXPERIMENT'
      else 'CONTINUE_SHADOW' end,
    s.independent_dates,s.min_samples,s.metrics,
    jsonb_build_object('integrity_pass',v_integrity,
      'exact_three_horizons_pass',s.horizon_count_gate,
      'independent_matured_dates_pass',coalesce(s.dates_gate,false),
      'sample_pass',coalesce(s.sample_gate,false),
      'coverage_pass',coalesce(s.coverage_gate,false),
      'mean_alpha_pass',coalesce(s.mean_gate,false),
      'median_alpha_pass',coalesce(s.median_gate,false),
      'direction_agreement_pass',coalesce(s.direction_gate,false),
      'rank_ic_pass',coalesce(s.rank_gate,false),
      'adverse_excursion_pass',coalesce(s.adverse_gate,false),
      'incremental_lift_pass',coalesce(s.lift_gate,false),
      'positive_horizons_pass',s.positive_horizons=3,
      'historical_heldout_forward_pass',s.historical_gate,
      'regime_completeness_pass',s.regimes>=2 and s.regime_cells>=6,
      'regime_consistency_pass',coalesce(s.regime_consistency>=60,false),
      'liquidity_completeness_pass',s.liquidity_states>=2 and s.liquidity_cells>=6,
      'liquidity_consistency_pass',coalesce(s.liquidity_consistency>=60,false),
      'missing_values_fail_closed',true),
    case when s.regimes>=2 and s.regime_cells>=6 and s.liquidity_states>=2
      and s.liquidity_cells>=6 then 'MEASURED' else 'INSUFFICIENT_ROBUSTNESS' end,false
  from summary s
  on conflict(assessment_contract,candidate_id) do update set
    assessment_state=excluded.assessment_state,
    independent_matured_signal_dates=excluded.independent_matured_signal_dates,
    minimum_matured_sample_across_horizons=excluded.minimum_matured_sample_across_horizons,
    observed_metrics=excluded.observed_metrics,gate_results=excluded.gate_results,
    robustness_state=excluded.robustness_state,assessed_at=statement_timestamp();
  get diagnostics v_rows=row_count;
  return jsonb_build_object('status','COMPLETED','assessment_contract',
    'GATE15_PROSPECTIVE_ASSESSMENT_V2','candidate_assessments',v_rows,
    'integrity_ok',v_integrity,'production_influence_enabled',false);
end
$fn$;

create or replace function public.flow_strategy_global_integrity_v3()
returns boolean
language sql
stable
security invoker
set search_path=''
as $fn$
select
  (select count(*)=13 from public.flow_strategy_lifecycle_policy_v3
    where lifecycle_policy_version='STRATEGY_LIFECYCLE_POLICY_V3'
      and policy_hash=encode(extensions.digest(
        convert_to(policy_payload::text,'UTF8'),'sha256'),'hex'))
  and (select count(*)=13 from public.flow_attribution_forward_registry_v1
    where attribution_contract='IDX_PREDICTIVE_ATTRIBUTION_SHADOW_V1')
  and exists(select 1 from public.flow_driver_gate12_manifest_v1
    where validation_contract='IDX_DRIVER_PURGED_EXPANDING_WF_V2'
      and gate_state='PASS' and panel_leakage_count=0 and training_target_overlap_leaks=0)
  and exists(select 1 from public.flow_driver_gate13_manifest_v1
    where validation_contract='IDX_DRIVER_BOUNDED_CONFLUENCE_WF_V2'
      and gate_state='PASS' and target_leakage_count=0 and posthoc_mining_count=0)
  and not exists(select 1 from public.flow_attribution_prospective_driver_v1
    where production_influence_enabled)
  and not exists(select 1 from public.flow_attribution_prospective_candidate_v1
    where production_influence_enabled)
  and not exists(select 1 from public.flow_attribution_forward_outcome_v1
    where production_influence_enabled)
  and not exists(select 1 from public.flow_attribution_forward_outcome_v1 o
    join public.flow_attribution_prospective_candidate_v1 c
      on c.attribution_contract=o.attribution_contract and c.signal_date=o.signal_date
      and c.ticker=o.ticker and c.candidate_id=o.candidate_id
    where o.attribution_contract='IDX_PREDICTIVE_ATTRIBUTION_SHADOW_V1'
      and (o.target_date<=o.signal_date or o.calculated_at<=c.captured_at))
$fn$;

create or replace function public.flow_strategy_lifecycle_decision_v3(
  p_current_state text,p_assessment_state text,p_integrity_ok boolean,
  p_all_signal_dates integer,p_monitor jsonb
)
returns text
language plpgsql
immutable
security invoker
set search_path=''
as $fn$
begin
  if not coalesce(p_integrity_ok,false) then return 'FAIL_CLOSED'; end if;
  if p_current_state='FAIL_CLOSED' then return 'FAIL_CLOSED'; end if;
  if p_current_state in('SUSPENDED','DEGRADED') then return 'SHADOW_ONLY'; end if;
  if p_current_state in('SHADOW_ONLY','EVIDENCE_ACCUMULATING') then
    if p_assessment_state='READY_FOR_LIMITED_PROMOTION_EXPERIMENT' then
      return 'READY_FOR_LIMITED_PROMOTION';
    end if;
    if coalesce(p_all_signal_dates,0)>0 then return 'EVIDENCE_ACCUMULATING'; end if;
    return 'SHADOW_ONLY';
  end if;
  if p_current_state='READY_FOR_LIMITED_PROMOTION' then
    if p_assessment_state='READY_FOR_LIMITED_PROMOTION_EXPERIMENT' then
      return 'LIMITED_PRODUCTION';
    end if;
    return 'EVIDENCE_ACCUMULATING';
  end if;
  if p_current_state='LIMITED_PRODUCTION' then
    if coalesce((p_monitor->>'monitor_observable')::boolean,false)
      and not coalesce((p_monitor->>'demotion_gate_pass')::boolean,false) then
      return 'SHADOW_ONLY';
    end if;
    if p_assessment_state='READY_FOR_LIMITED_PROMOTION_EXPERIMENT'
      and coalesce((p_monitor->>'full_gate_pass')::boolean,false) then
      return 'FULL_PRODUCTION';
    end if;
    return 'LIMITED_PRODUCTION';
  end if;
  if p_current_state='FULL_PRODUCTION' then
    if coalesce((p_monitor->>'monitor_observable')::boolean,false)
      and not coalesce((p_monitor->>'demotion_gate_pass')::boolean,false) then
      return 'LIMITED_PRODUCTION';
    end if;
    return 'FULL_PRODUCTION';
  end if;
  return 'SHADOW_ONLY';
end
$fn$;

-- This monitor is deliberately evaluated only after a candidate enters limited
-- production.  Pre-promotion outcomes cannot satisfy full-promotion evidence.
create or replace function public.flow_strategy_post_promotion_monitor_v3(
  p_candidate_id text,p_started_at timestamptz
)
returns jsonb
language sql
stable
security invoker
set search_path=''
set work_mem='64MB'
as $fn$
with policy as(
  select p.policy_payload,g.candidate_type,g.minimum_sample_size_per_horizon,
    g.minimum_forward_coverage_pct,g.minimum_mean_alpha_pct,
    g.minimum_median_alpha_pct,g.minimum_direction_agreement_pct,
    g.minimum_rank_ic,g.minimum_incremental_lift_pct,
    g.maximum_mean_adverse_excursion_abs_pct,
    g.minimum_regime_consistency_pct,g.minimum_liquidity_consistency_pct
  from public.flow_strategy_lifecycle_policy_v3 p
  join public.flow_gate15_promotion_policy_v1 g
    on g.policy_version=p.gate15_policy_version and g.candidate_id=p.candidate_id
  where p.lifecycle_policy_version='STRATEGY_LIFECYCLE_POLICY_V3'
    and p.candidate_id=p_candidate_id
), active as(
  select c.*,h.horizon_days,
    case when c.candidate_type='DRIVER'
      then nullif(c.component_percentiles->>c.candidate_id,'')::numeric
      else (select min(nullif(x.value,'')::numeric)
        from jsonb_each_text(c.component_percentiles) x) end signal_strength,
    (select i.trade_date from public.flow_official_index_summary i
      where i.index_code='COMPOSITE' and i.source_verified and i.trade_date>c.signal_date
      order by i.trade_date offset(h.horizon_days-1) limit 1) target_date
  from public.flow_attribution_prospective_candidate_v1 c
  cross join(values(5),(20),(60)) h(horizon_days)
  where c.attribution_contract='IDX_PREDICTIVE_ATTRIBUTION_SHADOW_V1'
    and c.candidate_id=p_candidate_id and c.active_signal
    and p_started_at is not null and c.captured_at>p_started_at
), expected as(
  select horizon_days,count(*) filter(where target_date is not null)::int expected_samples
  from active group by horizon_days
), matured_base as(
  select a.*,o.alpha_vs_ihsg_pct,o.max_adverse_excursion_pct
  from active a join public.flow_attribution_forward_outcome_v1 o
    on o.attribution_contract=a.attribution_contract and o.signal_date=a.signal_date
    and o.ticker=a.ticker and o.candidate_id=a.candidate_id
    and o.horizon_days=a.horizon_days and o.outcome_state='MATURED'
  where a.signal_strength is not null and o.alpha_vs_ihsg_pct is not null
), ranked as(
  select m.*,percent_rank() over(partition by horizon_days order by signal_strength) strength_rank,
    percent_rank() over(partition by horizon_days order by alpha_vs_ihsg_pct) alpha_rank
  from matured_base m
), component_cell as(
  select m.horizon_days,d.driver_id,avg(d.alpha_vs_ihsg_pct) component_alpha
  from matured_base m join public.flow_component_forward_outcome_diagnostic_v1 d
    on d.attribution_contract=m.attribution_contract and d.signal_date=m.signal_date
    and d.ticker=m.ticker and d.horizon_days=m.horizon_days
    and d.driver_id=any(m.component_ids) and d.outcome_state='MATURED'
  group by m.horizon_days,d.driver_id
), incremental as(
  select m.horizon_days,avg(m.alpha_vs_ihsg_pct)-max(c.component_alpha) lift
  from matured_base m left join component_cell c using(horizon_days)
  group by m.horizon_days
), horizons as(
  select h.horizon_days,count(distinct r.signal_date)::int signal_dates,
    coalesce(e.expected_samples,0)::int expected_samples,count(r.ticker)::int samples,
    100.0*count(r.ticker)/nullif(e.expected_samples,0) coverage,
    avg(r.alpha_vs_ihsg_pct) mean_alpha,
    percentile_cont(0.5) within group(order by r.alpha_vs_ihsg_pct) median_alpha,
    100.0*count(*) filter(where r.alpha_vs_ihsg_pct>0)/nullif(count(r.ticker),0) hit_rate,
    corr(r.strength_rank::double precision,r.alpha_rank::double precision) rank_ic,
    abs(avg(r.max_adverse_excursion_pct)) adverse_abs,i.lift
  from(values(5),(20),(60)) h(horizon_days)
  left join ranked r using(horizon_days) left join expected e using(horizon_days)
  left join incremental i using(horizon_days)
  group by h.horizon_days,e.expected_samples,i.lift
), robust_base as(
  select m.*,u.liquidity_state,
    case when idx.close is null or prior.close is null or prior.close=0 then null
      when idx.close/prior.close-1>=0 then 'BULL_OR_FLAT' else 'BEAR' end regime
  from matured_base m left join public.flow_universe_snapshot_v1 u
    on u.universe_contract='TOP_900_UNIVERSE_V1' and u.snapshot_date=m.signal_date
    and u.ticker=m.ticker
  left join public.flow_official_index_summary idx
    on idx.index_code='COMPOSITE' and idx.source_verified and idx.trade_date=m.signal_date
  left join lateral(select z.close from public.flow_official_index_summary z
    where z.index_code='COMPOSITE' and z.source_verified and z.trade_date<m.signal_date
    order by z.trade_date desc offset 19 limit 1) prior on true
), regime_cell as(
  select horizon_days,regime,avg(alpha_vs_ihsg_pct) alpha from robust_base
  where regime is not null group by horizon_days,regime
), regime as(
  select count(*)::int cells,count(distinct regime)::int states,
    100.0*count(*) filter(where alpha>0)/nullif(count(*),0) consistency from regime_cell
), liquidity_cell as(
  select horizon_days,liquidity_state,avg(alpha_vs_ihsg_pct) alpha from robust_base
  where liquidity_state is not null group by horizon_days,liquidity_state
), liquidity as(
  select count(*)::int cells,count(distinct liquidity_state)::int states,
    100.0*count(*) filter(where alpha>0)/nullif(count(*),0) consistency from liquidity_cell
), summary as(
  select p.candidate_type,p.minimum_sample_size_per_horizon,p.minimum_forward_coverage_pct,
    p.minimum_mean_alpha_pct,p.minimum_median_alpha_pct,p.minimum_direction_agreement_pct,
    p.minimum_rank_ic,p.minimum_incremental_lift_pct,p.maximum_mean_adverse_excursion_abs_pct,
    p.minimum_regime_consistency_pct,p.minimum_liquidity_consistency_pct,p.policy_payload,
    coalesce(min(h.signal_dates),0)::int dates,coalesce(min(h.samples),0)::int samples,
    jsonb_agg(to_jsonb(h) order by h.horizon_days) horizon_metrics,
    bool_and(coalesce(h.signal_dates>=60,false)
      and coalesce(h.samples>=p.minimum_sample_size_per_horizon,false)
      and coalesce(h.coverage>=p.minimum_forward_coverage_pct,false)
      and coalesce(h.mean_alpha>=(p.minimum_mean_alpha_pct->>h.horizon_days::text)::numeric,false)
      and coalesce(h.median_alpha>=(p.minimum_median_alpha_pct->>h.horizon_days::text)::numeric,false)
      and coalesce(h.hit_rate>=p.minimum_direction_agreement_pct,false)
      and coalesce(h.rank_ic>=p.minimum_rank_ic,false)
      and coalesce(h.adverse_abs<=
        (p.maximum_mean_adverse_excursion_abs_pct->>h.horizon_days::text)::numeric,false)
      and case when p.candidate_type='DRIVER' then true else coalesce(
        h.lift>=(p.minimum_incremental_lift_pct->>h.horizon_days::text)::numeric,false) end
    ) full_horizon_gate,
    bool_and(coalesce(h.coverage>=(p.policy_payload->>'demotion_minimum_coverage_pct')::numeric,false)
      and coalesce(h.mean_alpha>(p.policy_payload#>>array['demotion_minimum_mean_alpha_pct',h.horizon_days::text])::numeric,false)
      and coalesce(h.median_alpha>=(p.policy_payload#>>array['demotion_minimum_median_alpha_pct',h.horizon_days::text])::numeric,false)
      and coalesce(h.hit_rate>=(p.policy_payload->>'demotion_minimum_hit_rate_pct')::numeric,false)
      and coalesce(h.rank_ic>=(p.policy_payload->>'demotion_minimum_rank_ic')::numeric,false)
      and coalesce(h.adverse_abs<=(p.policy_payload#>>array['demotion_maximum_mean_adverse_excursion_abs_pct',h.horizon_days::text])::numeric,false)
      and case when p.candidate_type='DRIVER' then true else coalesce(
        h.lift>(p.policy_payload#>>array['demotion_minimum_incremental_lift_pct',h.horizon_days::text])::numeric,false) end
    ) demotion_horizon_gate
  from policy p cross join horizons h group by p.candidate_type,
    p.minimum_sample_size_per_horizon,p.minimum_forward_coverage_pct,
    p.minimum_mean_alpha_pct,p.minimum_median_alpha_pct,p.minimum_direction_agreement_pct,
    p.minimum_rank_ic,p.minimum_incremental_lift_pct,p.maximum_mean_adverse_excursion_abs_pct,
    p.minimum_regime_consistency_pct,p.minimum_liquidity_consistency_pct,p.policy_payload
)
select coalesce(jsonb_build_object(
  'post_limited_signal_dates',s.dates,'minimum_samples_across_horizons',s.samples,
  'horizons',s.horizon_metrics,'regime_cells',r.cells,'regime_states',r.states,
  'regime_consistency_pct',r.consistency,'liquidity_cells',l.cells,
  'liquidity_states',l.states,'liquidity_consistency_pct',l.consistency,
  'monitor_observable',s.dates>=(s.policy_payload->>'minimum_monitor_signal_dates_for_demotion')::int
    and s.samples>=(s.policy_payload->>'minimum_monitor_samples_per_horizon_for_demotion')::int,
  'demotion_gate_pass',coalesce(s.demotion_horizon_gate,false)
    and coalesce(r.states,0)>=(s.policy_payload->>'minimum_distinct_regimes')::int
    and coalesce(r.cells,0)>=(s.policy_payload->>'minimum_regime_cells')::int
    and coalesce(r.consistency,0)>=(s.policy_payload->>'demotion_minimum_regime_consistency_pct')::numeric
    and coalesce(l.states,0)>=(s.policy_payload->>'minimum_distinct_liquidity_states')::int
    and coalesce(l.cells,0)>=(s.policy_payload->>'minimum_liquidity_cells')::int
    and coalesce(l.consistency,0)>=(s.policy_payload->>'demotion_minimum_liquidity_consistency_pct')::numeric,
  'full_gate_pass',coalesce(s.full_horizon_gate,false)
    and s.dates>=(s.policy_payload->>'minimum_post_limited_signal_dates_for_full')::int
    and coalesce(r.states,0)>=(s.policy_payload->>'minimum_distinct_regimes')::int
    and coalesce(r.cells,0)>=(s.policy_payload->>'minimum_regime_cells')::int
    and coalesce(r.consistency,0)>=s.minimum_regime_consistency_pct
    and coalesce(l.states,0)>=(s.policy_payload->>'minimum_distinct_liquidity_states')::int
    and coalesce(l.cells,0)>=(s.policy_payload->>'minimum_liquidity_cells')::int
    and coalesce(l.consistency,0)>=s.minimum_liquidity_consistency_pct,
  'missing_robustness_fails_closed',true
),'{}'::jsonb) from summary s cross join regime r cross join liquidity l
$fn$;

create or replace function public.flow_apply_strategy_lifecycle_v3()
returns jsonb
language plpgsql
security invoker
set search_path=''
as $fn$
declare r record;v_current text;v_next text;v_previous_weight numeric;
  v_effective date;v_limited_started timestamptz;v_full_started timestamptz;
  v_monitor jsonb;v_snapshot jsonb;v_weight numeric;v_max numeric;
  v_integrity boolean;v_changed integer:=0;v_assessed integer:=0;v_assess jsonb;
begin
  v_assess:=public.flow_assess_gate15_promotion_v2();
  v_integrity:=public.flow_strategy_global_integrity_v3();
  for r in
    select p.*,a.assessment_state,a.independent_matured_signal_dates,
      a.minimum_matured_sample_across_horizons,a.observed_metrics,a.gate_results,
      a.robustness_state,a.assessed_at assessment_timestamp,
      (select count(distinct c.signal_date) from public.flow_attribution_prospective_candidate_v1 c
        where c.attribution_contract='IDX_PREDICTIVE_ATTRIBUTION_SHADOW_V1'
          and c.candidate_id=p.candidate_id and c.active_signal) all_signal_dates
    from public.flow_strategy_lifecycle_policy_v3 p
    join public.flow_gate15_promotion_assessment_v2 a
      on a.assessment_contract='GATE15_PROSPECTIVE_ASSESSMENT_V2'
      and a.candidate_id=p.candidate_id and a.policy_version=p.gate15_policy_version
    where p.lifecycle_policy_version='STRATEGY_LIFECYCLE_POLICY_V3'
    order by p.candidate_id
  loop
    insert into public.flow_strategy_lifecycle_state_v3(
      lifecycle_policy_version,candidate_id,candidate_type,promotion_state,
      weight,maximum_weight,production_influence_enabled,integrity_state,
      transition_reason
    ) values(r.lifecycle_policy_version,r.candidate_id,r.candidate_type,'SHADOW_ONLY',
      0,r.limited_weight,false,case when v_integrity then 'PASS' else 'FAIL' end,
      'INITIALIZED_FAIL_CLOSED_ZERO_WEIGHT')
    on conflict(lifecycle_policy_version,candidate_id) do nothing;
    select promotion_state,weight,effective_from,limited_started_at,full_started_at
      into v_current,v_previous_weight,v_effective,v_limited_started,v_full_started
    from public.flow_strategy_lifecycle_state_v3
    where lifecycle_policy_version=r.lifecycle_policy_version and candidate_id=r.candidate_id
    for update;
    if v_current in('LIMITED_PRODUCTION','FULL_PRODUCTION') then
      v_monitor:=public.flow_strategy_post_promotion_monitor_v3(
        r.candidate_id,v_limited_started);
    else v_monitor:=jsonb_build_object('monitor_observable',false,
      'demotion_gate_pass',false,'full_gate_pass',false,
      'reason','NOT_IN_PRODUCTION_OBSERVATION'); end if;
    v_next:=public.flow_strategy_lifecycle_decision_v3(v_current,r.assessment_state,
      v_integrity,r.all_signal_dates::integer,v_monitor);
    if v_next='LIMITED_PRODUCTION' then v_weight:=r.limited_weight;v_max:=r.limited_weight;
    elsif v_next='FULL_PRODUCTION' then v_weight:=r.full_weight;v_max:=r.full_weight;
    else v_weight:=0;v_max:=case when v_next='READY_FOR_LIMITED_PROMOTION'
      then r.limited_weight else r.full_weight end; end if;
    if v_next='LIMITED_PRODUCTION' and v_current='READY_FOR_LIMITED_PROMOTION' then
      v_effective:=(statement_timestamp() at time zone 'Asia/Jakarta')::date+1;
      v_limited_started:=statement_timestamp();v_full_started:=null;
    elsif v_next='FULL_PRODUCTION' and v_current='LIMITED_PRODUCTION' then
      v_full_started:=statement_timestamp();
    elsif v_next not in('LIMITED_PRODUCTION','FULL_PRODUCTION') then
      v_effective:=null;v_limited_started:=null;v_full_started:=null;
    elsif v_next='LIMITED_PRODUCTION' and v_current='FULL_PRODUCTION' then
      v_full_started:=null;
    end if;
    v_snapshot:=jsonb_build_object('assessment_contract',
      'GATE15_PROSPECTIVE_ASSESSMENT_V2','assessment_state',r.assessment_state,
      'independent_matured_signal_dates',r.independent_matured_signal_dates,
      'minimum_matured_samples',r.minimum_matured_sample_across_horizons,
      'assessment_metrics',r.observed_metrics,'assessment_gates',r.gate_results,
      'robustness_state',r.robustness_state,'post_promotion_monitor',v_monitor,
      'integrity_ok',v_integrity,'policy_hash',r.policy_hash,
      'assessment_timestamp',r.assessment_timestamp,'cycle_result',v_assess);
    if v_next is distinct from v_current or v_weight is distinct from v_previous_weight then
      insert into public.flow_strategy_lifecycle_history_v3(
        lifecycle_policy_version,candidate_id,from_state,to_state,previous_weight,
        new_weight,effective_from,limited_started_at,full_started_at,evidence_snapshot,
        transition_reason,production_influence_enabled
      ) values(r.lifecycle_policy_version,r.candidate_id,v_current,v_next,
        v_previous_weight,v_weight,v_effective,v_limited_started,v_full_started,
        v_snapshot,'POLICY_V3_AUTOMATIC_TRANSITION',
        v_next in('LIMITED_PRODUCTION','FULL_PRODUCTION'));
      update public.flow_strategy_lifecycle_state_v3 set previous_state=v_current,
        promotion_state=v_next,effective_from=v_effective,
        limited_started_at=v_limited_started,full_started_at=v_full_started,
        weight=v_weight,maximum_weight=v_max,
        production_influence_enabled=v_next in('LIMITED_PRODUCTION','FULL_PRODUCTION'),
        integrity_state=case when v_integrity then 'PASS' else 'FAIL' end,
        evidence_snapshot=v_snapshot,transition_reason='POLICY_V3_AUTOMATIC_TRANSITION',
        assessed_at=statement_timestamp(),last_transition_at=statement_timestamp()
      where lifecycle_policy_version=r.lifecycle_policy_version and candidate_id=r.candidate_id;
      v_changed:=v_changed+1;
    else
      update public.flow_strategy_lifecycle_state_v3 set
        integrity_state=case when v_integrity then 'PASS' else 'FAIL' end,
        evidence_snapshot=v_snapshot,assessed_at=statement_timestamp()
      where lifecycle_policy_version=r.lifecycle_policy_version and candidate_id=r.candidate_id;
    end if;
    v_assessed:=v_assessed+1;
  end loop;
  return jsonb_build_object('status','COMPLETED','lifecycle_policy_version',
    'STRATEGY_LIFECYCLE_POLICY_V3','assessed_candidates',v_assessed,
    'state_changes',v_changed,'integrity_ok',v_integrity,
    'production_candidates',(select count(*) from public.flow_strategy_lifecycle_state_v3
      where lifecycle_policy_version='STRATEGY_LIFECYCLE_POLICY_V3'
        and production_influence_enabled),
    'production_influence_enabled',(select exists(select 1
      from public.flow_strategy_lifecycle_state_v3
      where lifecycle_policy_version='STRATEGY_LIFECYCLE_POLICY_V3'
        and production_influence_enabled)));
end
$fn$;

create or replace function public.flow_load_production_predictive_overlay_v3(
  p_signal_date date default null
)
returns table(signal_date date,ticker text,promotion_state text,candidate_id text,
  predictive_strength numeric,effective_weight numeric,score_adjustment_points numeric,
  lifecycle_policy_version text,policy_hash text,production_influence_enabled boolean)
language sql
stable
security invoker
set search_path=''
as $fn$
with manifest as(
  select m.* from public.flow_attribution_capture_manifest_v1 m
  where m.attribution_contract='IDX_PREDICTIVE_ATTRIBUTION_SHADOW_V1'
    and m.capture_state='CAPTURED' and m.prospective_driver_rows=4500
    and m.candidate_rows=11700 and m.signal_date=coalesce(p_signal_date,(
      select max(x.signal_date) from public.flow_attribution_capture_manifest_v1 x
      where x.attribution_contract='IDX_PREDICTIVE_ATTRIBUTION_SHADOW_V1'
        and x.capture_state='CAPTURED' and x.prospective_driver_rows=4500
        and x.candidate_rows=11700))
), enabled as(
  select s.*,p.policy_hash,p.policy_payload
  from public.flow_strategy_lifecycle_state_v3 s
  join public.flow_strategy_lifecycle_policy_v3 p using(lifecycle_policy_version,candidate_id)
  where s.lifecycle_policy_version='STRATEGY_LIFECYCLE_POLICY_V3'
    and s.promotion_state in('LIMITED_PRODUCTION','FULL_PRODUCTION')
    and s.production_influence_enabled and s.integrity_state='PASS' and s.weight>0
    and p.policy_hash=encode(extensions.digest(
      convert_to(p.policy_payload::text,'UTF8'),'sha256'),'hex')
), strengths as(
  select m.signal_date,c.ticker,e.promotion_state,e.candidate_id,e.weight,
    case when e.candidate_type='DRIVER' then d.normalized_value
      else (select min(nullif(x.value,'')::numeric)
        from jsonb_each_text(c.component_percentiles) x) end strength,
    e.lifecycle_policy_version,e.policy_hash,e.policy_payload
  from manifest m cross join enabled e
  join public.flow_attribution_prospective_candidate_v1 c
    on c.attribution_contract=m.attribution_contract and c.signal_date=m.signal_date
    and c.candidate_id=e.candidate_id and c.active_signal
    and c.captured_at=m.captured_at and c.signal_date>=e.effective_from
    and e.assessed_at>=m.captured_at
  join public.flow_official_stock_summary px
    on px.ticker=c.ticker and px.trade_date=c.signal_date and px.source_verified
    and px.close=c.base_close
  join public.flow_official_index_summary ix
    on ix.index_code='COMPOSITE' and ix.trade_date=c.signal_date and ix.source_verified
    and ix.close=c.base_ihsg_close
  left join public.flow_attribution_prospective_driver_v1 d
    on e.candidate_type='DRIVER' and d.attribution_contract=c.attribution_contract
    and d.signal_date=c.signal_date and d.ticker=c.ticker and d.driver_id=e.candidate_id
    and d.driver_state='AVAILABLE' and d.captured_at=m.captured_at
), ranked as(
  select s.*,greatest(s.weight*(100*s.strength-50),0) adjustment,
    row_number() over(partition by s.signal_date,s.ticker
      order by greatest(s.weight*(100*s.strength-50),0) desc,s.candidate_id) rn
  from strengths s where s.strength between 0 and 1
)
select signal_date,ticker,promotion_state,candidate_id,round(strength,6),weight,
  round(least(adjustment,case when promotion_state='LIMITED_PRODUCTION'
    then (policy_payload->>'limited_max_score_points')::numeric
    else (policy_payload->>'full_max_score_points')::numeric end),6),
  lifecycle_policy_version,policy_hash,true from ranked where rn=1
$fn$;

create or replace function public.flow_run_gate15_lifecycle_cycle_v3()
returns jsonb
language plpgsql
security invoker
set search_path=''
as $fn$
declare v_outcomes jsonb;v_lifecycle jsonb;
begin
  v_outcomes:=public.flow_run_gate15_outcome_cycle_v1();
  v_lifecycle:=public.flow_apply_strategy_lifecycle_v3();
  return jsonb_build_object('status','COMPLETED','outcomes',v_outcomes,
    'strategy_lifecycle',v_lifecycle,'production_influence_enabled',
    coalesce((v_lifecycle->>'production_influence_enabled')::boolean,false));
end
$fn$;

alter table public.flow_gate15_promotion_assessment_v2 enable row level security;
alter table public.flow_strategy_lifecycle_policy_v3 enable row level security;
alter table public.flow_strategy_lifecycle_state_v3 enable row level security;
alter table public.flow_strategy_lifecycle_history_v3 enable row level security;
revoke all on public.flow_gate15_promotion_assessment_v2,
  public.flow_strategy_lifecycle_policy_v3,public.flow_strategy_lifecycle_state_v3,
  public.flow_strategy_lifecycle_history_v3 from public,anon,authenticated,service_role;
grant select on public.flow_gate15_promotion_assessment_v2,
  public.flow_strategy_lifecycle_policy_v3,public.flow_strategy_lifecycle_state_v3,
  public.flow_strategy_lifecycle_history_v3 to service_role;
grant insert,update on public.flow_gate15_promotion_assessment_v2,
  public.flow_strategy_lifecycle_state_v3,public.flow_strategy_lifecycle_history_v3
  to service_role;

-- V2 can no longer influence production after V3 is installed.
update public.flow_strategy_lifecycle_state_v2 set promotion_state='SUSPENDED',
  previous_state=promotion_state,effective_from=null,weight=0,maximum_weight=0,
  production_influence_enabled=false,
  promotion_reason='SUPERSEDED_FAIL_CLOSED_BY_STRATEGY_LIFECYCLE_POLICY_V3',
  assessment_timestamp=statement_timestamp(),last_transition_at=statement_timestamp()
where lifecycle_policy_version='STRATEGY_LIFECYCLE_POLICY_V2';

revoke all on function public.flow_assess_gate15_promotion_v2(),
  public.flow_strategy_global_integrity_v3(),
  public.flow_strategy_lifecycle_decision_v3(text,text,boolean,integer,jsonb),
  public.flow_strategy_post_promotion_monitor_v3(text,timestamptz),
  public.flow_apply_strategy_lifecycle_v3(),
  public.flow_load_production_predictive_overlay_v3(date),
  public.flow_run_gate15_lifecycle_cycle_v3(),
  public.flow_apply_strategy_lifecycle_v2(),
  public.flow_load_production_predictive_overlay_v2(date),
  public.flow_run_gate15_lifecycle_cycle_v2()
  from public,anon,authenticated,service_role;
grant execute on function public.flow_assess_gate15_promotion_v2(),
  public.flow_strategy_global_integrity_v3(),
  public.flow_strategy_lifecycle_decision_v3(text,text,boolean,integer,jsonb),
  public.flow_strategy_post_promotion_monitor_v3(text,timestamptz),
  public.flow_apply_strategy_lifecycle_v3(),
  public.flow_load_production_predictive_overlay_v3(date),
  public.flow_run_gate15_lifecycle_cycle_v3() to service_role;

do $do$
declare r record;
begin
  for r in select jobid from cron.job where jobname in(
    'flow-attribution-forward-outcomes-v1','flow-gate15-lifecycle-retry-v2'
  ) loop perform cron.unschedule(r.jobid); end loop;
  perform cron.schedule('flow-attribution-forward-outcomes-v1','0 12 * * 1-5',
    'select public.flow_run_prospective_stage_v4(''OUTCOMES'',(now() at time zone ''Asia/Jakarta'')::date);');
  perform cron.schedule('flow-gate15-lifecycle-retry-v2','25 12 * * 1-5',
    'select public.flow_run_prospective_stage_v4(''OUTCOMES'',(now() at time zone ''Asia/Jakarta'')::date);');
end
$do$;
