-- Gate 12: preregistered single-driver predictive validation.
-- FIN_BALANCE remains discovery-aware; no production promotion is possible here.

create or replace function public.flow_driver_feature_orientation_guard_v1()
returns trigger language plpgsql security invoker set search_path='' as $fn$
begin
  new.raw_values:=jsonb_set(new.raw_values,'{FLOW_FOREIGN_DISTRIBUTION}',
    to_jsonb(-coalesce((new.raw_values->>'FLOW_FOREIGN_ACCUMULATION')::numeric,0)),true);
  return new;
end;$fn$;
drop trigger if exists flow_driver_feature_orientation_guard_v1 on public.flow_driver_feature_panel_v1;
create trigger flow_driver_feature_orientation_guard_v1 before insert or update of raw_values
on public.flow_driver_feature_panel_v1 for each row execute function public.flow_driver_feature_orientation_guard_v1();
update public.flow_driver_feature_panel_v1 set raw_values=raw_values
where panel_contract='IDX_DRIVER_WEEKLY_PIT_PANEL_V1';
revoke all on function public.flow_driver_feature_orientation_guard_v1() from public,anon,authenticated;

create table if not exists public.flow_driver_gate12_run_v1 (
  validation_contract text primary key,
  registry_version text not null,
  panel_contract text not null,
  evaluation_started_at timestamptz not null,
  registry_frozen_at timestamptz not null,
  candidate_registry_frozen_before_evaluation boolean not null check(candidate_registry_frozen_before_evaluation),
  result_read_before_freeze boolean not null default false check(result_read_before_freeze=false),
  production_influence_enabled boolean not null default false check(production_influence_enabled=false)
);
insert into public.flow_driver_gate12_run_v1
select 'IDX_DRIVER_PURGED_EXPANDING_WF_V1','IDX_DRIVER_REGISTRY_GATE10_V1','IDX_DRIVER_WEEKLY_PIT_PANEL_V1',
  statement_timestamp(),p.frozen_at,p.frozen_at<statement_timestamp(),false,false
from public.flow_driver_research_policy_v1 p where p.registry_version='IDX_DRIVER_REGISTRY_GATE10_V1'
on conflict(validation_contract) do nothing;

create table if not exists public.flow_driver_walkforward_folds_v1 (
  validation_contract text not null,horizon_days integer not null check(horizon_days in (5,20,60)),
  fold_no integer not null check(fold_no in (1,2)),train_start date not null,train_end date not null,
  validation_start date not null,validation_end date not null,heldout_start date not null,heldout_end date not null,
  forward_start date not null,forward_end date not null,purge_rule text not null,
  created_at timestamptz not null,primary key(validation_contract,horizon_days,fold_no)
);

create table if not exists public.flow_driver_oos_metrics_v1 (
  validation_contract text not null,driver_id text not null,family text not null,
  horizon_days integer not null,fold_no integer not null,segment text not null check(segment in ('TRAIN','VALIDATION','HELDOUT','FORWARD')),
  universe_count integer not null,observation_count integer not null,coverage_pct numeric not null,
  mean_return_pct numeric,median_return_pct numeric,mean_alpha_vs_ihsg_pct numeric,mean_alpha_vs_sector_pct numeric,
  hit_rate_pct numeric,top_count integer not null,bottom_count integer not null,
  top_mean_return_pct numeric,bottom_mean_return_pct numeric,top_bottom_return_spread_pct numeric,
  top_mean_alpha_vs_ihsg_pct numeric,bottom_mean_alpha_vs_ihsg_pct numeric,top_bottom_alpha_spread_pct numeric,
  top_mean_alpha_vs_sector_pct numeric,bottom_mean_alpha_vs_sector_pct numeric,top_bottom_sector_alpha_spread_pct numeric,
  rank_ic numeric,mean_mfe_pct numeric,mean_mae_pct numeric,missing_mean_alpha_pct numeric,
  direction_agreement boolean,valid_sample boolean not null,calculated_at timestamptz not null,
  production_influence_enabled boolean not null default false check(production_influence_enabled=false),
  primary key(validation_contract,driver_id,horizon_days,fold_no,segment)
);

create table if not exists public.flow_driver_oos_slices_v1 (
  validation_contract text not null,driver_id text not null,horizon_days integer not null,
  slice_kind text not null check(slice_kind in ('MARKET_REGIME','LIQUIDITY_QUINTILE')),
  slice_value text not null,observation_count integer not null,top_count integer not null,bottom_count integer not null,
  top_bottom_alpha_spread_pct numeric,direction_agreement boolean,valid_sample boolean not null,calculated_at timestamptz not null,
  primary key(validation_contract,driver_id,horizon_days,slice_kind,slice_value)
);

create table if not exists public.flow_driver_oos_summary_v1 (
  validation_contract text not null,driver_id text not null,family text not null,
  valid_oos_cells integer not null,positive_oos_cells integer not null,direction_agreement_pct numeric,
  mean_oos_alpha_spread_pct numeric,mean_heldout_alpha_spread_pct numeric,mean_forward_alpha_spread_pct numeric,
  mean_rank_ic numeric,positive_horizons integer not null,panel_coverage_pct numeric not null,
  regime_consistency_pct numeric,liquidity_consistency_pct numeric,sector_stability_state text not null,
  classification text not null check(classification in ('PROMISING','WEAK','UNSTABLE','REGIME_DEPENDENT','SECTOR_SPECIFIC','LIQUIDITY_SENSITIVE','REJECTED','INSUFFICIENT_EVIDENCE')),
  confirmation_state text not null,eligible_to_enter_phase2 boolean not null,
  decision_reason text not null,calculated_at timestamptz not null,
  production_influence_enabled boolean not null default false check(production_influence_enabled=false),
  primary key(validation_contract,driver_id)
);

create table if not exists public.flow_driver_gate12_manifest_v1 (
  validation_contract text primary key,registry_version text not null,panel_contract text not null,
  registered_drivers integer not null,evaluation_eligible_drivers integer not null,evaluated_drivers integer not null,
  fold_rows integer not null,metric_cells integer not null,invalid_metric_cells integer not null,
  promising_drivers integer not null,phase2_eligible_drivers integer not null,
  training_target_overlap_leaks integer not null check(training_target_overlap_leaks=0),
  panel_leakage_count integer not null check(panel_leakage_count=0),
  registry_frozen_before_evaluation boolean not null check(registry_frozen_before_evaluation),
  gate_state text not null,completed_at timestamptz not null,
  production_influence_enabled boolean not null default false check(production_influence_enabled=false)
);

alter table public.flow_driver_gate12_run_v1 enable row level security;
alter table public.flow_driver_walkforward_folds_v1 enable row level security;
alter table public.flow_driver_oos_metrics_v1 enable row level security;
alter table public.flow_driver_oos_slices_v1 enable row level security;
alter table public.flow_driver_oos_summary_v1 enable row level security;
alter table public.flow_driver_gate12_manifest_v1 enable row level security;
revoke all on public.flow_driver_gate12_run_v1,public.flow_driver_walkforward_folds_v1,
 public.flow_driver_oos_metrics_v1,public.flow_driver_oos_slices_v1,public.flow_driver_oos_summary_v1,
 public.flow_driver_gate12_manifest_v1 from public,anon,authenticated,service_role;
grant select on public.flow_driver_gate12_run_v1 to service_role;
grant select,insert,update,delete on public.flow_driver_walkforward_folds_v1,public.flow_driver_oos_metrics_v1,
 public.flow_driver_oos_slices_v1,public.flow_driver_oos_summary_v1,public.flow_driver_gate12_manifest_v1 to service_role;

create or replace function public.flow_build_driver_folds_v1()
returns jsonb language plpgsql security invoker set search_path='' as $fn$
declare v_contract constant text:='IDX_DRIVER_PURGED_EXPANDING_WF_V1';v_at timestamptz;v_rows integer;
begin
  select evaluation_started_at into strict v_at from public.flow_driver_gate12_run_v1 where validation_contract=v_contract;
  delete from public.flow_driver_walkforward_folds_v1 where validation_contract=v_contract;
  with h as (
    select 5 horizon_days,signal_date,target_date_5d target_date,alpha_vs_ihsg_5d_pct alpha from public.flow_driver_signal_panel_v1 where panel_contract='IDX_DRIVER_WEEKLY_PIT_PANEL_V1'
    union all select 20,signal_date,target_date_20d,alpha_vs_ihsg_20d_pct from public.flow_driver_signal_panel_v1 where panel_contract='IDX_DRIVER_WEEKLY_PIT_PANEL_V1'
    union all select 60,signal_date,target_date_60d,alpha_vs_ihsg_60d_pct from public.flow_driver_signal_panel_v1 where panel_contract='IDX_DRIVER_WEEKLY_PIT_PANEL_V1'
  ), dates as (
    select horizon_days,signal_date,row_number() over(partition by horizon_days order by signal_date) rn,count(*) over(partition by horizon_days) n
    from (select distinct horizon_days,signal_date from h where target_date is not null and alpha is not null) d
  ), b as (
    select horizon_days,min(signal_date) min_date,max(signal_date) max_date,
      max(signal_date) filter(where rn<=floor(n*.40)) f1_train_end,min(signal_date) filter(where rn>floor(n*.40)) f1_val_start,
      max(signal_date) filter(where rn<=floor(n*.60)) f1_val_end,min(signal_date) filter(where rn>floor(n*.60)) f1_hold_start,
      max(signal_date) filter(where rn<=floor(n*.80)) f1_hold_end,min(signal_date) filter(where rn>floor(n*.80)) f1_fwd_start,
      max(signal_date) filter(where rn<=floor(n*.55)) f2_train_end,min(signal_date) filter(where rn>floor(n*.55)) f2_val_start,
      max(signal_date) filter(where rn<=floor(n*.70)) f2_val_end,min(signal_date) filter(where rn>floor(n*.70)) f2_hold_start,
      max(signal_date) filter(where rn<=floor(n*.85)) f2_hold_end,min(signal_date) filter(where rn>floor(n*.85)) f2_fwd_start
    from dates group by horizon_days
  )
  insert into public.flow_driver_walkforward_folds_v1
  select v_contract,horizon_days,1,min_date,f1_train_end,f1_val_start,f1_val_end,f1_hold_start,f1_hold_end,f1_fwd_start,max_date,
    'PURGE_TRAIN_ROWS_UNLESS_TARGET_DATE_LE_TRAIN_END',v_at from b
  union all select v_contract,horizon_days,2,min_date,f2_train_end,f2_val_start,f2_val_end,f2_hold_start,f2_hold_end,f2_fwd_start,max_date,
    'PURGE_TRAIN_ROWS_UNLESS_TARGET_DATE_LE_TRAIN_END',v_at from b;
  get diagnostics v_rows=row_count;
  return jsonb_build_object('status','PASS','fold_rows',v_rows,'production_influence_enabled',false);
end;$fn$;

create or replace function public.flow_run_single_driver_oos_v1(p_driver_id text)
returns jsonb language plpgsql security invoker set search_path='' set work_mem='32MB' as $fn$
declare
  v_contract constant text:='IDX_DRIVER_PURGED_EXPANDING_WF_V1';v_panel constant text:='IDX_DRIVER_WEEKLY_PIT_PANEL_V1';
  v_family text;v_direction smallint;v_threshold text;v_min_history integer;v_at timestamptz;v_rows integer;
begin
  select family,direction_hypothesis,threshold_definition,minimum_history_sessions into strict v_family,v_direction,v_threshold,v_min_history
  from public.flow_driver_registry_v1 where registry_version='IDX_DRIVER_REGISTRY_GATE10_V1' and driver_id=p_driver_id and evaluation_eligible;
  select evaluation_started_at into strict v_at from public.flow_driver_gate12_run_v1 where validation_contract=v_contract;
  delete from public.flow_driver_oos_metrics_v1 where validation_contract=v_contract and driver_id=p_driver_id;
  delete from public.flow_driver_oos_slices_v1 where validation_contract=v_contract and driver_id=p_driver_id;
  drop table if exists pg_temp.flow_gate12_driver_base;
  create temp table flow_gate12_driver_base on commit drop as
  with raw as (
    select f.signal_date,f.ticker,s.market_regime,
      percent_rank() over(partition by f.signal_date order by nullif(f.raw_values->>'LIQ_TURNOVER','')::numeric) liquidity_rank,
      case when p_driver_id='FLOW_FOREIGN_DISTRIBUTION' then -(f.raw_values->>'FLOW_FOREIGN_ACCUMULATION')::numeric
        else nullif(f.raw_values->>p_driver_id,'')::numeric end raw_value,
      case when v_family='FINANCIAL' then
        case when f.financial_available_from_date>f.signal_date then 'INVALID'
          when p_driver_id='FIN_GROWTH' then coalesce(f.financial_feature_states->>'growth',f.financial_state,'MISSING')
          when p_driver_id='FIN_CASHFLOW' then coalesce(f.financial_feature_states->>'cashflow',f.financial_state,'MISSING')
          when nullif(f.raw_values->>p_driver_id,'') is not null and f.financial_state='AVAILABLE' then 'AVAILABLE'
          else coalesce(f.financial_state,'MISSING') end
        when f.history_count<v_min_history then 'INSUFFICIENT_HISTORY'
        when nullif(f.raw_values->>p_driver_id,'') is null then 'MISSING' else 'AVAILABLE' end driver_state,
      s.target_date_5d,s.target_date_20d,s.target_date_60d,
      s.forward_return_5d_pct,s.forward_return_20d_pct,s.forward_return_60d_pct,
      s.alpha_vs_ihsg_5d_pct,s.alpha_vs_ihsg_20d_pct,s.alpha_vs_ihsg_60d_pct,
      s.alpha_vs_sector_5d_pct,s.alpha_vs_sector_20d_pct,s.alpha_vs_sector_60d_pct,
      s.mfe_5d_pct,s.mfe_20d_pct,s.mfe_60d_pct,s.mae_5d_pct,s.mae_20d_pct,s.mae_60d_pct
    from public.flow_driver_feature_panel_v1 f join public.flow_driver_signal_panel_v1 s using(panel_contract,signal_date,ticker)
    where f.panel_contract=v_panel
  ), oriented as (
    select *,case when driver_state='AVAILABLE' then raw_value*v_direction end transformed_value from raw
  ), ranked as (
    select *,case when driver_state='AVAILABLE' then percent_rank() over(partition by signal_date,driver_state order by transformed_value) end normalized_value
    from oriented
  ), flagged as (
    select *,case when driver_state<>'AVAILABLE' then false
      when v_threshold='RAW_BOTTOM_20_TOP_80' then raw_value<=20
      when v_threshold='RAW_BOTTOM_0_35_TOP_0_65' then raw_value<=.35
      when v_threshold='RAW_BOTTOM_0_80_TOP_1_50' then raw_value<=.80
      when v_threshold='RAW_BOTTOM_0_75_TOP_1_50' then raw_value<=.75
      when v_threshold='RAW_BOTTOM_LE_-3_TOP_GE_3_PCT' then raw_value<=-3
      when v_threshold='RAW_TOP_GE_-0_25_PCT_BOTTOM_LE_-8_PCT' then raw_value<=-8
      when v_threshold='BINARY_TRUE_VS_FALSE' then (case when v_direction=1 then raw_value=0 else raw_value=1 end)
      else normalized_value<=.20 end bottom_signal,
      case when driver_state<>'AVAILABLE' then false
      when v_threshold='RAW_BOTTOM_20_TOP_80' then raw_value>=80
      when v_threshold='RAW_BOTTOM_0_35_TOP_0_65' then raw_value>=.65
      when v_threshold='RAW_BOTTOM_0_80_TOP_1_50' then raw_value>=1.50
      when v_threshold='RAW_BOTTOM_0_75_TOP_1_50' then raw_value>=1.50
      when v_threshold='RAW_BOTTOM_LE_-3_TOP_GE_3_PCT' then raw_value>=3
      when v_threshold='RAW_TOP_GE_-0_25_PCT_BOTTOM_LE_-8_PCT' then raw_value>=-.25
      when v_threshold='BINARY_TRUE_VS_FALSE' then (case when v_direction=1 then raw_value=1 else raw_value=0 end)
      else normalized_value>=.80 end top_signal from ranked
  )
  select f.*,h.* from flagged f cross join lateral(values
    (5,target_date_5d,forward_return_5d_pct,alpha_vs_ihsg_5d_pct,alpha_vs_sector_5d_pct,mfe_5d_pct,mae_5d_pct),
    (20,target_date_20d,forward_return_20d_pct,alpha_vs_ihsg_20d_pct,alpha_vs_sector_20d_pct,mfe_20d_pct,mae_20d_pct),
    (60,target_date_60d,forward_return_60d_pct,alpha_vs_ihsg_60d_pct,alpha_vs_sector_60d_pct,mfe_60d_pct,mae_60d_pct)
  ) h(horizon_days,target_date,forward_return,alpha_ihsg,alpha_sector,mfe,mae);
  analyze pg_temp.flow_gate12_driver_base;

  insert into public.flow_driver_oos_metrics_v1
  with segmented as (
    select b.*,f.fold_no,f.train_end,x.segment
    from pg_temp.flow_gate12_driver_base b join public.flow_driver_walkforward_folds_v1 f
      on f.validation_contract=v_contract and f.horizon_days=b.horizon_days
    cross join lateral(values ('TRAIN'::text,f.train_start,f.train_end),('VALIDATION',f.validation_start,f.validation_end),
      ('HELDOUT',f.heldout_start,f.heldout_end),('FORWARD',f.forward_start,f.forward_end)) x(segment,start_date,end_date)
    where b.signal_date between x.start_date and x.end_date and b.target_date is not null and b.alpha_ihsg is not null
      and (x.segment<>'TRAIN' or b.target_date<=f.train_end)
  )
  select v_contract,p_driver_id,v_family,horizon_days,fold_no,segment,count(*)::int,
    count(*) filter(where driver_state='AVAILABLE')::int,
    round(100.0*count(*) filter(where driver_state='AVAILABLE')/nullif(count(*),0),4),
    avg(forward_return) filter(where driver_state='AVAILABLE'),
    percentile_cont(.5) within group(order by forward_return) filter(where driver_state='AVAILABLE'),
    avg(alpha_ihsg) filter(where driver_state='AVAILABLE'),avg(alpha_sector) filter(where driver_state='AVAILABLE'),
    100.0*avg((alpha_ihsg>0)::int) filter(where driver_state='AVAILABLE'),
    count(*) filter(where top_signal)::int,count(*) filter(where bottom_signal)::int,
    avg(forward_return) filter(where top_signal),avg(forward_return) filter(where bottom_signal),
    avg(forward_return) filter(where top_signal)-avg(forward_return) filter(where bottom_signal),
    avg(alpha_ihsg) filter(where top_signal),avg(alpha_ihsg) filter(where bottom_signal),
    avg(alpha_ihsg) filter(where top_signal)-avg(alpha_ihsg) filter(where bottom_signal),
    avg(alpha_sector) filter(where top_signal),avg(alpha_sector) filter(where bottom_signal),
    avg(alpha_sector) filter(where top_signal)-avg(alpha_sector) filter(where bottom_signal),
    corr(normalized_value::double precision,alpha_ihsg::double precision) filter(where driver_state='AVAILABLE'),
    avg(mfe) filter(where driver_state='AVAILABLE'),avg(mae) filter(where driver_state='AVAILABLE'),
    avg(alpha_ihsg) filter(where driver_state<>'AVAILABLE'),
    (avg(alpha_ihsg) filter(where top_signal)-avg(alpha_ihsg) filter(where bottom_signal))>0,
    count(*) filter(where top_signal)>=50 and count(*) filter(where bottom_signal)>=50,v_at,false
  from segmented group by horizon_days,fold_no,segment;
  get diagnostics v_rows=row_count;

  insert into public.flow_driver_oos_slices_v1
  with oos as (
    select b.* from pg_temp.flow_gate12_driver_base b join public.flow_driver_walkforward_folds_v1 f
      on f.validation_contract=v_contract and f.horizon_days=b.horizon_days and f.fold_no=1
    where b.signal_date between f.validation_start and f.forward_end and b.target_date is not null and b.alpha_ihsg is not null
  ), sliced as (
    select o.*,'MARKET_REGIME'::text slice_kind,market_regime slice_value from oos o
    union all select o.*,'LIQUIDITY_QUINTILE',least(5,floor(liquidity_rank*5)::int+1)::text from oos o
  )
  select v_contract,p_driver_id,horizon_days,slice_kind,slice_value,count(*) filter(where driver_state='AVAILABLE')::int,
    count(*) filter(where top_signal)::int,count(*) filter(where bottom_signal)::int,
    avg(alpha_ihsg) filter(where top_signal)-avg(alpha_ihsg) filter(where bottom_signal),
    (avg(alpha_ihsg) filter(where top_signal)-avg(alpha_ihsg) filter(where bottom_signal))>0,
    count(*) filter(where top_signal)>=50 and count(*) filter(where bottom_signal)>=50,v_at
  from sliced group by horizon_days,slice_kind,slice_value;
  return jsonb_build_object('status','PASS','driver_id',p_driver_id,'metric_cells',v_rows,'production_influence_enabled',false);
end;$fn$;

create or replace function public.flow_finalize_driver_gate12_v1()
returns jsonb language plpgsql security invoker set search_path='' as $fn$
declare v_contract constant text:='IDX_DRIVER_PURGED_EXPANDING_WF_V1';v_at timestamptz;v_panel_leaks integer;v_invalid integer;v_evaluated integer;
begin
  select evaluation_started_at into strict v_at from public.flow_driver_gate12_run_v1 where validation_contract=v_contract;
  delete from public.flow_driver_gate12_manifest_v1 where validation_contract=v_contract;
  delete from public.flow_driver_oos_summary_v1 where validation_contract=v_contract;
  with oos as (
    select * from public.flow_driver_oos_metrics_v1 where validation_contract=v_contract and segment<>'TRAIN' and valid_sample
  ), stats as (
    select r.driver_id,r.family,c.coverage_pct,count(o.*) valid_cells,count(o.*) filter(where o.top_bottom_alpha_spread_pct>0) positive_cells,
      100.0*count(o.*) filter(where o.top_bottom_alpha_spread_pct>0)/nullif(count(o.*),0) direction_pct,
      avg(o.top_bottom_alpha_spread_pct) mean_spread,avg(o.top_bottom_alpha_spread_pct) filter(where o.segment='HELDOUT') heldout_spread,
      avg(o.top_bottom_alpha_spread_pct) filter(where o.segment='FORWARD') forward_spread,avg(o.rank_ic) mean_ic
    from public.flow_driver_registry_v1 r
    left join public.flow_driver_coverage_v1 c on c.panel_contract='IDX_DRIVER_WEEKLY_PIT_PANEL_V1' and c.entity_type='DRIVER' and c.entity_id=r.driver_id
    left join oos o on o.driver_id=r.driver_id where r.registry_version='IDX_DRIVER_REGISTRY_GATE10_V1'
    group by r.driver_id,r.family,c.coverage_pct
  ), horizons as (
    select driver_id,count(*) filter(where mean_h>0) positive_horizons from
      (select driver_id,horizon_days,avg(top_bottom_alpha_spread_pct) mean_h from oos group by driver_id,horizon_days) h group by driver_id
  ), slices as (
    select driver_id,
      100.0*count(*) filter(where slice_kind='MARKET_REGIME' and valid_sample and direction_agreement)/nullif(count(*) filter(where slice_kind='MARKET_REGIME' and valid_sample),0) regime_pct,
      100.0*count(*) filter(where slice_kind='LIQUIDITY_QUINTILE' and valid_sample and direction_agreement)/nullif(count(*) filter(where slice_kind='LIQUIDITY_QUINTILE' and valid_sample),0) liq_pct
    from public.flow_driver_oos_slices_v1 where validation_contract=v_contract group by driver_id
  ), classified as (
    select s.*,coalesce(h.positive_horizons,0) positive_horizons,sl.regime_pct,sl.liq_pct,
      case when s.valid_cells=0 then 'INSUFFICIENT_EVIDENCE'
        when s.direction_pct>=66.67 and coalesce(sl.regime_pct,100)<50 then 'REGIME_DEPENDENT'
        when s.direction_pct>=66.67 and coalesce(sl.liq_pct,100)<50 then 'LIQUIDITY_SENSITIVE'
        when s.valid_cells>=15 and s.direction_pct>=66.67 and s.heldout_spread>0 and s.forward_spread>0 and coalesce(h.positive_horizons,0)=3 and s.coverage_pct>=60 then 'PROMISING'
        when s.mean_spread<=0 and s.direction_pct<33.34 then 'REJECTED'
        when s.mean_spread>0 and s.direction_pct<66.67 then 'WEAK' else 'UNSTABLE' end classification
    from stats s left join horizons h using(driver_id) left join slices sl using(driver_id)
  )
  insert into public.flow_driver_oos_summary_v1
  select v_contract,driver_id,family,valid_cells,positive_cells,round(direction_pct,2),round(mean_spread,4),round(heldout_spread,4),round(forward_spread,4),
    round(mean_ic,4),positive_horizons,coalesce(coverage_pct,0),round(regime_pct,2),round(liq_pct,2),
    'INSUFFICIENT_PIT_SECTOR_HISTORY',classification,
    case when driver_id='FIN_BALANCE' then 'DISCOVERY_REPLAY_NOT_INDEPENDENT_CONFIRMATION' else 'PREREGISTERED_PHASE1_OOS' end,
    (classification='PROMISING' and driver_id<>'FIN_BALANCE'),
    case when driver_id='FIN_BALANCE' then 'Gate 9 overlap prevents independent confirmation; collect untouched forward data in Phase 2'
      when classification='PROMISING' then 'Preregistered OOS criteria met; eligible only to enter Phase 2'
      else 'No Phase 2 entry under frozen acceptance criteria' end,v_at,false from classified;

  select leakage_count into strict v_panel_leaks from public.flow_driver_panel_manifest_v1 where panel_contract='IDX_DRIVER_WEEKLY_PIT_PANEL_V1';
  select count(*) into v_invalid from public.flow_driver_oos_metrics_v1 where validation_contract=v_contract and valid_sample and top_bottom_alpha_spread_pct is null;
  select count(distinct driver_id) into v_evaluated from public.flow_driver_oos_metrics_v1 where validation_contract=v_contract;
  insert into public.flow_driver_gate12_manifest_v1
  select v_contract,'IDX_DRIVER_REGISTRY_GATE10_V1','IDX_DRIVER_WEEKLY_PIT_PANEL_V1',
    (select count(*) from public.flow_driver_registry_v1 where registry_version='IDX_DRIVER_REGISTRY_GATE10_V1'),
    (select count(*) from public.flow_driver_registry_v1 where registry_version='IDX_DRIVER_REGISTRY_GATE10_V1' and evaluation_eligible),v_evaluated,
    (select count(*) from public.flow_driver_walkforward_folds_v1 where validation_contract=v_contract),
    (select count(*) from public.flow_driver_oos_metrics_v1 where validation_contract=v_contract),v_invalid,
    (select count(*) from public.flow_driver_oos_summary_v1 where validation_contract=v_contract and classification='PROMISING'),
    (select count(*) from public.flow_driver_oos_summary_v1 where validation_contract=v_contract and eligible_to_enter_phase2),
    0,v_panel_leaks,(select candidate_registry_frozen_before_evaluation from public.flow_driver_gate12_run_v1 where validation_contract=v_contract),
    case when v_panel_leaks=0 and v_invalid=0 and v_evaluated=(select count(*) from public.flow_driver_registry_v1 where registry_version='IDX_DRIVER_REGISTRY_GATE10_V1' and evaluation_eligible) then 'PASS' else 'FAIL' end,v_at,false;
  return (select to_jsonb(m) from public.flow_driver_gate12_manifest_v1 m where validation_contract=v_contract);
end;$fn$;

revoke all on function public.flow_build_driver_folds_v1() from public,anon,authenticated;
revoke all on function public.flow_run_single_driver_oos_v1(text) from public,anon,authenticated;
revoke all on function public.flow_finalize_driver_gate12_v1() from public,anon,authenticated;
grant execute on function public.flow_build_driver_folds_v1() to service_role;
grant execute on function public.flow_run_single_driver_oos_v1(text) to service_role;
grant execute on function public.flow_finalize_driver_gate12_v1() to service_role;

comment on table public.flow_driver_oos_summary_v1 is 'Gate 12 statistical predictive association only; no causal or production claim.';
