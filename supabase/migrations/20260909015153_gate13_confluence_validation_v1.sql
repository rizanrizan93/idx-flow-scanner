-- Gate 13: bounded preregistered interaction / confluence validation.
-- Research/calibration only; no production score/rank/decision/execution influence.

create table if not exists public.flow_driver_gate13_run_v1 (
  validation_contract text primary key,
  registry_version text not null,
  parent_validation_contract text not null,
  evaluation_started_at timestamptz not null,
  registry_frozen_at timestamptz not null,
  max_interaction_budget integer not null check(max_interaction_budget=12),
  registered_interactions integer not null check(registered_interactions<=max_interaction_budget),
  production_influence_enabled boolean not null default false check(production_influence_enabled=false)
);

insert into public.flow_driver_gate13_run_v1
select 'IDX_DRIVER_BOUNDED_CONFLUENCE_WF_V1','IDX_DRIVER_REGISTRY_GATE10_V1','IDX_DRIVER_PURGED_EXPANDING_WF_V1',
       statement_timestamp(),p.frozen_at,p.max_interaction_budget,
       (select count(*) from public.flow_driver_interaction_registry_v1 i where i.registry_version=p.registry_version),false
from public.flow_driver_research_policy_v1 p
where p.registry_version='IDX_DRIVER_REGISTRY_GATE10_V1'
on conflict(validation_contract) do nothing;

create table if not exists public.flow_driver_interaction_metrics_v1 (
  validation_contract text not null,
  interaction_id text not null,
  family text not null,
  horizon_days integer not null check(horizon_days in (5,20,60)),
  fold_no integer not null check(fold_no in (1,2)),
  segment text not null check(segment in ('TRAIN','VALIDATION','HELDOUT','FORWARD')),
  universe_count integer not null,
  component_available_count integer not null,
  confluence_count integer not null,
  coverage_pct numeric not null,
  mean_return_pct numeric,
  mean_alpha_vs_ihsg_pct numeric,
  hit_rate_pct numeric,
  mean_mfe_pct numeric,
  mean_mae_pct numeric,
  strongest_component_id text,
  strongest_component_top_alpha_pct numeric,
  incremental_alpha_lift_pct numeric,
  valid_sample boolean not null,
  calculated_at timestamptz not null,
  production_influence_enabled boolean not null default false check(production_influence_enabled=false),
  primary key(validation_contract,interaction_id,horizon_days,fold_no,segment)
);

create table if not exists public.flow_driver_interaction_slices_v1 (
  validation_contract text not null,
  interaction_id text not null,
  horizon_days integer not null check(horizon_days in (5,20,60)),
  slice_kind text not null check(slice_kind in ('MARKET_REGIME','LIQUIDITY_QUINTILE')),
  slice_value text not null,
  observation_count integer not null,
  confluence_count integer not null,
  mean_alpha_vs_ihsg_pct numeric,
  hit_rate_pct numeric,
  valid_sample boolean not null,
  direction_agreement boolean,
  calculated_at timestamptz not null,
  primary key(validation_contract,interaction_id,horizon_days,slice_kind,slice_value)
);

create table if not exists public.flow_driver_interaction_summary_v1 (
  validation_contract text not null,
  interaction_id text not null,
  family text not null,
  component_driver_ids text[] not null,
  valid_oos_cells integer not null,
  positive_oos_cells integer not null,
  direction_agreement_pct numeric,
  mean_oos_alpha_pct numeric,
  mean_heldout_alpha_pct numeric,
  mean_forward_alpha_pct numeric,
  mean_incremental_lift_pct numeric,
  mean_heldout_incremental_lift_pct numeric,
  mean_forward_incremental_lift_pct numeric,
  positive_horizons integer not null,
  confluence_coverage_pct numeric not null,
  regime_consistency_pct numeric,
  liquidity_consistency_pct numeric,
  classification text not null check(classification in ('VALIDATED_CONFLUENCE','REGIME_DEPENDENT','LIQUIDITY_SENSITIVE','WEAK','UNSTABLE','REJECTED','INSUFFICIENT_EVIDENCE')),
  confirmation_state text not null,
  eligible_to_enter_phase2 boolean not null,
  decision_reason text not null,
  calculated_at timestamptz not null,
  production_influence_enabled boolean not null default false check(production_influence_enabled=false),
  primary key(validation_contract,interaction_id)
);

create table if not exists public.flow_driver_gate13_manifest_v1 (
  validation_contract text primary key,
  registry_version text not null,
  parent_validation_contract text not null,
  registered_interactions integer not null,
  evaluated_interactions integer not null,
  metric_interactions integer not null,
  metric_cells integer not null,
  validated_interactions integer not null,
  rejected_interactions integer not null,
  insufficient_interactions integer not null,
  panel_leakage_count integer not null check(panel_leakage_count=0),
  target_leakage_count integer not null check(target_leakage_count=0),
  posthoc_mining_count integer not null check(posthoc_mining_count=0),
  interaction_budget_respected boolean not null check(interaction_budget_respected),
  gate_state text not null check(gate_state in ('PASS','FAIL')),
  completed_at timestamptz not null,
  production_influence_enabled boolean not null default false check(production_influence_enabled=false)
);

alter table public.flow_driver_gate13_run_v1 enable row level security;
alter table public.flow_driver_interaction_metrics_v1 enable row level security;
alter table public.flow_driver_interaction_slices_v1 enable row level security;
alter table public.flow_driver_interaction_summary_v1 enable row level security;
alter table public.flow_driver_gate13_manifest_v1 enable row level security;

revoke all on public.flow_driver_gate13_run_v1,public.flow_driver_interaction_metrics_v1,
 public.flow_driver_interaction_slices_v1,public.flow_driver_interaction_summary_v1,
 public.flow_driver_gate13_manifest_v1 from public,anon,authenticated,service_role;
grant select on public.flow_driver_gate13_run_v1 to service_role;
grant select,insert,update,delete on public.flow_driver_interaction_metrics_v1,
 public.flow_driver_interaction_slices_v1,public.flow_driver_interaction_summary_v1,
 public.flow_driver_gate13_manifest_v1 to service_role;

create or replace function public.flow_run_interaction_oos_v1(p_interaction_id text)
returns jsonb
language plpgsql
security invoker
set search_path=''
set work_mem='32MB'
as $fn$
declare
  v_contract constant text := 'IDX_DRIVER_BOUNDED_CONFLUENCE_WF_V1';
  v_parent constant text := 'IDX_DRIVER_PURGED_EXPANDING_WF_V1';
  v_panel constant text := 'IDX_DRIVER_WEEKLY_PIT_PANEL_V1';
  v_components text[];
  v_family text;
  v_min_coverage numeric;
  v_min_sample integer;
  v_component_count integer;
  v_ready_count integer;
  v_at timestamptz;
  v_rows integer;
begin
  select component_driver_ids,family,minimum_coverage_pct,minimum_sample_size
    into strict v_components,v_family,v_min_coverage,v_min_sample
  from public.flow_driver_interaction_registry_v1
  where registry_version='IDX_DRIVER_REGISTRY_GATE10_V1' and interaction_id=p_interaction_id;

  select evaluation_started_at into strict v_at
  from public.flow_driver_gate13_run_v1 where validation_contract=v_contract;

  v_component_count := cardinality(v_components);
  select count(*) into v_ready_count
  from unnest(v_components) c(driver_id)
  join public.flow_driver_registry_v1 r
    on r.registry_version='IDX_DRIVER_REGISTRY_GATE10_V1' and r.driver_id=c.driver_id and r.evaluation_eligible
  join public.flow_driver_coverage_v1 cv
    on cv.panel_contract=v_panel and cv.entity_type='DRIVER' and cv.entity_id=c.driver_id and cv.coverage_pct>0;

  delete from public.flow_driver_interaction_metrics_v1
   where validation_contract=v_contract and interaction_id=p_interaction_id;
  delete from public.flow_driver_interaction_slices_v1
   where validation_contract=v_contract and interaction_id=p_interaction_id;

  if v_ready_count < v_component_count then
    return jsonb_build_object('status','INSUFFICIENT_EVIDENCE','interaction_id',p_interaction_id,
      'ready_components',v_ready_count,'required_components',v_component_count,'production_influence_enabled',false);
  end if;

  drop table if exists pg_temp.flow_gate13_base;
  create temp table flow_gate13_base on commit drop as
  with comp as (
    select s.signal_date,s.ticker,s.market_regime,c.driver_id,o.driver_state,o.normalized_value
    from public.flow_driver_signal_panel_v1 s
    cross join unnest(v_components) c(driver_id)
    left join public.flow_driver_observation_panel_v1 o
      on o.panel_contract=s.panel_contract and o.signal_date=s.signal_date and o.ticker=s.ticker and o.driver_id=c.driver_id
    where s.panel_contract=v_panel
  ), grouped as (
    select signal_date,ticker,max(market_regime) market_regime,
      count(*) filter(where driver_state='AVAILABLE' and normalized_value is not null) available_components,
      min(normalized_value) filter(where driver_state='AVAILABLE') interaction_score,
      bool_and(driver_state='AVAILABLE' and normalized_value is not null) component_available,
      bool_and(driver_state='AVAILABLE' and normalized_value>=0.80) confluence_signal
    from comp group by signal_date,ticker
  ), liq as (
    select signal_date,ticker,normalized_value liquidity_rank
    from public.flow_driver_observation_panel_v1
    where panel_contract=v_panel and driver_id='LIQ_TURNOVER' and driver_state='AVAILABLE'
  )
  select g.*,l.liquidity_rank,
    s.target_date_5d,s.target_date_20d,s.target_date_60d,
    s.forward_return_5d_pct,s.forward_return_20d_pct,s.forward_return_60d_pct,
    s.alpha_vs_ihsg_5d_pct,s.alpha_vs_ihsg_20d_pct,s.alpha_vs_ihsg_60d_pct,
    s.mfe_5d_pct,s.mfe_20d_pct,s.mfe_60d_pct,
    s.mae_5d_pct,s.mae_20d_pct,s.mae_60d_pct
  from grouped g
  join public.flow_driver_signal_panel_v1 s
    on s.panel_contract=v_panel and s.signal_date=g.signal_date and s.ticker=g.ticker
  left join liq l using(signal_date,ticker);

  analyze pg_temp.flow_gate13_base;

  insert into public.flow_driver_interaction_metrics_v1
  with expanded as (
    select b.*,h.*
    from pg_temp.flow_gate13_base b
    cross join lateral(values
      (5,b.target_date_5d,b.forward_return_5d_pct,b.alpha_vs_ihsg_5d_pct,b.mfe_5d_pct,b.mae_5d_pct),
      (20,b.target_date_20d,b.forward_return_20d_pct,b.alpha_vs_ihsg_20d_pct,b.mfe_20d_pct,b.mae_20d_pct),
      (60,b.target_date_60d,b.forward_return_60d_pct,b.alpha_vs_ihsg_60d_pct,b.mfe_60d_pct,b.mae_60d_pct)
    ) h(horizon_days,target_date,forward_return,alpha_ihsg,mfe,mae)
  ), segmented as (
    select e.*,f.fold_no,x.segment
    from expanded e
    join public.flow_driver_walkforward_folds_v1 f
      on f.validation_contract=v_parent and f.horizon_days=e.horizon_days
    cross join lateral(values
      ('TRAIN'::text,f.train_start,f.train_end),
      ('VALIDATION',f.validation_start,f.validation_end),
      ('HELDOUT',f.heldout_start,f.heldout_end),
      ('FORWARD',f.forward_start,f.forward_end)
    ) x(segment,start_date,end_date)
    where e.signal_date between x.start_date and x.end_date
      and e.target_date is not null and e.alpha_ihsg is not null
      and (x.segment<>'TRAIN' or e.target_date<=f.train_end)
  ), agg as (
    select horizon_days,fold_no,segment,
      count(*)::int universe_count,
      count(*) filter(where component_available)::int component_available_count,
      count(*) filter(where confluence_signal)::int confluence_count,
      100.0*count(*) filter(where confluence_signal)/nullif(count(*),0) coverage_pct,
      avg(forward_return) filter(where confluence_signal) mean_return,
      avg(alpha_ihsg) filter(where confluence_signal) mean_alpha,
      100.0*avg((alpha_ihsg>0)::int) filter(where confluence_signal) hit_rate,
      avg(mfe) filter(where confluence_signal) mean_mfe,
      avg(mae) filter(where confluence_signal) mean_mae
    from segmented group by horizon_days,fold_no,segment
  )
  select v_contract,p_interaction_id,v_family,a.horizon_days,a.fold_no,a.segment,
    a.universe_count,a.component_available_count,a.confluence_count,round(a.coverage_pct,4),
    a.mean_return,a.mean_alpha,a.hit_rate,a.mean_mfe,a.mean_mae,
    sc.driver_id,sc.top_mean_alpha_vs_ihsg_pct,
    a.mean_alpha-sc.top_mean_alpha_vs_ihsg_pct,
    (a.confluence_count>=v_min_sample and a.coverage_pct>=v_min_coverage and a.mean_alpha is not null and sc.top_mean_alpha_vs_ihsg_pct is not null),
    v_at,false
  from agg a
  left join lateral (
    select m.driver_id,m.top_mean_alpha_vs_ihsg_pct
    from public.flow_driver_oos_metrics_v1 m
    where m.validation_contract=v_parent and m.driver_id=any(v_components)
      and m.horizon_days=a.horizon_days and m.fold_no=a.fold_no and m.segment=a.segment
      and m.top_mean_alpha_vs_ihsg_pct is not null
    order by m.top_mean_alpha_vs_ihsg_pct desc,m.driver_id
    limit 1
  ) sc on true;
  get diagnostics v_rows=row_count;

  insert into public.flow_driver_interaction_slices_v1
  with expanded as (
    select b.*,h.*
    from pg_temp.flow_gate13_base b
    cross join lateral(values
      (5,b.target_date_5d,b.alpha_vs_ihsg_5d_pct),
      (20,b.target_date_20d,b.alpha_vs_ihsg_20d_pct),
      (60,b.target_date_60d,b.alpha_vs_ihsg_60d_pct)
    ) h(horizon_days,target_date,alpha_ihsg)
  ), oos as (
    select e.*
    from expanded e
    join public.flow_driver_walkforward_folds_v1 f
      on f.validation_contract=v_parent and f.horizon_days=e.horizon_days and f.fold_no=1
    where e.signal_date between f.validation_start and f.forward_end
      and e.target_date is not null and e.alpha_ihsg is not null
  ), sliced as (
    select o.*,'MARKET_REGIME'::text slice_kind,market_regime slice_value from oos o
    union all
    select o.*,'LIQUIDITY_QUINTILE',least(5,floor(liquidity_rank*5)::int+1)::text
    from oos o where liquidity_rank is not null
  )
  select v_contract,p_interaction_id,horizon_days,slice_kind,slice_value,
    count(*)::int,count(*) filter(where confluence_signal)::int,
    avg(alpha_ihsg) filter(where confluence_signal),
    100.0*avg((alpha_ihsg>0)::int) filter(where confluence_signal),
    count(*) filter(where confluence_signal)>=v_min_sample,
    (avg(alpha_ihsg) filter(where confluence_signal)>0),v_at
  from sliced group by horizon_days,slice_kind,slice_value;

  return jsonb_build_object('status','PASS','interaction_id',p_interaction_id,'metric_cells',v_rows,
    'production_influence_enabled',false);
end;$fn$;

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
      count(o.*)::int valid_cells,
      count(o.*) filter(where o.incremental_alpha_lift_pct>0)::int positive_cells,
      100.0*count(o.*) filter(where o.incremental_alpha_lift_pct>0)/nullif(count(o.*),0) direction_pct,
      avg(o.mean_alpha_vs_ihsg_pct) mean_alpha,
      avg(o.mean_alpha_vs_ihsg_pct) filter(where o.segment='HELDOUT') heldout_alpha,
      avg(o.mean_alpha_vs_ihsg_pct) filter(where o.segment='FORWARD') forward_alpha,
      avg(o.incremental_alpha_lift_pct) mean_lift,
      avg(o.incremental_alpha_lift_pct) filter(where o.segment='HELDOUT') heldout_lift,
      avg(o.incremental_alpha_lift_pct) filter(where o.segment='FORWARD') forward_lift,
      avg(o.coverage_pct) coverage_pct
    from public.flow_driver_interaction_registry_v1 r
    left join o on o.interaction_id=r.interaction_id
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

revoke all on function public.flow_run_interaction_oos_v1(text) from public,anon,authenticated;
revoke all on function public.flow_finalize_driver_gate13_v1() from public,anon,authenticated;
grant execute on function public.flow_run_interaction_oos_v1(text) to service_role;
grant execute on function public.flow_finalize_driver_gate13_v1() to service_role;

comment on table public.flow_driver_interaction_summary_v1 is 'Gate 13 predictive association and incremental-lift research only; no causal or production claim.';
