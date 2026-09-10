-- Fully automatic, policy-driven, reversible strategy lifecycle.  Research
-- tables remain shadow-only; production influence lives in this separate,
-- versioned control plane and starts at zero for every real candidate.
create table if not exists public.flow_strategy_lifecycle_policy_v2(
  lifecycle_policy_version text not null,
  gate15_policy_version text not null,
  candidate_id text not null,
  candidate_type text not null check(candidate_type in('DRIVER','INTERACTION')),
  limited_weight numeric not null check(limited_weight>0 and limited_weight<=0.05),
  full_weight numeric not null check(full_weight>=limited_weight and full_weight<=0.10),
  minimum_limited_signal_dates_for_full integer not null,
  minimum_limited_20d_samples_for_full integer not null,
  minimum_limited_60d_samples_for_full integer not null,
  minimum_monitor_signal_dates_for_demotion integer not null,
  minimum_monitor_20d_samples_for_demotion integer not null,
  demotion_minimum_20d_coverage_pct numeric not null,
  demotion_minimum_20d_mean_alpha_pct numeric not null,
  demotion_maximum_20d_adverse_excursion_abs_pct numeric not null,
  overlay_combination_rule text not null,
  full_promotion_rule text not null,
  demotion_rule text not null,
  frozen_at timestamptz not null default statement_timestamp(),
  primary key(lifecycle_policy_version,candidate_id),
  foreign key(gate15_policy_version,candidate_id)
    references public.flow_gate15_promotion_policy_v1(policy_version,candidate_id)
);

create table if not exists public.flow_strategy_lifecycle_state_v2(
  lifecycle_policy_version text not null,
  candidate_id text not null,
  candidate_type text not null,
  promotion_state text not null check(promotion_state in(
    'SHADOW_ONLY','EVIDENCE_ACCUMULATING','READY_FOR_LIMITED_PROMOTION',
    'LIMITED_PRODUCTION','FULL_PRODUCTION','DEGRADED','SUSPENDED','FAIL_CLOSED'
  )),
  previous_state text,
  effective_from date,
  weight numeric not null default 0 check(weight between 0 and 0.10),
  maximum_weight numeric not null check(maximum_weight between 0 and 0.10),
  production_influence_enabled boolean not null default false,
  evidence_snapshot jsonb not null default '{}'::jsonb,
  promotion_reason text not null,
  assessment_timestamp timestamptz not null default statement_timestamp(),
  last_transition_at timestamptz not null default statement_timestamp(),
  primary key(lifecycle_policy_version,candidate_id),
  foreign key(lifecycle_policy_version,candidate_id)
    references public.flow_strategy_lifecycle_policy_v2(lifecycle_policy_version,candidate_id),
  check((promotion_state in('LIMITED_PRODUCTION','FULL_PRODUCTION')
      and production_influence_enabled and weight>0)
    or (promotion_state not in('LIMITED_PRODUCTION','FULL_PRODUCTION')
      and not production_influence_enabled and weight=0))
);

create table if not exists public.flow_strategy_lifecycle_history_v2(
  transition_id uuid primary key default extensions.gen_random_uuid(),
  lifecycle_policy_version text not null,
  candidate_id text not null,
  from_state text,
  to_state text not null,
  previous_weight numeric not null,
  new_weight numeric not null,
  effective_from date,
  evidence_snapshot jsonb not null,
  transition_reason text not null,
  assessed_at timestamptz not null default statement_timestamp(),
  production_influence_enabled boolean not null,
  foreign key(lifecycle_policy_version,candidate_id)
    references public.flow_strategy_lifecycle_policy_v2(lifecycle_policy_version,candidate_id)
);

create index if not exists flow_strategy_lifecycle_state_v2_state_idx
  on public.flow_strategy_lifecycle_state_v2(promotion_state,assessment_timestamp desc);
create index if not exists flow_strategy_lifecycle_history_v2_candidate_idx
  on public.flow_strategy_lifecycle_history_v2(candidate_id,assessed_at desc);

insert into public.flow_strategy_lifecycle_policy_v2(
  lifecycle_policy_version,gate15_policy_version,candidate_id,candidate_type,
  limited_weight,full_weight,minimum_limited_signal_dates_for_full,
  minimum_limited_20d_samples_for_full,minimum_limited_60d_samples_for_full,
  minimum_monitor_signal_dates_for_demotion,minimum_monitor_20d_samples_for_demotion,
  demotion_minimum_20d_coverage_pct,demotion_minimum_20d_mean_alpha_pct,
  demotion_maximum_20d_adverse_excursion_abs_pct,overlay_combination_rule,
  full_promotion_rule,demotion_rule
)
select 'STRATEGY_LIFECYCLE_POLICY_V2',p.policy_version,p.candidate_id,p.candidate_type,
  p.maximum_initial_production_weight,0.10,60,
  p.minimum_sample_size_per_horizon,p.minimum_sample_size_per_horizon,
  10,30,80,0,12,
  'Per ticker use the maximum neutral-centered contribution across promoted candidates. Never sum overlapping candidate weights. LIMITED total influence <=2.5 score points; FULL <=5 score points.',
  'At least 60 independent post-limited signal dates; policy-sized matured 20D and 60D samples; Gate15 assessment still READY; post-limited 20D and 60D mean alpha, coverage, adverse excursion, regime and liquidity gates all pass.',
  p.rollback_rule
from public.flow_gate15_promotion_policy_v1 p
where p.policy_version='GATE15_PROMOTION_POLICY_V1'
on conflict(lifecycle_policy_version,candidate_id) do nothing;

do $do$
begin
  if (select count(*) from public.flow_strategy_lifecycle_policy_v2
      where lifecycle_policy_version='STRATEGY_LIFECYCLE_POLICY_V2')<>13 then
    raise exception 'strategy lifecycle policy must contain FIN_BALANCE plus exactly 12 frozen interactions';
  end if;
end
$do$;

create or replace function public.flow_strategy_lifecycle_decision_v2(
  p_current_state text,p_assessment_state text,p_integrity_ok boolean,
  p_monitor jsonb,p_policy jsonb
)
returns text
language plpgsql
immutable
security invoker
set search_path=''
as $fn$
declare v_dates integer:=coalesce((p_monitor->>'signal_dates')::integer,0);
  v_sample20 integer:=coalesce((p_monitor->>'samples_20d')::integer,0);
  v_sample60 integer:=coalesce((p_monitor->>'samples_60d')::integer,0);
  v_coverage20 numeric:=(p_monitor->>'coverage_20d_pct')::numeric;
  v_coverage60 numeric:=(p_monitor->>'coverage_60d_pct')::numeric;
  v_alpha20 numeric:=(p_monitor->>'mean_alpha_20d_pct')::numeric;
  v_alpha60 numeric:=(p_monitor->>'mean_alpha_60d_pct')::numeric;
  v_adverse20 numeric:=(p_monitor->>'mean_adverse_20d_abs_pct')::numeric;
  v_regime numeric:=(p_monitor->>'regime_consistency_pct')::numeric;
  v_liquidity numeric:=(p_monitor->>'liquidity_consistency_pct')::numeric;
  v_observable boolean;v_degraded boolean;v_full boolean;
begin
  if not coalesce(p_integrity_ok,false) then return 'FAIL_CLOSED'; end if;
  if p_current_state='FAIL_CLOSED' then return 'FAIL_CLOSED'; end if;
  if p_current_state in('SUSPENDED','DEGRADED') then return 'SHADOW_ONLY'; end if;
  if p_current_state in('SHADOW_ONLY','EVIDENCE_ACCUMULATING') then
    if p_assessment_state='READY_FOR_LIMITED_PROMOTION_EXPERIMENT' then
      return 'READY_FOR_LIMITED_PROMOTION';
    end if;
    if coalesce((p_monitor->>'all_signal_dates')::integer,0)>0 then
      return 'EVIDENCE_ACCUMULATING';
    end if;
    return 'SHADOW_ONLY';
  end if;
  if p_current_state='READY_FOR_LIMITED_PROMOTION' then
    if p_assessment_state='READY_FOR_LIMITED_PROMOTION_EXPERIMENT' then
      return 'LIMITED_PRODUCTION';
    end if;
    return 'EVIDENCE_ACCUMULATING';
  end if;

  v_observable:=v_dates>=coalesce((p_policy->>'minimum_monitor_signal_dates_for_demotion')::integer,10)
    and v_sample20>=coalesce((p_policy->>'minimum_monitor_20d_samples_for_demotion')::integer,30);
  v_degraded:=v_observable and(
    p_assessment_state<>'READY_FOR_LIMITED_PROMOTION_EXPERIMENT'
    or v_coverage20 is null or v_coverage20<(p_policy->>'demotion_minimum_20d_coverage_pct')::numeric
    or v_alpha20 is null or v_alpha20<=(p_policy->>'demotion_minimum_20d_mean_alpha_pct')::numeric
    or v_adverse20 is null or v_adverse20>(p_policy->>'demotion_maximum_20d_adverse_excursion_abs_pct')::numeric
    or v_regime is null or v_regime<(p_policy->>'minimum_regime_consistency_pct')::numeric
    or v_liquidity is null or v_liquidity<(p_policy->>'minimum_liquidity_consistency_pct')::numeric
  );
  if p_current_state='FULL_PRODUCTION' and v_degraded then return 'LIMITED_PRODUCTION'; end if;
  if p_current_state='LIMITED_PRODUCTION' and v_degraded then return 'SHADOW_ONLY'; end if;

  v_full:=p_current_state='LIMITED_PRODUCTION'
    and p_assessment_state='READY_FOR_LIMITED_PROMOTION_EXPERIMENT'
    and v_dates>=(p_policy->>'minimum_limited_signal_dates_for_full')::integer
    and v_sample20>=(p_policy->>'minimum_limited_20d_samples_for_full')::integer
    and v_sample60>=(p_policy->>'minimum_limited_60d_samples_for_full')::integer
    and v_coverage20 is not null and v_coverage20>=(p_policy->>'minimum_forward_coverage_pct')::numeric
    and v_coverage60 is not null and v_coverage60>=(p_policy->>'minimum_forward_coverage_pct')::numeric
    and v_alpha20 is not null and v_alpha20>=(p_policy->>'minimum_mean_alpha_20d_pct')::numeric
    and v_alpha60 is not null and v_alpha60>=(p_policy->>'minimum_mean_alpha_60d_pct')::numeric
    and v_adverse20 is not null and v_adverse20<=(p_policy->>'maximum_mean_adverse_20d_abs_pct')::numeric
    and v_regime is not null and v_regime>=(p_policy->>'minimum_regime_consistency_pct')::numeric
    and v_liquidity is not null and v_liquidity>=(p_policy->>'minimum_liquidity_consistency_pct')::numeric;
  if v_full then return 'FULL_PRODUCTION'; end if;
  return p_current_state;
end
$fn$;

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
      'signal_dates',count(distinct c.signal_date) filter(where v_effective is not null and c.signal_date>=v_effective),
      'samples_20d',count(o.ticker) filter(where o.horizon_days=20 and o.outcome_state='MATURED'),
      'samples_60d',count(o.ticker) filter(where o.horizon_days=60 and o.outcome_state='MATURED'),
      'coverage_20d_pct',100.0*count(o.ticker) filter(where o.horizon_days=20 and o.outcome_state='MATURED')
        /nullif(count(*) filter(where h.horizon_days=20 and hdate.target_date is not null),0),
      'coverage_60d_pct',100.0*count(o.ticker) filter(where o.horizon_days=60 and o.outcome_state='MATURED')
        /nullif(count(*) filter(where h.horizon_days=60 and hdate.target_date is not null),0),
      'mean_alpha_20d_pct',avg(o.alpha_vs_ihsg_pct) filter(where o.horizon_days=20 and o.outcome_state='MATURED'),
      'mean_alpha_60d_pct',avg(o.alpha_vs_ihsg_pct) filter(where o.horizon_days=60 and o.outcome_state='MATURED'),
      'mean_adverse_20d_abs_pct',abs(avg(o.max_adverse_excursion_pct)) filter(where o.horizon_days=20 and o.outcome_state='MATURED'),
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

    -- h.target_date above is represented by the lateral alias hdate.
    v_monitor:=jsonb_set(v_monitor,'{signal_dates}',to_jsonb(
      case when v_effective is null then 0 else coalesce((v_monitor->>'signal_dates')::int,0) end));
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
        from public.flow_gate15_promotion_policy_v1 where policy_version=r.gate15_policy_version and candidate_id=r.candidate_id),
      'minimum_mean_alpha_20d_pct',(select minimum_mean_alpha_pct->>'20'
        from public.flow_gate15_promotion_policy_v1 where policy_version=r.gate15_policy_version and candidate_id=r.candidate_id),
      'minimum_mean_alpha_60d_pct',(select minimum_mean_alpha_pct->>'60'
        from public.flow_gate15_promotion_policy_v1 where policy_version=r.gate15_policy_version and candidate_id=r.candidate_id),
      'maximum_mean_adverse_20d_abs_pct',(select maximum_mean_adverse_excursion_abs_pct->>'20'
        from public.flow_gate15_promotion_policy_v1 where policy_version=r.gate15_policy_version and candidate_id=r.candidate_id),
      'minimum_regime_consistency_pct',(select minimum_regime_consistency_pct
        from public.flow_gate15_promotion_policy_v1 where policy_version=r.gate15_policy_version and candidate_id=r.candidate_id),
      'minimum_liquidity_consistency_pct',(select minimum_liquidity_consistency_pct
        from public.flow_gate15_promotion_policy_v1 where policy_version=r.gate15_policy_version and candidate_id=r.candidate_id)
    );
    v_gate:=jsonb_build_object('assessment_state',r.assessment_state,
      'assessment_gate_results',r.gate_results,'monitor',v_monitor,
      'policy',v_policy,'integrity_ok',v_integrity,
      'assessment_result',v_assess_result,'evaluated_at',clock_timestamp());

    -- At most one non-critical transition per date makes duplicate scheduler
    -- executions idempotent. Integrity failure always overrides immediately.
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

    if v_next='LIMITED_PRODUCTION' then v_weight:=r.limited_weight;v_max:=r.limited_weight;
    elsif v_next='FULL_PRODUCTION' then v_weight:=r.full_weight;v_max:=r.full_weight;
    else v_weight:=0;v_max:=case when v_next='READY_FOR_LIMITED_PROMOTION'
      then r.limited_weight else r.full_weight end; end if;

    if v_next is distinct from v_current or v_weight is distinct from v_previous_weight then
      if v_next='LIMITED_PRODUCTION' and v_current='READY_FOR_LIMITED_PROMOTION' then
        select max(signal_date) into v_effective
        from public.flow_attribution_capture_manifest_v1
        where attribution_contract='IDX_PREDICTIVE_ATTRIBUTION_SHADOW_V1'
          and capture_state='CAPTURED';
      elsif v_next not in('LIMITED_PRODUCTION','FULL_PRODUCTION') then v_effective:=null;
      end if;
      insert into public.flow_strategy_lifecycle_history_v2(
        lifecycle_policy_version,candidate_id,from_state,to_state,previous_weight,new_weight,
        effective_from,evidence_snapshot,transition_reason,production_influence_enabled
      ) values(r.lifecycle_policy_version,r.candidate_id,v_current,v_next,v_previous_weight,v_weight,
        v_effective,v_gate,'POLICY_DRIVEN_AUTOMATIC_TRANSITION',
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
    'production_candidates',(select count(*) from public.flow_strategy_lifecycle_state_v2
      where lifecycle_policy_version='STRATEGY_LIFECYCLE_POLICY_V2'
        and production_influence_enabled),
    'production_influence_enabled',(select exists(select 1
      from public.flow_strategy_lifecycle_state_v2
      where lifecycle_policy_version='STRATEGY_LIFECYCLE_POLICY_V2'
        and production_influence_enabled)));
end
$fn$;

create or replace function public.flow_load_production_predictive_overlay_v2(p_signal_date date default null)
returns table(
  signal_date date,ticker text,promotion_state text,candidate_id text,
  predictive_strength numeric,effective_weight numeric,score_adjustment_points numeric,
  lifecycle_policy_version text,production_influence_enabled boolean
)
language sql
stable
security invoker
set search_path=''
as $fn$
with d as(
  select coalesce(p_signal_date,(select max(m.signal_date)
    from public.flow_attribution_capture_manifest_v1 m
    where m.attribution_contract='IDX_PREDICTIVE_ATTRIBUTION_SHADOW_V1'
      and m.capture_state='CAPTURED')) signal_date
), enabled as(
  select s.*
  from public.flow_strategy_lifecycle_state_v2 s
  where s.lifecycle_policy_version='STRATEGY_LIFECYCLE_POLICY_V2'
    and s.promotion_state in('LIMITED_PRODUCTION','FULL_PRODUCTION')
    and s.production_influence_enabled and s.weight>0
), strengths as(
  select d.signal_date,c.ticker,e.promotion_state,e.candidate_id,e.weight,
    case when e.candidate_type='DRIVER' then drv.normalized_value
      else (select min(x.value::numeric) from jsonb_each_text(c.component_percentiles) x) end strength,
    e.lifecycle_policy_version
  from d cross join enabled e
  join public.flow_attribution_prospective_candidate_v1 c
    on c.attribution_contract='IDX_PREDICTIVE_ATTRIBUTION_SHADOW_V1'
    and c.signal_date=d.signal_date and c.candidate_id=e.candidate_id and c.active_signal
  left join public.flow_attribution_prospective_driver_v1 drv
    on e.candidate_type='DRIVER' and drv.attribution_contract=c.attribution_contract
    and drv.signal_date=c.signal_date and drv.ticker=c.ticker and drv.driver_id=e.candidate_id
), ranked as(
  select s.*,greatest(s.weight*(100*s.strength-50),0) adjustment,
    row_number() over(partition by s.signal_date,s.ticker
      order by greatest(s.weight*(100*s.strength-50),0) desc,s.candidate_id) rn
  from strengths s where s.strength is not null
)
select signal_date,ticker,promotion_state,candidate_id,round(strength,6),weight,
  round(adjustment,6),lifecycle_policy_version,true from ranked where rn=1
$fn$;

create or replace function public.flow_run_gate15_lifecycle_cycle_v2()
returns jsonb
language plpgsql
security invoker
set search_path=''
as $fn$
declare v_outcomes jsonb;v_lifecycle jsonb;
begin
  v_outcomes:=public.flow_run_gate15_outcome_cycle_v1();
  v_lifecycle:=public.flow_apply_strategy_lifecycle_v2();
  return jsonb_build_object('status','COMPLETED','outcomes',v_outcomes,
    'strategy_lifecycle',v_lifecycle,
    'production_influence_enabled',coalesce((v_lifecycle->>'production_influence_enabled')::boolean,false));
end
$fn$;

alter table public.flow_strategy_lifecycle_policy_v2 enable row level security;
alter table public.flow_strategy_lifecycle_state_v2 enable row level security;
alter table public.flow_strategy_lifecycle_history_v2 enable row level security;
revoke all on public.flow_strategy_lifecycle_policy_v2,
  public.flow_strategy_lifecycle_state_v2,public.flow_strategy_lifecycle_history_v2
  from public,anon,authenticated,service_role;
grant select on public.flow_strategy_lifecycle_policy_v2,
  public.flow_strategy_lifecycle_state_v2,public.flow_strategy_lifecycle_history_v2
  to service_role;
grant insert,update on public.flow_strategy_lifecycle_state_v2,
  public.flow_strategy_lifecycle_history_v2 to service_role;
revoke all on function public.flow_strategy_lifecycle_decision_v2(text,text,boolean,jsonb,jsonb),
  public.flow_apply_strategy_lifecycle_v2(),
  public.flow_load_production_predictive_overlay_v2(date),
  public.flow_run_gate15_lifecycle_cycle_v2()
  from public,anon,authenticated,service_role;
grant execute on function public.flow_strategy_lifecycle_decision_v2(text,text,boolean,jsonb,jsonb),
  public.flow_apply_strategy_lifecycle_v2(),
  public.flow_load_production_predictive_overlay_v2(date),
  public.flow_run_gate15_lifecycle_cycle_v2() to service_role;

do $do$
declare r record;
begin
  for r in select jobid from cron.job where jobname in(
    'flow-attribution-forward-outcomes-v1','flow-gate15-lifecycle-retry-v2'
  ) loop perform cron.unschedule(r.jobid); end loop;
  perform cron.schedule('flow-attribution-forward-outcomes-v1','0 12 * * 1-5',
    'select public.flow_run_gate15_lifecycle_cycle_v2();');
  perform cron.schedule('flow-gate15-lifecycle-retry-v2','25 12 * * 1-5',
    'select public.flow_run_gate15_lifecycle_cycle_v2();');
end
$do$;
