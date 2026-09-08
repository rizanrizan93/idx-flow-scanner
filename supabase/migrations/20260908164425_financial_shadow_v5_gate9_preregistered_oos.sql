-- Gate 9 preregistered OOS contract. Candidate set, thresholds, direction and
-- possible promotion weight are frozen before outcome evaluation.

create table if not exists public.flow_financial_shadow_candidate_registry_v5 (
  calibration_contract text not null,
  factor_name text not null,
  factor_column text not null,
  direction_sign smallint not null check(direction_sign in (-1,1)),
  bottom_threshold numeric not null,
  top_threshold numeric not null,
  promotion_eligible boolean not null,
  preregistered_weight_pct numeric not null check(preregistered_weight_pct between 0 and 5),
  family_budget_pct numeric not null check(family_budget_pct between 0 and 5),
  production_influence_enabled boolean not null check(production_influence_enabled=false),
  frozen_at timestamptz not null default now(),
  primary key(calibration_contract,factor_name)
);
alter table public.flow_financial_shadow_candidate_registry_v5 enable row level security;
revoke all on public.flow_financial_shadow_candidate_registry_v5 from public,anon,authenticated,service_role;
grant select,insert,update,delete on public.flow_financial_shadow_candidate_registry_v5 to service_role;

insert into public.flow_financial_shadow_candidate_registry_v5 values
('FINANCIAL_V5_PURGED_EXPANDING_WF_1','FIN_QUALITY','quality_score',1,20,80,false,0,5,false,now()),
('FINANCIAL_V5_PURGED_EXPANDING_WF_1','FIN_GROWTH','growth_score',1,20,80,false,0,5,false,now()),
('FINANCIAL_V5_PURGED_EXPANDING_WF_1','FIN_BALANCE','balance_score',1,20,80,false,0,5,false,now()),
('FINANCIAL_V5_PURGED_EXPANDING_WF_1','FIN_CASHFLOW','cashflow_score',1,20,80,false,0,5,false,now()),
('FINANCIAL_V5_PURGED_EXPANDING_WF_1','FIN_COMPOSITE','financial_shadow_score',1,20,80,true,5,5,false,now())
on conflict(calibration_contract,factor_name) do update set
 factor_column=excluded.factor_column,direction_sign=excluded.direction_sign,bottom_threshold=excluded.bottom_threshold,
 top_threshold=excluded.top_threshold,promotion_eligible=excluded.promotion_eligible,preregistered_weight_pct=excluded.preregistered_weight_pct,
 family_budget_pct=excluded.family_budget_pct,production_influence_enabled=false;

create table if not exists public.flow_financial_shadow_walkforward_folds_v5 (
  calibration_contract text not null,
  horizon_days integer not null check(horizon_days in (5,20,60)),
  fold_no integer not null check(fold_no in (1,2)),
  train_start date not null,train_end date not null,
  validation_start date not null,validation_end date not null,
  heldout_start date not null,heldout_end date not null,
  forward_start date not null,forward_end date not null,
  purge_rule text not null,
  source_verified boolean not null check(source_verified=true),
  created_at timestamptz not null default now(),
  primary key(calibration_contract,horizon_days,fold_no)
);

create table if not exists public.flow_financial_shadow_oos_metrics_v5 (
  calibration_contract text not null,
  factor_name text not null,
  horizon_days integer not null,
  fold_no integer not null,
  segment text not null check(segment in ('TRAIN','VALIDATION','HELDOUT','FORWARD')),
  top_n integer not null,bottom_n integer not null,
  top_mean_alpha_pct numeric,bottom_mean_alpha_pct numeric,spread_alpha_pct numeric,
  top_hit_rate_pct numeric,bottom_hit_rate_pct numeric,
  valid_sample boolean not null,
  calculated_at timestamptz not null default now(),
  primary key(calibration_contract,factor_name,horizon_days,fold_no,segment)
);

create table if not exists public.flow_financial_shadow_gate9_summary_v5 (
  calibration_contract text not null,
  factor_name text not null,
  valid_oos_checks integer not null,
  positive_oos_checks integer not null,
  direction_agreement_pct numeric,
  mean_oos_spread_pct numeric,
  min_oos_spread_pct numeric,
  stddev_oos_spread_pct numeric,
  mean_validation_spread_pct numeric,
  mean_heldout_spread_pct numeric,
  mean_forward_spread_pct numeric,
  positive_horizons integer not null,
  panel_coverage_pct numeric not null,
  stable_oos_pass boolean not null,
  promotion_ready boolean not null,
  preregistered_weight_pct numeric not null,
  production_influence_enabled boolean not null check(production_influence_enabled=false),
  decision_reason text not null,
  calculated_at timestamptz not null default now(),
  primary key(calibration_contract,factor_name)
);

create table if not exists public.flow_financial_shadow_missing_analysis_v5 (
  calibration_contract text not null,
  sector text not null,
  financial_state text not null,
  rows integer not null,
  pct_of_sector numeric not null,
  calculated_at timestamptz not null default now(),
  primary key(calibration_contract,sector,financial_state)
);

alter table public.flow_financial_shadow_walkforward_folds_v5 enable row level security;
alter table public.flow_financial_shadow_oos_metrics_v5 enable row level security;
alter table public.flow_financial_shadow_gate9_summary_v5 enable row level security;
alter table public.flow_financial_shadow_missing_analysis_v5 enable row level security;
revoke all on public.flow_financial_shadow_walkforward_folds_v5,public.flow_financial_shadow_oos_metrics_v5,public.flow_financial_shadow_gate9_summary_v5,public.flow_financial_shadow_missing_analysis_v5 from public,anon,authenticated,service_role;
grant select,insert,update,delete on public.flow_financial_shadow_walkforward_folds_v5,public.flow_financial_shadow_oos_metrics_v5,public.flow_financial_shadow_gate9_summary_v5,public.flow_financial_shadow_missing_analysis_v5 to service_role;

create or replace function public.flow_run_financial_shadow_gate9_v5()
returns jsonb
language plpgsql
security invoker
set search_path=''
as $fn$
declare
  v_contract constant text := 'FINANCIAL_V5_PURGED_EXPANDING_WF_1';
  v_sample constant text := 'FINANCIAL_V5_WEEKLY_LAST_TRADING_DAY_PIT_1';
  v_coverage numeric;
  v_result jsonb;
begin
  delete from public.flow_financial_shadow_walkforward_folds_v5 where calibration_contract=v_contract;
  delete from public.flow_financial_shadow_oos_metrics_v5 where calibration_contract=v_contract;
  delete from public.flow_financial_shadow_gate9_summary_v5 where calibration_contract=v_contract;
  delete from public.flow_financial_shadow_missing_analysis_v5 where calibration_contract=v_contract;

  with h as (
    select 5 horizon_days,as_of_date,target_date_5d target_date,clean_alpha_vs_sector_5d_pct alpha from public.flow_financial_shadow_panel_v5 where sample_contract=v_sample
    union all select 20,as_of_date,target_date_20d,clean_alpha_vs_sector_20d_pct from public.flow_financial_shadow_panel_v5 where sample_contract=v_sample
    union all select 60,as_of_date,target_date_60d,clean_alpha_vs_sector_60d_pct from public.flow_financial_shadow_panel_v5 where sample_contract=v_sample
  ), dates as (
    select horizon_days,as_of_date,row_number() over(partition by horizon_days order by as_of_date) rn,
      count(*) over(partition by horizon_days) n
    from (select distinct horizon_days,as_of_date from h where alpha is not null and target_date is not null) d
  ), bounds as (
    select horizon_days,min(as_of_date) min_date,max(as_of_date) max_date,
      max(as_of_date) filter(where rn<=floor(n*0.40)) f1_train_end,
      min(as_of_date) filter(where rn>floor(n*0.40)) f1_val_start,
      max(as_of_date) filter(where rn<=floor(n*0.60)) f1_val_end,
      min(as_of_date) filter(where rn>floor(n*0.60)) f1_hold_start,
      max(as_of_date) filter(where rn<=floor(n*0.80)) f1_hold_end,
      min(as_of_date) filter(where rn>floor(n*0.80)) f1_fwd_start,
      max(as_of_date) filter(where rn<=floor(n*0.55)) f2_train_end,
      min(as_of_date) filter(where rn>floor(n*0.55)) f2_val_start,
      max(as_of_date) filter(where rn<=floor(n*0.70)) f2_val_end,
      min(as_of_date) filter(where rn>floor(n*0.70)) f2_hold_start,
      max(as_of_date) filter(where rn<=floor(n*0.85)) f2_hold_end,
      min(as_of_date) filter(where rn>floor(n*0.85)) f2_fwd_start
    from dates group by horizon_days
  )
  insert into public.flow_financial_shadow_walkforward_folds_v5
  select v_contract,horizon_days,1,min_date,f1_train_end,f1_val_start,f1_val_end,f1_hold_start,f1_hold_end,f1_fwd_start,max_date,
    'PURGE_TRAIN_ROWS_UNLESS_TARGET_DATE_LE_TRAIN_END',true,now() from bounds
  union all
  select v_contract,horizon_days,2,min_date,f2_train_end,f2_val_start,f2_val_end,f2_hold_start,f2_hold_end,f2_fwd_start,max_date,
    'PURGE_TRAIN_ROWS_UNLESS_TARGET_DATE_LE_TRAIN_END',true,now() from bounds;

  with long_panel as (
    select p.as_of_date,p.quality_score,p.growth_score,p.balance_score,p.cashflow_score,p.financial_shadow_score,
      5 horizon_days,p.target_date_5d target_date,p.clean_alpha_vs_sector_5d_pct alpha from public.flow_financial_shadow_panel_v5 p where p.sample_contract=v_sample
    union all select p.as_of_date,p.quality_score,p.growth_score,p.balance_score,p.cashflow_score,p.financial_shadow_score,
      20,p.target_date_20d,p.clean_alpha_vs_sector_20d_pct from public.flow_financial_shadow_panel_v5 p where p.sample_contract=v_sample
    union all select p.as_of_date,p.quality_score,p.growth_score,p.balance_score,p.cashflow_score,p.financial_shadow_score,
      60,p.target_date_60d,p.clean_alpha_vs_sector_60d_pct from public.flow_financial_shadow_panel_v5 p where p.sample_contract=v_sample
  ), factor_rows as (
    select p.*,r.factor_name,r.top_threshold,r.bottom_threshold,
      case r.factor_name when 'FIN_QUALITY' then p.quality_score when 'FIN_GROWTH' then p.growth_score when 'FIN_BALANCE' then p.balance_score when 'FIN_CASHFLOW' then p.cashflow_score else p.financial_shadow_score end factor_score
    from long_panel p cross join public.flow_financial_shadow_candidate_registry_v5 r
    where r.calibration_contract=v_contract
  ), segmented as (
    select x.factor_name,x.horizon_days,f.fold_no,s.segment,x.alpha,x.factor_score,x.top_threshold,x.bottom_threshold
    from factor_rows x
    join public.flow_financial_shadow_walkforward_folds_v5 f on f.calibration_contract=v_contract and f.horizon_days=x.horizon_days
    cross join lateral (values
      ('TRAIN'::text,f.train_start,f.train_end),('VALIDATION',f.validation_start,f.validation_end),('HELDOUT',f.heldout_start,f.heldout_end),('FORWARD',f.forward_start,f.forward_end)
    ) s(segment,start_date,end_date)
    where x.as_of_date between s.start_date and s.end_date
      and x.alpha is not null and x.factor_score is not null
      and (s.segment<>'TRAIN' or x.target_date<=f.train_end)
  )
  insert into public.flow_financial_shadow_oos_metrics_v5
  select v_contract,factor_name,horizon_days,fold_no,segment,
    count(*) filter(where factor_score>=top_threshold),count(*) filter(where factor_score<=bottom_threshold),
    avg(alpha) filter(where factor_score>=top_threshold),avg(alpha) filter(where factor_score<=bottom_threshold),
    avg(alpha) filter(where factor_score>=top_threshold)-avg(alpha) filter(where factor_score<=bottom_threshold),
    100.0*avg((alpha>0)::int) filter(where factor_score>=top_threshold),
    100.0*avg((alpha>0)::int) filter(where factor_score<=bottom_threshold),
    (count(*) filter(where factor_score>=top_threshold)>=50 and count(*) filter(where factor_score<=bottom_threshold)>=50),now()
  from segmented group by factor_name,horizon_days,fold_no,segment;

  select round(100.0*count(*) filter(where financial_shadow_score is not null)/nullif(count(*),0),2) into v_coverage
  from public.flow_financial_shadow_panel_v5 where sample_contract=v_sample;

  insert into public.flow_financial_shadow_missing_analysis_v5
  select v_contract,coalesce(sector,'UNKNOWN'),financial_state,count(*),
    round(100.0*count(*)/sum(count(*)) over(partition by coalesce(sector,'UNKNOWN')),2),now()
  from public.flow_financial_shadow_panel_v5 where sample_contract=v_sample
  group by coalesce(sector,'UNKNOWN'),financial_state;

  with oos as (
    select m.* from public.flow_financial_shadow_oos_metrics_v5 m
    where m.calibration_contract=v_contract and m.segment<>'TRAIN' and m.valid_sample
  ), factor_stats as (
    select r.factor_name,r.promotion_eligible,r.preregistered_weight_pct,
      count(o.*) valid_checks,count(o.*) filter(where o.spread_alpha_pct>0) positive_checks,
      100.0*count(o.*) filter(where o.spread_alpha_pct>0)/nullif(count(o.*),0) direction_pct,
      avg(o.spread_alpha_pct) mean_spread,min(o.spread_alpha_pct) min_spread,stddev_samp(o.spread_alpha_pct) sd_spread,
      avg(o.spread_alpha_pct) filter(where o.segment='VALIDATION') mean_val,
      avg(o.spread_alpha_pct) filter(where o.segment='HELDOUT') mean_hold,
      avg(o.spread_alpha_pct) filter(where o.segment='FORWARD') mean_fwd
    from public.flow_financial_shadow_candidate_registry_v5 r
    left join oos o on o.factor_name=r.factor_name
    where r.calibration_contract=v_contract
    group by r.factor_name,r.promotion_eligible,r.preregistered_weight_pct
  ), horizon_stats as (
    select factor_name,count(*) filter(where mean_h>0) positive_horizons
    from (select factor_name,horizon_days,avg(spread_alpha_pct) mean_h from oos group by factor_name,horizon_days) h group by factor_name
  )
  insert into public.flow_financial_shadow_gate9_summary_v5
  select v_contract,s.factor_name,s.valid_checks,s.positive_checks,round(s.direction_pct,2),round(s.mean_spread,4),round(s.min_spread,4),round(s.sd_spread,4),
    round(s.mean_val,4),round(s.mean_hold,4),round(s.mean_fwd,4),coalesce(h.positive_horizons,0),v_coverage,
    (s.valid_checks>=15 and s.direction_pct>=66.67 and s.mean_hold>0 and s.mean_fwd>0 and coalesce(h.positive_horizons,0)=3 and v_coverage>=70),
    (s.promotion_eligible and s.valid_checks>=15 and s.direction_pct>=66.67 and s.mean_hold>0 and s.mean_fwd>0 and coalesce(h.positive_horizons,0)=3 and v_coverage>=70),
    s.preregistered_weight_pct,false,
    case when s.promotion_eligible and s.valid_checks>=15 and s.direction_pct>=66.67 and s.mean_hold>0 and s.mean_fwd>0 and coalesce(h.positive_horizons,0)=3 and v_coverage>=70
         then 'PREREGISTERED_COMPOSITE_PASSES_OOS; READY_FOR_BOUNDED_5PCT_INTEGRATION'
         else 'NO_PRODUCTION_PROMOTION; OOS_OR_ELIGIBILITY_CRITERIA_NOT_MET' end,now()
  from factor_stats s left join horizon_stats h using(factor_name);

  select jsonb_build_object(
    'status','OK','calibration_contract',v_contract,'panel_coverage_pct',v_coverage,
    'folds',(select count(*) from public.flow_financial_shadow_walkforward_folds_v5 where calibration_contract=v_contract),
    'oos_metric_rows',(select count(*) from public.flow_financial_shadow_oos_metrics_v5 where calibration_contract=v_contract),
    'promotion_ready_factors',(select count(*) from public.flow_financial_shadow_gate9_summary_v5 where calibration_contract=v_contract and promotion_ready),
    'production_influence_enabled',false
  ) into v_result;
  return v_result;
end;
$fn$;

revoke all on function public.flow_run_financial_shadow_gate9_v5() from public,anon,authenticated,service_role;
grant execute on function public.flow_run_financial_shadow_gate9_v5() to service_role;
