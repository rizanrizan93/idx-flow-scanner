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
    join public.flow_driver_registry_v1 r
      on r.registry_version='IDX_DRIVER_REGISTRY_GATE10_V1' and r.driver_id=c.driver_id
    where f.panel_contract=v_panel
  ), comp_oriented as (
    select *,case when driver_state='AVAILABLE' then raw_value*direction_hypothesis end transformed_value
    from comp_raw
  ), comp_norm as (
    select *,case when driver_state='AVAILABLE' then
      percent_rank() over(partition by signal_date,driver_id,driver_state order by transformed_value) end normalized_value
    from comp_oriented
  ), grouped as (
    select signal_date,ticker,
      count(*) filter(where driver_state='AVAILABLE' and normalized_value is not null) available_components,
      min(normalized_value) filter(where driver_state='AVAILABLE') interaction_score,
      (count(*)=v_component_count and bool_and(driver_state='AVAILABLE' and normalized_value is not null)) component_available,
      (count(*)=v_component_count and bool_and(driver_state='AVAILABLE' and normalized_value>=0.80)) confluence_signal
    from comp_norm group by signal_date,ticker
  ), liq_raw as (
    select signal_date,ticker,nullif(raw_values->>'LIQ_TURNOVER','')::numeric raw_value
    from public.flow_driver_feature_panel_v1 where panel_contract=v_panel
  ), liq as (
    select signal_date,ticker,case when raw_value is not null then percent_rank() over(partition by signal_date order by raw_value) end liquidity_rank
    from liq_raw
  )
  select g.*,s.market_regime,l.liquidity_rank,
    s.target_date_5d,s.target_date_20d,s.target_date_60d,
    s.forward_return_5d_pct,s.forward_return_20d_pct,s.forward_return_60d_pct,
    s.alpha_vs_ihsg_5d_pct,s.alpha_vs_ihsg_20d_pct,s.alpha_vs_ihsg_60d_pct,
    s.mfe_5d_pct,s.mfe_20d_pct,s.mfe_60d_pct,
    s.mae_5d_pct,s.mae_20d_pct,s.mae_60d_pct
  from grouped g
  join public.flow_driver_signal_panel_v1 s
    on s.panel_contract=v_panel and s.signal_date=g.signal_date and s.ticker=g.ticker
  left join liq l on l.signal_date=g.signal_date and l.ticker=g.ticker;

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

revoke all on function public.flow_run_interaction_oos_v1(text) from public,anon,authenticated;
grant execute on function public.flow_run_interaction_oos_v1(text) to service_role;
