-- Gate 15 shadow predictive model and preregistered promotion boundary.
alter table public.flow_attribution_forward_outcome_v1
  add column if not exists max_favorable_excursion_pct numeric,
  add column if not exists max_adverse_excursion_pct numeric;

create table if not exists public.flow_gate15_promotion_policy_v1(
  policy_version text not null,
  candidate_id text not null,
  candidate_type text not null check(candidate_type in ('DRIVER','INTERACTION')),
  minimum_sample_size_per_horizon integer not null,
  minimum_independent_signal_dates integer not null,
  minimum_forward_coverage_pct numeric not null,
  minimum_mean_alpha_pct jsonb not null,
  minimum_median_alpha_pct jsonb not null,
  minimum_direction_agreement_pct numeric not null,
  minimum_positive_horizons integer not null,
  required_heldout_forward_behavior text not null,
  minimum_rank_ic numeric,
  minimum_regime_consistency_pct numeric not null,
  minimum_liquidity_consistency_pct numeric not null,
  minimum_incremental_lift_pct jsonb not null,
  maximum_mean_adverse_excursion_abs_pct jsonb not null,
  maximum_initial_production_weight numeric not null check(maximum_initial_production_weight between 0 and 0.05),
  rollback_rule text not null,
  frozen_before_first_matured_outcome boolean not null check(frozen_before_first_matured_outcome),
  matured_outcomes_at_freeze integer not null check(matured_outcomes_at_freeze=0),
  frozen_at timestamptz not null default statement_timestamp(),
  production_influence_enabled boolean not null default false check(production_influence_enabled=false),
  primary key(policy_version,candidate_id)
);

create table if not exists public.flow_shadow_predictive_model_policy_v1(
  model_contract text primary key,
  attribution_contract text not null,
  universe_contract text not null,
  component_weights jsonb not null,
  reliability_multipliers jsonb not null,
  coverage_rule text not null,
  tradeability_rule text not null,
  interaction_rule text not null,
  frozen_at timestamptz not null default statement_timestamp(),
  production_influence_enabled boolean not null default false check(production_influence_enabled=false)
);

create table if not exists public.flow_shadow_predictive_score_v1(
  model_contract text not null,
  signal_date date not null,
  ticker text not null,
  universe_rank integer not null,
  current_tradeable boolean not null,
  production_actionable boolean not null,
  base_close numeric,
  base_ihsg_close numeric,
  component_strength_score numeric,
  reliability_adjusted_score numeric,
  evidence_coverage_pct numeric not null,
  tradeability_multiplier numeric not null,
  shadow_predictive_score numeric,
  shadow_rank integer not null,
  production_final_score numeric,
  production_rank integer,
  rank_displacement integer,
  active_interactions text[] not null default '{}'::text[],
  timing_quality text not null check(timing_quality in ('EARLY','IDEAL','EXTENDED','WAIT_PULLBACK','INVALID')),
  model_state text not null default 'UNCONFIRMED_SHADOW_ONLY'
    check(model_state='UNCONFIRMED_SHADOW_ONLY'),
  captured_at timestamptz not null default statement_timestamp(),
  production_influence_enabled boolean not null default false check(production_influence_enabled=false),
  primary key(model_contract,signal_date,ticker)
);

create table if not exists public.flow_shadow_rank_forward_outcome_v1(
  model_contract text not null,
  signal_date date not null,
  ticker text not null,
  shadow_rank integer not null,
  horizon_days integer not null check(horizon_days in (5,20,60)),
  target_date date not null,
  forward_return_pct numeric,
  ihsg_return_pct numeric,
  alpha_vs_ihsg_pct numeric,
  max_favorable_excursion_pct numeric,
  max_adverse_excursion_pct numeric,
  outcome_state text not null,
  calculated_at timestamptz not null default statement_timestamp(),
  production_influence_enabled boolean not null default false check(production_influence_enabled=false),
  primary key(model_contract,signal_date,ticker,horizon_days)
);

create table if not exists public.flow_component_forward_outcome_diagnostic_v1(
  attribution_contract text not null,
  signal_date date not null,
  ticker text not null,
  driver_id text not null,
  horizon_days integer not null check(horizon_days in (5,20,60)),
  target_date date not null,
  alpha_vs_ihsg_pct numeric,
  outcome_state text not null,
  calculated_at timestamptz not null default statement_timestamp(),
  production_influence_enabled boolean not null default false check(production_influence_enabled=false),
  primary key(attribution_contract,signal_date,ticker,driver_id,horizon_days)
);

create table if not exists public.flow_shadow_predictive_evaluation_v1(
  model_contract text not null,
  signal_date date not null,
  horizon_days integer not null check(horizon_days in (5,20,60)),
  shadow_universe_count integer not null,
  production_comparable_count integer not null,
  top10_overlap_count integer,
  top10_overlap_pct numeric,
  top20_overlap_count integer,
  top20_overlap_pct numeric,
  mean_absolute_rank_displacement numeric,
  matured_sample_count integer not null,
  mean_alpha_pct numeric,
  median_alpha_pct numeric,
  hit_rate_pct numeric,
  mean_max_favorable_excursion_pct numeric,
  mean_max_adverse_excursion_pct numeric,
  active_liquidity_top20_pct numeric,
  maximum_sector_concentration_top20_pct numeric,
  top20_turnover_pct numeric,
  false_positive_rate_pct numeric,
  false_negative_candidate_count integer,
  ideal_timing_hit_rate_pct numeric,
  thesis_failure_rate_pct numeric,
  calculated_at timestamptz not null default statement_timestamp(),
  production_influence_enabled boolean not null default false check(production_influence_enabled=false),
  primary key(model_contract,signal_date,horizon_days)
);

create table if not exists public.flow_gate15_promotion_assessment_v1(
  policy_version text not null,
  candidate_id text not null,
  assessment_state text not null check(assessment_state in (
    'INSUFFICIENT_EVIDENCE','CONTINUE_SHADOW','READY_FOR_LIMITED_PROMOTION_EXPERIMENT','ROLLBACK_REQUIRED'
  )),
  independent_signal_dates integer not null,
  minimum_matured_sample_across_horizons integer not null,
  minimum_observed_coverage_pct numeric,
  positive_horizons integer not null,
  direction_agreement_pct numeric,
  minimum_observed_rank_ic numeric,
  regime_consistency_pct numeric,
  liquidity_consistency_pct numeric,
  maximum_mean_adverse_excursion_abs_pct numeric,
  minimum_incremental_lift_pct numeric,
  observed_metrics jsonb not null,
  gate_results jsonb not null,
  assessed_at timestamptz not null default statement_timestamp(),
  production_influence_enabled boolean not null default false check(production_influence_enabled=false),
  primary key(policy_version,candidate_id)
);

insert into public.flow_gate15_promotion_policy_v1(
  policy_version,candidate_id,candidate_type,minimum_sample_size_per_horizon,
  minimum_independent_signal_dates,minimum_forward_coverage_pct,minimum_mean_alpha_pct,
  minimum_median_alpha_pct,minimum_direction_agreement_pct,minimum_positive_horizons,
  required_heldout_forward_behavior,minimum_rank_ic,minimum_regime_consistency_pct,
  minimum_liquidity_consistency_pct,minimum_incremental_lift_pct,
  maximum_mean_adverse_excursion_abs_pct,maximum_initial_production_weight,rollback_rule,
  frozen_before_first_matured_outcome,matured_outcomes_at_freeze,production_influence_enabled
) values(
  'GATE15_PROMOTION_POLICY_V1','FIN_BALANCE','DRIVER',500,20,90,
  '{"5":0.25,"20":0.75,"60":1.50}'::jsonb,
  '{"5":0.00,"20":0.25,"60":0.50}'::jsonb,66.67,3,
  'Gate12 heldout and forward alpha must both remain positive; discovery replay is not independent confirmation.',
  0.02,60,60,'{"5":0.00,"20":0.00,"60":0.00}'::jsonb,
  '{"5":6.0,"20":10.0,"60":15.0}'::jsonb,0.05,
  'Rollback limited experiment if rolling 20D mean alpha is non-positive after 10 independent dates, coverage falls below 80%, 20D mean adverse excursion exceeds 12%, any leakage/integrity breach appears, or production behavior diverges from the frozen shadow contract.',
  true,(select count(*) from public.flow_attribution_forward_outcome_v1),false
) on conflict(policy_version,candidate_id) do nothing;

insert into public.flow_gate15_promotion_policy_v1(
  policy_version,candidate_id,candidate_type,minimum_sample_size_per_horizon,
  minimum_independent_signal_dates,minimum_forward_coverage_pct,minimum_mean_alpha_pct,
  minimum_median_alpha_pct,minimum_direction_agreement_pct,minimum_positive_horizons,
  required_heldout_forward_behavior,minimum_rank_ic,minimum_regime_consistency_pct,
  minimum_liquidity_consistency_pct,minimum_incremental_lift_pct,
  maximum_mean_adverse_excursion_abs_pct,maximum_initial_production_weight,rollback_rule,
  frozen_before_first_matured_outcome,matured_outcomes_at_freeze,production_influence_enabled
)
select 'GATE15_PROMOTION_POLICY_V1',f.candidate_id,'INTERACTION',r.minimum_sample_size,20,85,
  '{"5":0.25,"20":0.75,"60":1.50}'::jsonb,
  '{"5":0.00,"20":0.25,"60":0.50}'::jsonb,66.67,3,
  'Gate13 heldout and forward incremental lift must both be measured and positive; missing sector, regime, liquidity, or robustness fails closed.',
  0.02,60,60,'{"5":0.25,"20":0.50,"60":1.00}'::jsonb,
  '{"5":6.0,"20":10.0,"60":15.0}'::jsonb,0.05,
  'Rollback limited experiment if rolling 20D incremental lift is non-positive after 10 independent dates, coverage falls below 80%, 20D mean adverse excursion exceeds 12%, any leakage/integrity breach appears, or production behavior diverges from the frozen shadow contract.',
  true,(select count(*) from public.flow_attribution_forward_outcome_v1),false
from public.flow_attribution_forward_registry_v1 f
join public.flow_driver_interaction_registry_v1 r
  on r.registry_version='IDX_DRIVER_REGISTRY_GATE10_V2' and r.interaction_id=f.candidate_id
where f.attribution_contract='IDX_PREDICTIVE_ATTRIBUTION_SHADOW_V1'
  and f.candidate_type='INTERACTION'
on conflict(policy_version,candidate_id) do nothing;

do $do$
begin
  if (select count(*) from public.flow_gate15_promotion_policy_v1
      where policy_version='GATE15_PROMOTION_POLICY_V1') <> 13 then
    raise exception 'GATE15_PROMOTION_POLICY_V1 must contain FIN_BALANCE plus exactly 12 frozen interactions';
  end if;
  if (select count(*) from public.flow_gate15_promotion_policy_v1
      where policy_version='GATE15_PROMOTION_POLICY_V1' and candidate_type='INTERACTION') <> 12 then
    raise exception 'GATE15_PROMOTION_POLICY_V1 interaction cohort must remain exactly 12';
  end if;
end
$do$;

insert into public.flow_shadow_predictive_model_policy_v1(
  model_contract,attribution_contract,universe_contract,component_weights,
  reliability_multipliers,coverage_rule,tradeability_rule,interaction_rule,
  production_influence_enabled
) values(
  'SHADOW_PREDICTIVE_SCORE_V1','IDX_PREDICTIVE_ATTRIBUTION_SHADOW_V1','TOP_900_UNIVERSE_V1',
  '{"FIN_BALANCE":0.50,"FLOW_FOREIGN_ACCUMULATION":0.20,"TECH_TREND_STRUCTURE":0.15,"PV_PRICE_VOLUME_CONFIRMATION":0.10,"MKT_SECTOR_RELATIVE_STRENGTH_20D":0.05}'::jsonb,
  '{"VALIDATED":1.00,"PROMISING_UNCONFIRMED":0.50,"WEAK":0.00,"UNSTABLE":0.00,"UNVALIDATED":0.00,"MISSING":0.00}'::jsonb,
  'Score is multiplied by AVAILABLE component count divided by five; zero reliable weight returns NULL, never a neutral zero.',
  'Multiplier is 1.00 production-actionable, 0.90 currently-tradeable, 0.50 research-only.',
  'The exactly 12 frozen interactions are displayed and evaluated but receive zero model weight until independently promoted under GATE15_PROMOTION_POLICY_V1.',
  false
) on conflict(model_contract) do nothing;

create index if not exists flow_shadow_predictive_score_v1_rank_idx
  on public.flow_shadow_predictive_score_v1(signal_date desc,shadow_rank);
create index if not exists flow_shadow_rank_outcome_v1_horizon_idx
  on public.flow_shadow_rank_forward_outcome_v1(horizon_days,target_date,shadow_rank);
create index if not exists flow_component_outcome_v1_driver_idx
  on public.flow_component_forward_outcome_diagnostic_v1(driver_id,horizon_days,target_date);
create index if not exists flow_gate15_assessment_v1_state_idx
  on public.flow_gate15_promotion_assessment_v1(assessment_state,assessed_at desc);

create or replace function public.flow_capture_shadow_predictive_score_v1(p_signal_date date)
returns jsonb
language plpgsql
security invoker
set search_path=''
set work_mem='48MB'
as $fn$
declare
  v_model text := 'SHADOW_PREDICTIVE_SCORE_V1';
  v_attr text := 'IDX_PREDICTIVE_ATTRIBUTION_SHADOW_V1';
  v_rows integer := 0;
begin
  if not exists(
    select 1 from public.flow_attribution_structured_snapshot_v2
    where attribution_contract='IDX_STRUCTURED_ATTRIBUTION_SHADOW_V2'
      and signal_date=p_signal_date
  ) then
    return jsonb_build_object('status','SOURCE_NOT_READY','signal_date',p_signal_date,
      'rows',0,'production_influence_enabled',false);
  end if;

  delete from public.flow_shadow_predictive_score_v1
  where model_contract=v_model and signal_date=p_signal_date;

  with u as (
    select * from public.flow_universe_snapshot_v1
    where universe_contract='TOP_900_UNIVERSE_V1' and snapshot_date=p_signal_date and selected_top900
  ), driver as (
    select u.ticker,u.universe_rank,u.current_tradeable,u.production_actionable,
      d.driver_id,d.normalized_value,d.driver_state,
      case d.driver_id when 'FIN_BALANCE' then 0.50
        when 'FLOW_FOREIGN_ACCUMULATION' then 0.20
        when 'TECH_TREND_STRUCTURE' then 0.15
        when 'PV_PRICE_VOLUME_CONFIRMATION' then 0.10
        when 'MKT_SECTOR_RELATIVE_STRENGTH_20D' then 0.05 else 0 end weight,
      case when coalesce(o.eligible_to_enter_phase2,false) then 1.00
        when o.classification='PROMISING' then 0.50 else 0.00 end reliability,
      case when d.driver_id='TECH_TREND_STRUCTURE' then d.normalized_value end technical_percentile
    from u left join public.flow_attribution_prospective_driver_v1 d
      on d.attribution_contract=v_attr and d.signal_date=p_signal_date and d.ticker=u.ticker
    left join public.flow_driver_oos_summary_v1 o
      on o.validation_contract='IDX_DRIVER_PURGED_EXPANDING_WF_V2' and o.driver_id=d.driver_id
  ), agg as (
    select ticker,max(universe_rank) universe_rank,bool_or(current_tradeable) current_tradeable,
      bool_or(production_actionable) production_actionable,
      100.0*sum(weight*normalized_value) filter(where driver_state='AVAILABLE' and normalized_value is not null)
        /nullif(sum(weight) filter(where driver_state='AVAILABLE' and normalized_value is not null),0) component_score,
      100.0*sum(weight*reliability*normalized_value) filter(where driver_state='AVAILABLE' and normalized_value is not null)
        /nullif(sum(weight*reliability) filter(where driver_state='AVAILABLE' and normalized_value is not null),0) reliability_score,
      100.0*count(*) filter(where driver_state='AVAILABLE' and normalized_value is not null)/5.0 coverage_pct,
      max(technical_percentile) technical_percentile
    from driver group by ticker
  ), base as (
    select ticker,max(base_close) base_close,max(base_ihsg_close) base_ihsg_close
    from public.flow_attribution_prospective_candidate_v1
    where attribution_contract=v_attr and signal_date=p_signal_date group by ticker
  ), ints as (
    select ticker,array_agg(candidate_id order by candidate_id) active_interactions
    from public.flow_attribution_prospective_candidate_v1
    where attribution_contract=v_attr and signal_date=p_signal_date
      and candidate_type='INTERACTION' and active_signal group by ticker
  ), prod_latest as (
    select distinct on(ticker) ticker,final_score
    from public.flow_scan_results where as_of_date=p_signal_date
    order by ticker,created_at desc
  ), prod as (
    select ticker,final_score,
      row_number() over(order by final_score desc,ticker)::int production_rank
    from prod_latest
  ), scored as (
    select a.*,b.base_close,b.base_ihsg_close,coalesce(i.active_interactions,'{}'::text[]) active_interactions,
      case when a.production_actionable then 1.00 when a.current_tradeable then 0.90 else 0.50 end trade_mult,
      case when a.reliability_score is null then null
           else a.reliability_score*(a.coverage_pct/100.0)*
             case when a.production_actionable then 1.00 when a.current_tradeable then 0.90 else 0.50 end
      end shadow_score
    from agg a left join base b using(ticker) left join ints i using(ticker)
  ), ranked as (
    select s.*,row_number() over(order by shadow_score desc nulls last,ticker)::int shadow_rank
    from scored s
  )
  insert into public.flow_shadow_predictive_score_v1(
    model_contract,signal_date,ticker,universe_rank,current_tradeable,production_actionable,
    base_close,base_ihsg_close,component_strength_score,reliability_adjusted_score,
    evidence_coverage_pct,tradeability_multiplier,shadow_predictive_score,shadow_rank,
    production_final_score,production_rank,rank_displacement,active_interactions,
    timing_quality,model_state,production_influence_enabled
  )
  select v_model,p_signal_date,r.ticker,r.universe_rank,r.current_tradeable,r.production_actionable,
    r.base_close,r.base_ihsg_close,round(r.component_score,6),round(r.reliability_score,6),
    round(r.coverage_pct,2),r.trade_mult,round(r.shadow_score,6),r.shadow_rank,
    p.final_score,p.production_rank,
    case when p.production_rank is null then null else r.shadow_rank-p.production_rank end,
    r.active_interactions,
    case when not r.current_tradeable or r.technical_percentile is null then 'INVALID'
         when r.technical_percentile>=0.95 then 'EXTENDED'
         when r.technical_percentile>=0.80 then 'IDEAL'
         when r.technical_percentile>=0.65 then 'EARLY'
         else 'WAIT_PULLBACK' end,
    'UNCONFIRMED_SHADOW_ONLY',false
  from ranked r left join prod p using(ticker);

  get diagnostics v_rows = row_count;
  return jsonb_build_object('status','CAPTURED','model_contract',v_model,
    'signal_date',p_signal_date,'rows',v_rows,'production_influence_enabled',false);
end
$fn$;

create or replace function public.flow_enrich_attribution_excursions_v1()
returns integer
language plpgsql
security invoker
set search_path=''
as $fn$
declare v_rows integer := 0;
begin
  with path as (
    select o.attribution_contract,o.signal_date,o.ticker,o.candidate_id,o.horizon_days,
      max(s.high) max_high,min(s.low) min_low,max(c.base_close) base_close
    from public.flow_attribution_forward_outcome_v1 o
    join public.flow_attribution_prospective_candidate_v1 c
      on c.attribution_contract=o.attribution_contract and c.signal_date=o.signal_date
      and c.ticker=o.ticker and c.candidate_id=o.candidate_id
    join public.flow_official_stock_summary s
      on s.ticker=o.ticker and s.source_verified and s.trade_date>o.signal_date
      and s.trade_date<=o.target_date
    where o.outcome_state='MATURED'
      and (o.max_favorable_excursion_pct is null or o.max_adverse_excursion_pct is null)
    group by o.attribution_contract,o.signal_date,o.ticker,o.candidate_id,o.horizon_days
  )
  update public.flow_attribution_forward_outcome_v1 o set
    max_favorable_excursion_pct=100.0*(p.max_high/p.base_close-1),
    max_adverse_excursion_pct=100.0*(p.min_low/p.base_close-1),
    calculated_at=statement_timestamp()
  from path p
  where o.attribution_contract=p.attribution_contract and o.signal_date=p.signal_date
    and o.ticker=p.ticker and o.candidate_id=p.candidate_id
    and o.horizon_days=p.horizon_days and p.base_close>0;
  get diagnostics v_rows = row_count;
  return v_rows;
end
$fn$;

create or replace function public.flow_evaluate_shadow_predictive_outcomes_v1()
returns jsonb
language plpgsql
security invoker
set search_path=''
set work_mem='48MB'
as $fn$
declare v_rank integer := 0; v_component integer := 0;
begin
  with expanded as (
    select s.*,h.horizon_days
    from public.flow_shadow_predictive_score_v1 s
    cross join (values(5),(20),(60)) h(horizon_days)
  ), target as (
    select e.*,(select i.trade_date from public.flow_official_index_summary i
      where i.index_code='COMPOSITE' and i.source_verified and i.trade_date>e.signal_date
      order by i.trade_date offset(e.horizon_days-1) limit 1) target_date
    from expanded e
  ), outcome as (
    select t.*,ss.close target_close,ii.close target_ihsg_close,p.max_high,p.min_low
    from target t
    join public.flow_official_stock_summary ss
      on ss.ticker=t.ticker and ss.trade_date=t.target_date and ss.source_verified
    join public.flow_official_index_summary ii
      on ii.index_code='COMPOSITE' and ii.trade_date=t.target_date and ii.source_verified
    left join lateral(
      select max(x.high) max_high,min(x.low) min_low
      from public.flow_official_stock_summary x
      where x.ticker=t.ticker and x.source_verified and x.trade_date>t.signal_date
        and x.trade_date<=t.target_date
    ) p on true
    where t.target_date is not null and t.base_close>0 and t.base_ihsg_close>0
  )
  insert into public.flow_shadow_rank_forward_outcome_v1(
    model_contract,signal_date,ticker,shadow_rank,horizon_days,target_date,
    forward_return_pct,ihsg_return_pct,alpha_vs_ihsg_pct,max_favorable_excursion_pct,
    max_adverse_excursion_pct,outcome_state,production_influence_enabled
  )
  select model_contract,signal_date,ticker,shadow_rank,horizon_days,target_date,
    100.0*(target_close/base_close-1),100.0*(target_ihsg_close/base_ihsg_close-1),
    100.0*(target_close/base_close-1)-100.0*(target_ihsg_close/base_ihsg_close-1),
    100.0*(max_high/base_close-1),100.0*(min_low/base_close-1),'MATURED',false
  from outcome
  on conflict(model_contract,signal_date,ticker,horizon_days) do nothing;
  get diagnostics v_rank = row_count;

  with active_component as (
    select d.attribution_contract,d.signal_date,d.ticker,d.driver_id,
      s.base_close,s.base_ihsg_close,h.horizon_days
    from public.flow_attribution_prospective_driver_v1 d
    join public.flow_shadow_predictive_score_v1 s
      on s.signal_date=d.signal_date and s.ticker=d.ticker
      and s.model_contract='SHADOW_PREDICTIVE_SCORE_V1'
    cross join (values(5),(20),(60)) h(horizon_days)
    where d.attribution_contract='IDX_PREDICTIVE_ATTRIBUTION_SHADOW_V1'
      and d.driver_state='AVAILABLE' and d.normalized_value>=0.80
  ), target as (
    select a.*,(select i.trade_date from public.flow_official_index_summary i
      where i.index_code='COMPOSITE' and i.source_verified and i.trade_date>a.signal_date
      order by i.trade_date offset(a.horizon_days-1) limit 1) target_date
    from active_component a
  ), outcome as (
    select t.*,ss.close target_close,ii.close target_ihsg_close
    from target t
    join public.flow_official_stock_summary ss
      on ss.ticker=t.ticker and ss.trade_date=t.target_date and ss.source_verified
    join public.flow_official_index_summary ii
      on ii.index_code='COMPOSITE' and ii.trade_date=t.target_date and ii.source_verified
    where t.target_date is not null and t.base_close>0 and t.base_ihsg_close>0
  )
  insert into public.flow_component_forward_outcome_diagnostic_v1(
    attribution_contract,signal_date,ticker,driver_id,horizon_days,target_date,
    alpha_vs_ihsg_pct,outcome_state,production_influence_enabled
  )
  select attribution_contract,signal_date,ticker,driver_id,horizon_days,target_date,
    100.0*(target_close/base_close-1)-100.0*(target_ihsg_close/base_ihsg_close-1),
    'MATURED',false
  from outcome
  on conflict(attribution_contract,signal_date,ticker,driver_id,horizon_days) do nothing;
  get diagnostics v_component = row_count;

  return jsonb_build_object('status','OK','new_rank_outcomes',v_rank,
    'new_component_diagnostics',v_component,'production_influence_enabled',false);
end
$fn$;

create or replace function public.flow_refresh_shadow_predictive_evaluation_v1()
returns jsonb
language plpgsql
security invoker
set search_path=''
as $fn$
declare v_rows integer := 0;
begin
  with keys as (
    select distinct model_contract,signal_date,h.horizon_days
    from public.flow_shadow_predictive_score_v1
    cross join (values(5),(20),(60)) h(horizon_days)
  )
  insert into public.flow_shadow_predictive_evaluation_v1(
    model_contract,signal_date,horizon_days,shadow_universe_count,production_comparable_count,
    top10_overlap_count,top10_overlap_pct,top20_overlap_count,top20_overlap_pct,
    mean_absolute_rank_displacement,matured_sample_count,mean_alpha_pct,median_alpha_pct,
    hit_rate_pct,mean_max_favorable_excursion_pct,mean_max_adverse_excursion_pct,
    active_liquidity_top20_pct,maximum_sector_concentration_top20_pct,top20_turnover_pct,
    false_positive_rate_pct,false_negative_candidate_count,ideal_timing_hit_rate_pct,
    thesis_failure_rate_pct,production_influence_enabled
  )
  select k.model_contract,k.signal_date,k.horizon_days,
    (select count(*) from public.flow_shadow_predictive_score_v1 s
      where s.model_contract=k.model_contract and s.signal_date=k.signal_date),
    (select count(*) from public.flow_shadow_predictive_score_v1 s
      where s.model_contract=k.model_contract and s.signal_date=k.signal_date and s.production_rank is not null),
    (select count(*) from public.flow_shadow_predictive_score_v1 s
      where s.model_contract=k.model_contract and s.signal_date=k.signal_date
        and s.shadow_rank<=10 and s.production_rank<=10),
    (select 100.0*count(*) filter(where s.production_rank<=10)
      /nullif(count(*) filter(where s.production_rank is not null),0)
      from public.flow_shadow_predictive_score_v1 s
      where s.model_contract=k.model_contract and s.signal_date=k.signal_date and s.shadow_rank<=10),
    (select count(*) from public.flow_shadow_predictive_score_v1 s
      where s.model_contract=k.model_contract and s.signal_date=k.signal_date
        and s.shadow_rank<=20 and s.production_rank<=20),
    (select 100.0*count(*) filter(where s.production_rank<=20)
      /nullif(count(*) filter(where s.production_rank is not null),0)
      from public.flow_shadow_predictive_score_v1 s
      where s.model_contract=k.model_contract and s.signal_date=k.signal_date and s.shadow_rank<=20),
    (select avg(abs(s.rank_displacement)) from public.flow_shadow_predictive_score_v1 s
      where s.model_contract=k.model_contract and s.signal_date=k.signal_date and s.production_rank is not null),
    (select count(*) from public.flow_shadow_rank_forward_outcome_v1 o
      where o.model_contract=k.model_contract and o.signal_date=k.signal_date
        and o.horizon_days=k.horizon_days and o.shadow_rank<=20 and o.outcome_state='MATURED'),
    (select avg(o.alpha_vs_ihsg_pct) from public.flow_shadow_rank_forward_outcome_v1 o
      where o.model_contract=k.model_contract and o.signal_date=k.signal_date
        and o.horizon_days=k.horizon_days and o.shadow_rank<=20 and o.outcome_state='MATURED'),
    (select percentile_cont(0.5) within group(order by o.alpha_vs_ihsg_pct)
      from public.flow_shadow_rank_forward_outcome_v1 o
      where o.model_contract=k.model_contract and o.signal_date=k.signal_date
        and o.horizon_days=k.horizon_days and o.shadow_rank<=20 and o.outcome_state='MATURED'),
    (select 100.0*count(*) filter(where o.alpha_vs_ihsg_pct>0)/nullif(count(*),0)
      from public.flow_shadow_rank_forward_outcome_v1 o
      where o.model_contract=k.model_contract and o.signal_date=k.signal_date
        and o.horizon_days=k.horizon_days and o.shadow_rank<=20 and o.outcome_state='MATURED'),
    (select avg(o.max_favorable_excursion_pct) from public.flow_shadow_rank_forward_outcome_v1 o
      where o.model_contract=k.model_contract and o.signal_date=k.signal_date
        and o.horizon_days=k.horizon_days and o.shadow_rank<=20 and o.outcome_state='MATURED'),
    (select avg(o.max_adverse_excursion_pct) from public.flow_shadow_rank_forward_outcome_v1 o
      where o.model_contract=k.model_contract and o.signal_date=k.signal_date
        and o.horizon_days=k.horizon_days and o.shadow_rank<=20 and o.outcome_state='MATURED'),
    (select 100.0*count(*) filter(where u.liquidity_state='ACTIVE_60D')/nullif(count(*),0)
      from public.flow_shadow_predictive_score_v1 s
      join public.flow_universe_snapshot_v1 u
        on u.universe_contract='TOP_900_UNIVERSE_V1' and u.snapshot_date=s.signal_date and u.ticker=s.ticker
      where s.model_contract=k.model_contract and s.signal_date=k.signal_date and s.shadow_rank<=20),
    (select 100.0*max(x.n)/nullif(sum(x.n),0) from (
      select u.sector,count(*) n
      from public.flow_shadow_predictive_score_v1 s
      join public.flow_universe_snapshot_v1 u
        on u.universe_contract='TOP_900_UNIVERSE_V1' and u.snapshot_date=s.signal_date and u.ticker=s.ticker
      where s.model_contract=k.model_contract and s.signal_date=k.signal_date and s.shadow_rank<=20
      group by u.sector
    ) x),
    (case when not exists(
        select 1 from public.flow_shadow_predictive_score_v1 z
        where z.model_contract=k.model_contract and z.signal_date<k.signal_date
      ) then null else (
        select 100.0*(1.0-count(*)/20.0)
        from public.flow_shadow_predictive_score_v1 s
        where s.model_contract=k.model_contract and s.signal_date=k.signal_date and s.shadow_rank<=20
          and exists(select 1 from public.flow_shadow_predictive_score_v1 p
            where p.model_contract=s.model_contract and p.ticker=s.ticker and p.shadow_rank<=20
              and p.signal_date=(select max(z.signal_date) from public.flow_shadow_predictive_score_v1 z
                where z.model_contract=s.model_contract and z.signal_date<s.signal_date))
      ) end),
    (select 100.0*count(*) filter(where o.alpha_vs_ihsg_pct<=0)/nullif(count(*),0)
      from public.flow_shadow_rank_forward_outcome_v1 o
      where o.model_contract=k.model_contract and o.signal_date=k.signal_date
        and o.horizon_days=k.horizon_days and o.shadow_rank<=20 and o.outcome_state='MATURED'),
    (select count(*) from public.flow_shadow_rank_forward_outcome_v1 o
      where o.model_contract=k.model_contract and o.signal_date=k.signal_date
        and o.horizon_days=k.horizon_days and o.shadow_rank>20
        and o.alpha_vs_ihsg_pct>0 and o.outcome_state='MATURED'),
    (select 100.0*count(*) filter(where o.alpha_vs_ihsg_pct>0)/nullif(count(*),0)
      from public.flow_shadow_predictive_score_v1 s
      join public.flow_shadow_rank_forward_outcome_v1 o
        on o.model_contract=s.model_contract and o.signal_date=s.signal_date
        and o.ticker=s.ticker and o.horizon_days=k.horizon_days
      where s.model_contract=k.model_contract and s.signal_date=k.signal_date
        and s.shadow_rank<=20 and s.timing_quality='IDEAL' and o.outcome_state='MATURED'),
    (select 100.0*count(*) filter(where h.lifecycle_state in ('BROKEN','WEAKENING'))
      /nullif(count(*),0)
      from public.flow_thesis_lifecycle_history_v1 h
      where h.thesis_contract='IDX_THESIS_LIFECYCLE_SHADOW_V1'
        and h.signal_date=k.signal_date
        and h.observation_date=(select max(x.observation_date)
          from public.flow_thesis_lifecycle_history_v1 x
          where x.thesis_contract=h.thesis_contract and x.signal_date=h.signal_date
            and x.observation_date<=(
              select max(o.target_date) from public.flow_shadow_rank_forward_outcome_v1 o
              where o.model_contract=k.model_contract and o.signal_date=k.signal_date
                and o.horizon_days=k.horizon_days))),
    false
  from keys k
  on conflict(model_contract,signal_date,horizon_days) do update set
    shadow_universe_count=excluded.shadow_universe_count,
    production_comparable_count=excluded.production_comparable_count,
    top10_overlap_count=excluded.top10_overlap_count,top10_overlap_pct=excluded.top10_overlap_pct,
    top20_overlap_count=excluded.top20_overlap_count,top20_overlap_pct=excluded.top20_overlap_pct,
    mean_absolute_rank_displacement=excluded.mean_absolute_rank_displacement,
    matured_sample_count=excluded.matured_sample_count,mean_alpha_pct=excluded.mean_alpha_pct,
    median_alpha_pct=excluded.median_alpha_pct,hit_rate_pct=excluded.hit_rate_pct,
    mean_max_favorable_excursion_pct=excluded.mean_max_favorable_excursion_pct,
    mean_max_adverse_excursion_pct=excluded.mean_max_adverse_excursion_pct,
    active_liquidity_top20_pct=excluded.active_liquidity_top20_pct,
    maximum_sector_concentration_top20_pct=excluded.maximum_sector_concentration_top20_pct,
    top20_turnover_pct=excluded.top20_turnover_pct,
    false_positive_rate_pct=excluded.false_positive_rate_pct,
    false_negative_candidate_count=excluded.false_negative_candidate_count,
    ideal_timing_hit_rate_pct=excluded.ideal_timing_hit_rate_pct,
    thesis_failure_rate_pct=excluded.thesis_failure_rate_pct,
    calculated_at=statement_timestamp();
  get diagnostics v_rows = row_count;
  return jsonb_build_object('status','OK','metric_cells',v_rows,'production_influence_enabled',false);
end
$fn$;

create or replace function public.flow_assess_gate15_promotion_v1()
returns jsonb
language plpgsql
security invoker
set search_path=''
as $fn$
declare v_rows integer := 0;
begin
  with policy_horizon as (
    select p.candidate_id,h.horizon_days
    from public.flow_gate15_promotion_policy_v1 p
    cross join (values(5),(20),(60)) h(horizon_days)
    where p.policy_version='GATE15_PROMOTION_POLICY_V1'
  ), active as (
    select c.attribution_contract,c.signal_date,c.ticker,c.candidate_id,h.horizon_days,
      case when c.candidate_type='DRIVER' then
        nullif(c.component_percentiles->>c.candidate_id,'')::numeric
      else (
        select min(nullif(x.value,'')::numeric)
        from jsonb_each_text(c.component_percentiles) x
      ) end signal_strength,
      (select i.trade_date from public.flow_official_index_summary i
       where i.index_code='COMPOSITE' and i.source_verified and i.trade_date>c.signal_date
       order by i.trade_date offset(h.horizon_days-1) limit 1) target_date
    from public.flow_attribution_prospective_candidate_v1 c
    cross join (values(5),(20),(60)) h(horizon_days)
    where c.attribution_contract='IDX_PREDICTIVE_ATTRIBUTION_SHADOW_V1' and c.active_signal
  ), by_horizon as (
    select ph.candidate_id,ph.horizon_days,count(distinct a.signal_date)::int signal_dates,
      count(*) filter(where a.target_date is not null)::int expected_matured,
      count(o.ticker)::int matured_samples,
      100.0*count(o.ticker)/nullif(count(*) filter(where a.target_date is not null),0) coverage_pct,
      avg(o.alpha_vs_ihsg_pct) mean_alpha,
      percentile_cont(0.5) within group(order by o.alpha_vs_ihsg_pct) median_alpha,
      100.0*count(*) filter(where o.alpha_vs_ihsg_pct>0)/nullif(count(o.ticker),0) hit_rate,
      corr(a.signal_strength::double precision,o.alpha_vs_ihsg_pct::double precision) rank_ic,
      abs(avg(o.max_adverse_excursion_pct)) mean_adverse_abs
    from policy_horizon ph left join active a
      on a.candidate_id=ph.candidate_id and a.horizon_days=ph.horizon_days
    left join public.flow_attribution_forward_outcome_v1 o
      on o.attribution_contract=a.attribution_contract and o.signal_date=a.signal_date
      and o.ticker=a.ticker and o.candidate_id=a.candidate_id
      and o.horizon_days=a.horizon_days and o.outcome_state='MATURED'
    group by ph.candidate_id,ph.horizon_days
  ), incremental as (
    select h.candidate_id,h.horizon_days,
      h.mean_alpha-(select max(x.component_alpha) from (
        select avg(d.alpha_vs_ihsg_pct) component_alpha
        from public.flow_component_forward_outcome_diagnostic_v1 d
        join public.flow_attribution_forward_registry_v1 f
          on f.attribution_contract='IDX_PREDICTIVE_ATTRIBUTION_SHADOW_V1'
          and f.candidate_id=h.candidate_id and d.driver_id=any(f.component_ids)
        where d.attribution_contract='IDX_PREDICTIVE_ATTRIBUTION_SHADOW_V1'
          and d.horizon_days=h.horizon_days and d.outcome_state='MATURED'
        group by d.driver_id
      ) x) incremental_lift
    from by_horizon h
  ), robustness_source as (
    select o.candidate_id,o.horizon_days,o.signal_date,o.alpha_vs_ihsg_pct,
      u.liquidity_state,
      case when (
        select 100.0*(i.close/p.close-1)
        from public.flow_official_index_summary i
        join lateral(
          select j.close from public.flow_official_index_summary j
          where j.index_code='COMPOSITE' and j.source_verified and j.trade_date<i.trade_date
          order by j.trade_date desc offset 19 limit 1
        ) p on true
        where i.index_code='COMPOSITE' and i.source_verified and i.trade_date=o.signal_date
      )>=0 then 'BULL_OR_FLAT' else 'BEAR' end regime
    from public.flow_attribution_forward_outcome_v1 o
    left join public.flow_universe_snapshot_v1 u
      on u.universe_contract='TOP_900_UNIVERSE_V1' and u.snapshot_date=o.signal_date
      and u.ticker=o.ticker
    where o.attribution_contract='IDX_PREDICTIVE_ATTRIBUTION_SHADOW_V1'
      and o.outcome_state='MATURED'
  ), regime_cells as (
    select candidate_id,horizon_days,regime,avg(alpha_vs_ihsg_pct) cell_alpha
    from robustness_source group by candidate_id,horizon_days,regime
  ), regime as (
    select candidate_id,100.0*count(*) filter(where cell_alpha>0)/nullif(count(*),0) consistency
    from regime_cells group by candidate_id
  ), liquidity_cells as (
    select candidate_id,horizon_days,liquidity_state,avg(alpha_vs_ihsg_pct) cell_alpha
    from robustness_source where liquidity_state is not null
    group by candidate_id,horizon_days,liquidity_state
  ), liquidity as (
    select candidate_id,100.0*count(*) filter(where cell_alpha>0)/nullif(count(*),0) consistency
    from liquidity_cells group by candidate_id
  ), summary as (
    select p.policy_version,p.candidate_id,p.candidate_type,
      coalesce(max(h.signal_dates),0)::int independent_dates,
      coalesce(min(h.matured_samples),0)::int min_samples,
      min(h.coverage_pct) min_coverage,
      count(*) filter(where h.mean_alpha>0)::int positive_horizons,
      min(h.hit_rate) direction_agreement,
      min(h.rank_ic) minimum_rank_ic,
      r.consistency regime_consistency,l.consistency liquidity_consistency,
      max(h.mean_adverse_abs) maximum_mean_adverse_abs,
      min(i.incremental_lift) minimum_incremental_lift,
      jsonb_agg(jsonb_build_object(
        'horizon_days',h.horizon_days,'signal_dates',h.signal_dates,
        'expected_matured',h.expected_matured,'matured_samples',h.matured_samples,
        'coverage_pct',h.coverage_pct,'mean_alpha_pct',h.mean_alpha,
        'median_alpha_pct',h.median_alpha,'hit_rate_pct',h.hit_rate,
        'rank_ic',h.rank_ic,
        'mean_adverse_excursion_abs_pct',h.mean_adverse_abs,
        'incremental_lift_pct',i.incremental_lift
      ) order by h.horizon_days) metrics,
      bool_and(h.matured_samples>=p.minimum_sample_size_per_horizon) sample_gate,
      bool_and(h.coverage_pct>=p.minimum_forward_coverage_pct) coverage_gate,
      bool_and(h.mean_alpha>=((p.minimum_mean_alpha_pct->>h.horizon_days::text)::numeric)) mean_gate,
      bool_and(h.median_alpha>=((p.minimum_median_alpha_pct->>h.horizon_days::text)::numeric)) median_gate,
      bool_and(h.rank_ic>=p.minimum_rank_ic) rank_ic_gate,
      bool_and(h.mean_adverse_abs<=((p.maximum_mean_adverse_excursion_abs_pct->>h.horizon_days::text)::numeric)) adverse_gate,
      bool_and(case when p.candidate_type='DRIVER' then true
        else i.incremental_lift>=((p.minimum_incremental_lift_pct->>h.horizon_days::text)::numeric) end) lift_gate
    from public.flow_gate15_promotion_policy_v1 p
    left join by_horizon h on h.candidate_id=p.candidate_id
    left join incremental i on i.candidate_id=h.candidate_id and i.horizon_days=h.horizon_days
    left join regime r on r.candidate_id=p.candidate_id
    left join liquidity l on l.candidate_id=p.candidate_id
    where p.policy_version='GATE15_PROMOTION_POLICY_V1'
    group by p.policy_version,p.candidate_id,p.candidate_type,
      p.minimum_sample_size_per_horizon,p.minimum_forward_coverage_pct,
      p.minimum_mean_alpha_pct,p.minimum_median_alpha_pct,
      p.minimum_rank_ic,
      p.maximum_mean_adverse_excursion_abs_pct,p.minimum_incremental_lift_pct,
      r.consistency,l.consistency
  ), discovery as (
    select p.candidate_id,
      case when p.candidate_type='DRIVER' then
        (d.mean_heldout_alpha_spread_pct>0 and d.mean_forward_alpha_spread_pct>0)
      else
        (i.mean_heldout_incremental_lift_pct>0 and i.mean_forward_incremental_lift_pct>0)
      end heldout_forward_gate
    from public.flow_gate15_promotion_policy_v1 p
    left join public.flow_driver_oos_summary_v1 d
      on p.candidate_type='DRIVER' and d.validation_contract='IDX_DRIVER_PURGED_EXPANDING_WF_V2'
      and d.driver_id=p.candidate_id
    left join public.flow_driver_interaction_summary_v1 i
      on p.candidate_type='INTERACTION' and i.validation_contract='IDX_DRIVER_BOUNDED_CONFLUENCE_WF_V2'
      and i.interaction_id=p.candidate_id
    where p.policy_version='GATE15_PROMOTION_POLICY_V1'
  )
  insert into public.flow_gate15_promotion_assessment_v1(
    policy_version,candidate_id,assessment_state,independent_signal_dates,
    minimum_matured_sample_across_horizons,minimum_observed_coverage_pct,
    positive_horizons,direction_agreement_pct,minimum_observed_rank_ic,regime_consistency_pct,
    liquidity_consistency_pct,maximum_mean_adverse_excursion_abs_pct,
    minimum_incremental_lift_pct,observed_metrics,gate_results,
    production_influence_enabled
  )
  select s.policy_version,s.candidate_id,
    case when s.independent_dates<20 or s.min_samples=0 then 'INSUFFICIENT_EVIDENCE'
         when s.sample_gate and s.coverage_gate and s.mean_gate and s.median_gate
           and s.rank_ic_gate and s.adverse_gate and s.lift_gate
           and coalesce(d.heldout_forward_gate,false)
           and s.positive_horizons=3 and s.direction_agreement>=66.67
           and s.regime_consistency>=60 and s.liquidity_consistency>=60
           then 'READY_FOR_LIMITED_PROMOTION_EXPERIMENT'
         else 'CONTINUE_SHADOW' end,
    s.independent_dates,s.min_samples,s.min_coverage,s.positive_horizons,
    s.direction_agreement,s.minimum_rank_ic,s.regime_consistency,s.liquidity_consistency,
    s.maximum_mean_adverse_abs,s.minimum_incremental_lift,s.metrics,
    jsonb_build_object(
      'minimum_dates_pass',s.independent_dates>=20,'sample_pass',coalesce(s.sample_gate,false),
      'coverage_pass',coalesce(s.coverage_gate,false),'mean_alpha_pass',coalesce(s.mean_gate,false),
      'median_alpha_pass',coalesce(s.median_gate,false),'rank_ic_pass',coalesce(s.rank_ic_gate,false),
      'adverse_excursion_pass',coalesce(s.adverse_gate,false),
      'incremental_lift_pass',coalesce(s.lift_gate,false),
      'heldout_forward_pass',coalesce(d.heldout_forward_gate,false),
      'positive_horizons_pass',s.positive_horizons=3,
      'direction_agreement_pass',s.direction_agreement>=66.67,
      'regime_consistency_pass',coalesce(s.regime_consistency>=60,false),
      'liquidity_consistency_pass',coalesce(s.liquidity_consistency>=60,false),
      'missing_robustness_fails_closed',true
    ),false
  from summary s left join discovery d using(candidate_id)
  on conflict(policy_version,candidate_id) do update set
    assessment_state=excluded.assessment_state,
    independent_signal_dates=excluded.independent_signal_dates,
    minimum_matured_sample_across_horizons=excluded.minimum_matured_sample_across_horizons,
    minimum_observed_coverage_pct=excluded.minimum_observed_coverage_pct,
    positive_horizons=excluded.positive_horizons,
    direction_agreement_pct=excluded.direction_agreement_pct,
    minimum_observed_rank_ic=excluded.minimum_observed_rank_ic,
    regime_consistency_pct=excluded.regime_consistency_pct,
    liquidity_consistency_pct=excluded.liquidity_consistency_pct,
    maximum_mean_adverse_excursion_abs_pct=excluded.maximum_mean_adverse_excursion_abs_pct,
    minimum_incremental_lift_pct=excluded.minimum_incremental_lift_pct,
    observed_metrics=excluded.observed_metrics,gate_results=excluded.gate_results,
    assessed_at=statement_timestamp();
  get diagnostics v_rows = row_count;
  return jsonb_build_object('status','OK','candidate_assessments',v_rows,
    'production_influence_enabled',false);
end
$fn$;

create or replace function public.flow_run_gate15_outcome_cycle_v1()
returns jsonb
language plpgsql
security invoker
set search_path=''
as $fn$
declare v_candidate jsonb; v_excursions integer; v_rank jsonb; v_eval jsonb; v_assess jsonb;
begin
  v_candidate := public.flow_evaluate_attribution_forward_outcomes_v1();
  v_excursions := public.flow_enrich_attribution_excursions_v1();
  v_rank := public.flow_evaluate_shadow_predictive_outcomes_v1();
  v_eval := public.flow_refresh_shadow_predictive_evaluation_v1();
  v_assess := public.flow_assess_gate15_promotion_v1();
  return jsonb_build_object('candidate_outcomes',v_candidate,'candidate_excursions',v_excursions,
    'rank_outcomes',v_rank,'evaluation',v_eval,'promotion_assessment',v_assess,
    'production_influence_enabled',false);
end
$fn$;

create or replace function public.flow_run_attribution_signal_cycle_v2(
  p_signal_date date default ((clock_timestamp() at time zone 'Asia/Jakarta')::date)
)
returns jsonb
language plpgsql
security invoker
set search_path=''
as $fn$
declare v_signal jsonb; v_structured jsonb; v_thesis jsonb; v_shadow jsonb;
begin
  v_signal := public.flow_capture_attribution_prospective_signals_v1(p_signal_date);
  if coalesce(v_signal->>'status','')<>'CAPTURED' then
    return jsonb_build_object('signal',v_signal,'structured',jsonb_build_object('status','NOT_RUN'),
      'thesis',jsonb_build_object('status','NOT_RUN'),'shadow_score',jsonb_build_object('status','NOT_RUN'),
      'production_influence_enabled',false);
  end if;
  v_structured := public.flow_capture_structured_attribution_v2(p_signal_date);
  if coalesce(v_structured->>'status','')='CAPTURED' then
    v_thesis := public.flow_refresh_thesis_lifecycle_v1(p_signal_date);
    v_shadow := public.flow_capture_shadow_predictive_score_v1(p_signal_date);
  else
    v_thesis := jsonb_build_object('status','NOT_RUN');
    v_shadow := jsonb_build_object('status','NOT_RUN');
  end if;
  return jsonb_build_object('signal',v_signal,'structured',v_structured,'thesis',v_thesis,
    'shadow_score',v_shadow,'production_influence_enabled',false);
end
$fn$;

alter table public.flow_gate15_promotion_policy_v1 enable row level security;
alter table public.flow_shadow_predictive_model_policy_v1 enable row level security;
alter table public.flow_shadow_predictive_score_v1 enable row level security;
alter table public.flow_shadow_rank_forward_outcome_v1 enable row level security;
alter table public.flow_component_forward_outcome_diagnostic_v1 enable row level security;
alter table public.flow_shadow_predictive_evaluation_v1 enable row level security;
alter table public.flow_gate15_promotion_assessment_v1 enable row level security;

revoke all on table public.flow_gate15_promotion_policy_v1,
  public.flow_shadow_predictive_model_policy_v1,public.flow_shadow_predictive_score_v1,
  public.flow_shadow_rank_forward_outcome_v1,public.flow_component_forward_outcome_diagnostic_v1,
  public.flow_shadow_predictive_evaluation_v1,public.flow_gate15_promotion_assessment_v1
  from public,anon,authenticated;
grant select,insert,update,delete on table public.flow_gate15_promotion_policy_v1,
  public.flow_shadow_predictive_model_policy_v1,public.flow_shadow_predictive_score_v1,
  public.flow_shadow_rank_forward_outcome_v1,public.flow_component_forward_outcome_diagnostic_v1,
  public.flow_shadow_predictive_evaluation_v1,public.flow_gate15_promotion_assessment_v1
  to service_role;

revoke all on function public.flow_capture_shadow_predictive_score_v1(date),
  public.flow_enrich_attribution_excursions_v1(),
  public.flow_evaluate_shadow_predictive_outcomes_v1(),
  public.flow_refresh_shadow_predictive_evaluation_v1(),
  public.flow_assess_gate15_promotion_v1(),public.flow_run_gate15_outcome_cycle_v1(),
  public.flow_run_attribution_signal_cycle_v2(date)
  from public,anon,authenticated;
grant execute on function public.flow_capture_shadow_predictive_score_v1(date),
  public.flow_enrich_attribution_excursions_v1(),
  public.flow_evaluate_shadow_predictive_outcomes_v1(),
  public.flow_refresh_shadow_predictive_evaluation_v1(),
  public.flow_assess_gate15_promotion_v1(),public.flow_run_gate15_outcome_cycle_v1(),
  public.flow_run_attribution_signal_cycle_v2(date)
  to service_role;

do $do$
declare r record;
begin
  for r in select jobid from cron.job where jobname='flow-attribution-forward-outcomes-v1' loop
    perform cron.unschedule(r.jobid);
  end loop;
  perform cron.schedule(
    'flow-attribution-forward-outcomes-v1','50 11 * * 1-5',
    'select public.flow_run_gate15_outcome_cycle_v1();'
  );
end
$do$;
