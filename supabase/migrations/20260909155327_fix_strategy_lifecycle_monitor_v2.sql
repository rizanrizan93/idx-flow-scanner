-- Correct FILTER placement in the policy monitor aggregate.  This follow-up is
-- separate because 20260909100000 is already part of canonical migration history.
create or replace function public.flow_apply_strategy_lifecycle_v2()
returns jsonb
language plpgsql
security invoker
set search_path=''
as $fn$
declare r record;v_current text;v_previous_weight numeric;v_next text;
  v_effective date;v_monitor jsonb;v_policy jsonb;v_integrity boolean;
  v_weight numeric;v_max numeric;v_changed integer:=0;v_assessed integer:=0;
  v_gate jsonb;v_assess_result jsonb;
begin
  v_assess_result:=public.flow_assess_gate15_promotion_v1();
  select
    (select count(*)=13 from public.flow_gate15_promotion_policy_v1
      where policy_version='GATE15_PROMOTION_POLICY_V1'
        and frozen_before_first_matured_outcome and matured_outcomes_at_freeze=0)
    and (select count(*)=13 from public.flow_attribution_forward_registry_v1
      where attribution_contract='IDX_PREDICTIVE_ATTRIBUTION_SHADOW_V1')
    and not exists(select 1 from public.flow_attribution_prospective_driver_v1
      where production_influence_enabled)
    and not exists(select 1 from public.flow_attribution_prospective_candidate_v1
      where production_influence_enabled)
    and not exists(select 1 from public.flow_attribution_forward_outcome_v1
      where production_influence_enabled)
    and exists(select 1 from public.flow_driver_gate12_manifest_v1
      where validation_contract='IDX_DRIVER_PURGED_EXPANDING_WF_V2'
        and gate_state='PASS' and panel_leakage_count=0
        and training_target_overlap_leaks=0)
    and exists(select 1 from public.flow_driver_gate13_manifest_v1
      where validation_contract='IDX_DRIVER_BOUNDED_CONFLUENCE_WF_V2'
        and gate_state='PASS' and target_leakage_count=0 and posthoc_mining_count=0)
    into v_integrity;

  for r in
    select p.*,a.assessment_state,a.independent_signal_dates,a.observed_metrics,
      a.gate_results,a.regime_consistency_pct,a.liquidity_consistency_pct
    from public.flow_strategy_lifecycle_policy_v2 p
    join public.flow_gate15_promotion_assessment_v1 a
      on a.policy_version=p.gate15_policy_version and a.candidate_id=p.candidate_id
    where p.lifecycle_policy_version='STRATEGY_LIFECYCLE_POLICY_V2'
    order by p.candidate_id
  loop
    insert into public.flow_strategy_lifecycle_state_v2(
      lifecycle_policy_version,candidate_id,candidate_type,promotion_state,
      previous_state,weight,maximum_weight,production_influence_enabled,
      evidence_snapshot,promotion_reason
    ) values(r.lifecycle_policy_version,r.candidate_id,r.candidate_type,'SHADOW_ONLY',
      null,0,r.limited_weight,false,'{}','Initialized fail-closed at zero weight.')
    on conflict(lifecycle_policy_version,candidate_id) do nothing;

    select promotion_state,weight,effective_from into v_current,v_previous_weight,v_effective
    from public.flow_strategy_lifecycle_state_v2
    where lifecycle_policy_version=r.lifecycle_policy_version and candidate_id=r.candidate_id
    for update;

    select jsonb_build_object(
      'all_signal_dates',count(distinct c.signal_date),
      'signal_dates',count(distinct c.signal_date)
        filter(where v_effective is not null and c.signal_date>=v_effective),
      'samples_20d',count(o.ticker)
        filter(where o.horizon_days=20 and o.outcome_state='MATURED'),
      'samples_60d',count(o.ticker)
        filter(where o.horizon_days=60 and o.outcome_state='MATURED'),
      'coverage_20d_pct',100.0*count(o.ticker)
        filter(where o.horizon_days=20 and o.outcome_state='MATURED')
        /nullif(count(*) filter(where h.horizon_days=20 and hdate.target_date is not null),0),
      'coverage_60d_pct',100.0*count(o.ticker)
        filter(where o.horizon_days=60 and o.outcome_state='MATURED')
        /nullif(count(*) filter(where h.horizon_days=60 and hdate.target_date is not null),0),
      'mean_alpha_20d_pct',avg(o.alpha_vs_ihsg_pct)
        filter(where o.horizon_days=20 and o.outcome_state='MATURED'),
      'mean_alpha_60d_pct',avg(o.alpha_vs_ihsg_pct)
        filter(where o.horizon_days=60 and o.outcome_state='MATURED'),
      'mean_adverse_20d_abs_pct',abs((avg(o.max_adverse_excursion_pct)
        filter(where o.horizon_days=20 and o.outcome_state='MATURED'))),
      'regime_consistency_pct',r.regime_consistency_pct,
      'liquidity_consistency_pct',r.liquidity_consistency_pct
    ) into v_monitor
    from public.flow_attribution_prospective_candidate_v1 c
    cross join lateral(values(5),(20),(60)) h(horizon_days)
    left join lateral(
      select i.trade_date target_date from public.flow_official_index_summary i
      where i.index_code='COMPOSITE' and i.source_verified and i.trade_date>c.signal_date
      order by i.trade_date offset(h.horizon_days-1) limit 1
    ) hdate on true
    left join public.flow_attribution_forward_outcome_v1 o
      on o.attribution_contract=c.attribution_contract and o.signal_date=c.signal_date
      and o.ticker=c.ticker and o.candidate_id=c.candidate_id
      and o.horizon_days=h.horizon_days
    where c.attribution_contract='IDX_PREDICTIVE_ATTRIBUTION_SHADOW_V1'
      and c.candidate_id=r.candidate_id and c.active_signal
      and (v_effective is null or c.signal_date>=v_effective);

    v_monitor:=jsonb_set(v_monitor,'{signal_dates}',to_jsonb(
      case when v_effective is null then 0
        else coalesce((v_monitor->>'signal_dates')::int,0) end));
    v_policy:=jsonb_build_object(
      'minimum_limited_signal_dates_for_full',r.minimum_limited_signal_dates_for_full,
      'minimum_limited_20d_samples_for_full',r.minimum_limited_20d_samples_for_full,
      'minimum_limited_60d_samples_for_full',r.minimum_limited_60d_samples_for_full,
      'minimum_monitor_signal_dates_for_demotion',r.minimum_monitor_signal_dates_for_demotion,
      'minimum_monitor_20d_samples_for_demotion',r.minimum_monitor_20d_samples_for_demotion,
      'demotion_minimum_20d_coverage_pct',r.demotion_minimum_20d_coverage_pct,
      'demotion_minimum_20d_mean_alpha_pct',r.demotion_minimum_20d_mean_alpha_pct,
      'demotion_maximum_20d_adverse_excursion_abs_pct',r.demotion_maximum_20d_adverse_excursion_abs_pct,
      'minimum_forward_coverage_pct',(select minimum_forward_coverage_pct
        from public.flow_gate15_promotion_policy_v1
        where policy_version=r.gate15_policy_version and candidate_id=r.candidate_id),
      'minimum_mean_alpha_20d_pct',(select minimum_mean_alpha_pct->>'20'
        from public.flow_gate15_promotion_policy_v1
        where policy_version=r.gate15_policy_version and candidate_id=r.candidate_id),
      'minimum_mean_alpha_60d_pct',(select minimum_mean_alpha_pct->>'60'
        from public.flow_gate15_promotion_policy_v1
        where policy_version=r.gate15_policy_version and candidate_id=r.candidate_id),
      'maximum_mean_adverse_20d_abs_pct',(select maximum_mean_adverse_excursion_abs_pct->>'20'
        from public.flow_gate15_promotion_policy_v1
        where policy_version=r.gate15_policy_version and candidate_id=r.candidate_id),
      'minimum_regime_consistency_pct',(select minimum_regime_consistency_pct
        from public.flow_gate15_promotion_policy_v1
        where policy_version=r.gate15_policy_version and candidate_id=r.candidate_id),
      'minimum_liquidity_consistency_pct',(select minimum_liquidity_consistency_pct
        from public.flow_gate15_promotion_policy_v1
        where policy_version=r.gate15_policy_version and candidate_id=r.candidate_id)
    );
    v_gate:=jsonb_build_object('assessment_state',r.assessment_state,
      'assessment_gate_results',r.gate_results,'monitor',v_monitor,
      'policy',v_policy,'integrity_ok',v_integrity,
      'assessment_result',v_assess_result,'evaluated_at',clock_timestamp());

    if not v_integrity then
      v_next:='FAIL_CLOSED';
    elsif not exists(
      select 1 from public.flow_strategy_lifecycle_state_v2 s
      where s.lifecycle_policy_version=r.lifecycle_policy_version
        and s.candidate_id=r.candidate_id and s.last_transition_at::date=current_date
        and s.previous_state is not null
    ) then
      v_next:=public.flow_strategy_lifecycle_decision_v2(
        v_current,r.assessment_state,v_integrity,v_monitor,v_policy);
    else v_next:=v_current; end if;

    if v_next='LIMITED_PRODUCTION' then
      v_weight:=r.limited_weight;v_max:=r.limited_weight;
    elsif v_next='FULL_PRODUCTION' then
      v_weight:=r.full_weight;v_max:=r.full_weight;
    else
      v_weight:=0;v_max:=case when v_next='READY_FOR_LIMITED_PROMOTION'
        then r.limited_weight else r.full_weight end;
    end if;

    if v_next is distinct from v_current or v_weight is distinct from v_previous_weight then
      if v_next='LIMITED_PRODUCTION' and v_current='READY_FOR_LIMITED_PROMOTION' then
        select max(signal_date) into v_effective
        from public.flow_attribution_capture_manifest_v1
        where attribution_contract='IDX_PREDICTIVE_ATTRIBUTION_SHADOW_V1'
          and capture_state='CAPTURED';
      elsif v_next not in('LIMITED_PRODUCTION','FULL_PRODUCTION') then
        v_effective:=null;
      end if;
      insert into public.flow_strategy_lifecycle_history_v2(
        lifecycle_policy_version,candidate_id,from_state,to_state,previous_weight,new_weight,
        effective_from,evidence_snapshot,transition_reason,production_influence_enabled
      ) values(r.lifecycle_policy_version,r.candidate_id,v_current,v_next,
        v_previous_weight,v_weight,v_effective,v_gate,
        'POLICY_DRIVEN_AUTOMATIC_TRANSITION',
        v_next in('LIMITED_PRODUCTION','FULL_PRODUCTION'));
      update public.flow_strategy_lifecycle_state_v2 set previous_state=v_current,
        promotion_state=v_next,effective_from=v_effective,weight=v_weight,
        maximum_weight=v_max,production_influence_enabled=
          v_next in('LIMITED_PRODUCTION','FULL_PRODUCTION'),
        evidence_snapshot=v_gate,promotion_reason='POLICY_DRIVEN_AUTOMATIC_TRANSITION',
        assessment_timestamp=statement_timestamp(),last_transition_at=statement_timestamp()
      where lifecycle_policy_version=r.lifecycle_policy_version and candidate_id=r.candidate_id;
      v_changed:=v_changed+1;
    else
      update public.flow_strategy_lifecycle_state_v2 set evidence_snapshot=v_gate,
        assessment_timestamp=statement_timestamp()
      where lifecycle_policy_version=r.lifecycle_policy_version and candidate_id=r.candidate_id;
    end if;
    v_assessed:=v_assessed+1;
  end loop;
  return jsonb_build_object('status','COMPLETED','assessed_candidates',v_assessed,
    'state_changes',v_changed,'integrity_ok',v_integrity,
    'production_candidates',(select count(*)
      from public.flow_strategy_lifecycle_state_v2
      where lifecycle_policy_version='STRATEGY_LIFECYCLE_POLICY_V2'
        and production_influence_enabled),
    'production_influence_enabled',(select exists(select 1
      from public.flow_strategy_lifecycle_state_v2
      where lifecycle_policy_version='STRATEGY_LIFECYCLE_POLICY_V2'
        and production_influence_enabled)));
end
$fn$;

revoke all on function public.flow_apply_strategy_lifecycle_v2()
  from public,anon,authenticated,service_role;
grant execute on function public.flow_apply_strategy_lifecycle_v2() to service_role;
