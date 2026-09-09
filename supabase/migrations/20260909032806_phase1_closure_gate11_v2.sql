create table if not exists public.flow_driver_panel_lineage_v2(
  panel_contract text not null,
  signal_date date not null,
  ticker text not null,
  market_source_max_date date,
  stock_source_max_date date,
  financial_current_available_from_date date,
  financial_prior_available_from_date date,
  sector_history_state text not null,
  normalization_scope text not null,
  calculated_at timestamptz not null default now(),
  production_influence_enabled boolean not null default false check(production_influence_enabled=false),
  primary key(panel_contract,signal_date,ticker)
);
alter table public.flow_driver_panel_lineage_v2 enable row level security;
revoke all on table public.flow_driver_panel_lineage_v2 from public,anon,authenticated;
grant select,insert,update,delete on table public.flow_driver_panel_lineage_v2 to service_role;

create or replace function public.flow_refresh_driver_signal_stage_v2()
returns jsonb
language plpgsql
security invoker
set search_path=''
set work_mem='64MB'
as $fn$
declare
  v_contract constant text := 'IDX_DRIVER_WEEKLY_PIT_PANEL_V2';
  v_rows bigint;
  v_at timestamptz := clock_timestamp();
begin
  delete from public.flow_driver_panel_manifest_v1 where panel_contract=v_contract;
  delete from public.flow_driver_coverage_v1 where panel_contract=v_contract;
  delete from public.flow_driver_panel_lineage_v2 where panel_contract=v_contract;
  delete from public.flow_driver_feature_panel_v1 where panel_contract=v_contract;
  delete from public.flow_driver_signal_panel_v1 where panel_contract=v_contract;

  insert into public.flow_driver_signal_panel_v1
  with ihsg as (
    select trade_date,100.0*(close/nullif(lag(close,20) over(order by trade_date),0)-1.0) ihsg_return20
    from public.flow_official_index_summary where index_code='COMPOSITE' and source_verified
  )
  select v_contract,f.as_of_date,f.ticker,f.sector,'CURRENT_REGISTRY_CLASSIFICATION_NOT_HISTORICAL',
    case when i.ihsg_return20 is null then 'INSUFFICIENT_HISTORY' when i.ihsg_return20>=3 then 'RISK_ON'
      when i.ihsg_return20<=-3 then 'RISK_OFF' else 'NEUTRAL' end,
    i.ihsg_return20,
    'flow_financial_shadow_panel_v5+flow_market_learning_labels_clean_v4c',
    concat('FIN:',coalesce(f.current_filing_id,'NONE'),':MARKET:',f.as_of_date,':',f.ticker),
    (f.as_of_date::timestamp+time '16:15') at time zone 'Asia/Jakarta',f.as_of_date,
    l.target_date_5d,l.target_date_20d,l.target_date_60d,
    l.clean_forward_return_5d_pct,l.clean_forward_return_20d_pct,l.clean_forward_return_60d_pct,
    l.clean_alpha_vs_ihsg_5d_pct,l.clean_alpha_vs_ihsg_20d_pct,l.clean_alpha_vs_ihsg_60d_pct,
    null,null,null,l.clean_mfe_5d_pct,l.clean_mfe_20d_pct,l.clean_mfe_60d_pct,
    l.clean_mae_5d_pct,l.clean_mae_20d_pct,l.clean_mae_60d_pct,
    'INVALID_CURRENT_SECTOR_CLASSIFICATION_NOT_HISTORICAL',
    jsonb_build_object('financial_contract',f.sample_contract,'outcome_contract',l.clean_path_version,
      'target_is_outcome_not_feature',true,'sector_benchmark_fail_closed',true,
      'registry_version','IDX_DRIVER_REGISTRY_GATE10_V2','stage','SIGNAL'),v_at,false
  from public.flow_financial_shadow_panel_v5 f
  join public.flow_market_learning_labels_clean_v4c l on l.as_of_date=f.as_of_date and l.ticker=f.ticker and l.feature_contract='MARKET_MEMORY_V4_1'
  left join ihsg i on i.trade_date=f.as_of_date
  where f.sample_contract='FINANCIAL_V5_WEEKLY_LAST_TRADING_DAY_PIT_1';
  get diagnostics v_rows=row_count;
  return jsonb_build_object('status','SIGNAL_STAGE_READY','signal_rows',v_rows,'panel_contract',v_contract,'production_influence_enabled',false);
end;$fn$;

create or replace function public.flow_finalize_driver_panel_v2()
returns jsonb
language plpgsql
security invoker
set search_path=''
set work_mem='48MB'
as $fn$
declare
  v_contract constant text := 'IDX_DRIVER_WEEKLY_PIT_PANEL_V2';
  v_registry constant text := 'IDX_DRIVER_REGISTRY_GATE10_V2';
  v_at timestamptz := clock_timestamp();
  v_signals bigint; v_features bigint; v_observations bigint; v_available bigint;
  v_future_current bigint; v_future_prior bigint; v_future_market bigint; v_future_stock bigint;
  v_sector bigint; v_norm bigint; v_target bigint; v_ownership bigint; v_event bigint;
  v_revision bigint; v_leaks bigint; v_zero_coverage integer; v_digest text;
begin
  select count(*) into v_signals from public.flow_driver_signal_panel_v1 where panel_contract=v_contract;
  select count(*) into v_features from public.flow_driver_feature_panel_v1 where panel_contract=v_contract;
  if v_signals=0 or v_features<>v_signals then raise exception 'Gate11 V2 stages incomplete: signals %, features %',v_signals,v_features; end if;
  delete from public.flow_driver_panel_manifest_v1 where panel_contract=v_contract;
  delete from public.flow_driver_coverage_v1 where panel_contract=v_contract;

  drop table if exists pg_temp.flow_gate11_state_counts_v2;
  create temp table flow_gate11_state_counts_v2 on commit drop as
  with state_rows as (
    select r.driver_id,r.family,
      case when r.family='FINANCIAL' then
        case when f.financial_available_from_date>f.signal_date then 'INVALID'
          when r.driver_id='FIN_GROWTH' then coalesce(f.financial_feature_states->>'growth',f.financial_state,'MISSING')
          when r.driver_id='FIN_CASHFLOW' then coalesce(f.financial_feature_states->>'cashflow',f.financial_state,'MISSING')
          when nullif(f.raw_values->>r.driver_id,'') is not null and f.financial_state='AVAILABLE' then 'AVAILABLE'
          else coalesce(f.financial_state,'MISSING') end
        when f.history_count<r.minimum_history_sessions then 'INSUFFICIENT_HISTORY'
        when nullif(f.raw_values->>r.driver_id,'') is null then 'MISSING' else 'AVAILABLE' end driver_state
    from public.flow_driver_feature_panel_v1 f
    join public.flow_driver_registry_v1 r on r.registry_version=v_registry and r.evaluation_eligible
    where f.panel_contract=v_contract
  )
  select driver_id,family,count(*) total_rows,
    count(*) filter(where driver_state='AVAILABLE') available_rows,
    count(*) filter(where driver_state='MISSING') missing_rows,
    count(*) filter(where driver_state='STALE') stale_rows,
    count(*) filter(where driver_state='INVALID') invalid_rows,
    count(*) filter(where driver_state='NOT_APPLICABLE') not_applicable_rows,
    count(*) filter(where driver_state='INSUFFICIENT_HISTORY') insufficient_history_rows
  from state_rows group by driver_id,family;

  insert into public.flow_driver_coverage_v1
  select v_contract,'DRIVER',r.driver_id,coalesce(c.total_rows,0),coalesce(c.available_rows,0),coalesce(c.missing_rows,0),
    coalesce(c.stale_rows,0),coalesce(c.invalid_rows,0),coalesce(c.not_applicable_rows,0),coalesce(c.insufficient_history_rows,0),
    coalesce(round(100.0*c.available_rows/nullif(c.total_rows,0),4),0),
    coalesce(round(100.0*c.stale_rows/nullif(c.total_rows,0),4),0),
    coalesce(round(100.0*c.invalid_rows/nullif(c.total_rows,0),4),0),v_at
  from public.flow_driver_registry_v1 r left join pg_temp.flow_gate11_state_counts_v2 c on c.driver_id=r.driver_id
  where r.registry_version=v_registry;

  insert into public.flow_driver_coverage_v1
  select v_contract,'FAMILY',r.family,coalesce(sum(c.total_rows),0),coalesce(sum(c.available_rows),0),coalesce(sum(c.missing_rows),0),
    coalesce(sum(c.stale_rows),0),coalesce(sum(c.invalid_rows),0),coalesce(sum(c.not_applicable_rows),0),coalesce(sum(c.insufficient_history_rows),0),
    coalesce(round(100.0*sum(c.available_rows)/nullif(sum(c.total_rows),0),4),0),
    coalesce(round(100.0*sum(c.stale_rows)/nullif(sum(c.total_rows),0),4),0),
    coalesce(round(100.0*sum(c.invalid_rows)/nullif(sum(c.total_rows),0),4),0),v_at
  from public.flow_driver_registry_v1 r left join pg_temp.flow_gate11_state_counts_v2 c on c.driver_id=r.driver_id
  where r.registry_version=v_registry group by r.family;

  select coalesce(sum(total_rows),0),coalesce(sum(available_rows),0) into v_observations,v_available from pg_temp.flow_gate11_state_counts_v2;
  select count(*) into v_future_current from public.flow_driver_feature_panel_v1 where panel_contract=v_contract and financial_available_from_date is not null and financial_available_from_date>signal_date;
  select count(*) into v_future_prior from public.flow_driver_panel_lineage_v2 where panel_contract=v_contract and financial_prior_available_from_date is not null and financial_prior_available_from_date>signal_date;
  select count(*) filter(where market_source_max_date>signal_date),count(*) filter(where stock_source_max_date>signal_date),
         count(*) filter(where sector_history_state<>'CURRENT_REGISTRY_CLASSIFICATION_NOT_HISTORICAL'),
         count(*) filter(where normalization_scope<>'SAME_SIGNAL_DATE_ONLY')
    into v_future_market,v_future_stock,v_sector,v_norm
  from public.flow_driver_panel_lineage_v2 where panel_contract=v_contract;
  select count(*) into v_target from public.flow_driver_feature_panel_v1 f cross join lateral jsonb_object_keys(f.raw_values) k(key)
  where f.panel_contract=v_contract and k.key ~* '(forward|target|alpha|mfe|mae|outcome)';
  select count(*) into v_ownership from public.flow_driver_feature_panel_v1 f join public.flow_driver_registry_v1 r on r.registry_version=v_registry and r.family='OWNERSHIP_FREE_FLOAT'
  where f.panel_contract=v_contract and nullif(f.raw_values->>r.driver_id,'') is not null;
  select count(*) into v_event from public.flow_driver_feature_panel_v1 f join public.flow_driver_registry_v1 r on r.registry_version=v_registry and r.family='CORPORATE_EVENT'
  where f.panel_contract=v_contract and nullif(f.raw_values->>r.driver_id,'') is not null;
  v_revision:=v_future_current+v_future_prior;
  v_leaks:=v_future_current+v_future_prior+v_future_market+v_future_stock+v_sector+v_norm+v_ownership+v_event;
  select count(*) into v_zero_coverage from public.flow_driver_coverage_v1 c
  join public.flow_driver_registry_v1 r on r.registry_version=v_registry and r.driver_id=c.entity_id and r.evaluation_eligible
  where c.panel_contract=v_contract and c.entity_type='DRIVER' and c.coverage_pct=0;
  select md5(string_agg(md5(concat_ws('|',f.signal_date::text,f.ticker,f.raw_values::text,coalesce(f.financial_state,''),
    coalesce(f.financial_feature_states::text,''),coalesce(f.financial_available_from_date::text,''),coalesce(f.current_filing_id,''),coalesce(f.prior_filing_id,''))),'' order by f.signal_date,f.ticker))
  into v_digest from public.flow_driver_feature_panel_v1 f where f.panel_contract=v_contract;

  insert into public.flow_driver_panel_manifest_v1
  select v_contract,v_registry,v_signals,v_observations,
    (select count(distinct signal_date) from public.flow_driver_signal_panel_v1 where panel_contract=v_contract),
    (select count(distinct ticker) from public.flow_driver_signal_panel_v1 where panel_contract=v_contract),
    (select count(distinct sector) from public.flow_driver_signal_panel_v1 where panel_contract=v_contract),
    v_available,round(100.0*v_available/nullif(v_observations,0),4),
    coalesce((select round(100.0*sum(missing_rows)/nullif(sum(total_rows),0),4) from pg_temp.flow_gate11_state_counts_v2),0),
    coalesce((select round(100.0*sum(stale_rows)/nullif(sum(total_rows),0),4) from pg_temp.flow_gate11_state_counts_v2),0),
    coalesce((select round(100.0*sum(invalid_rows)/nullif(sum(total_rows),0),4) from pg_temp.flow_gate11_state_counts_v2),0),
    jsonb_build_object('future_financial_current',v_future_current,'future_financial_prior',v_future_prior,
      'future_flow_or_market_source',v_future_market,'future_stock_source',v_future_stock,
      'future_sector_membership_feature_rows',v_sector,'lookahead_normalization',v_norm,
      'forward_or_outcome_key_used_in_features',v_target,'ownership_feature_rows',v_ownership,
      'event_feature_rows',v_event,'evaluation_eligible_zero_coverage',v_zero_coverage,
      'panel_digest_md5',v_digest,'audit_mode','COMPUTED_NOT_LITERAL'),
    v_leaks,v_revision,v_target,
    case when v_leaks=0 and v_target=0 and v_zero_coverage=0 then 'COMPLETE' else 'FAILED_AUDIT' end,v_at,false;

  return jsonb_build_object('status',case when v_leaks=0 and v_target=0 and v_zero_coverage=0 then 'PASS' else 'FAIL' end,
    'panel_contract',v_contract,'signal_rows',v_signals,'feature_rows',v_features,'observation_rows',v_observations,
    'available_observations',v_available,'leakage_count',v_leaks,'revision_leakage_count',v_revision,
    'target_leakage_count',v_target,'zero_coverage_eligible_drivers',v_zero_coverage,'panel_digest_md5',v_digest,
    'production_influence_enabled',false);
end;$fn$;

revoke all on function public.flow_refresh_driver_signal_stage_v2() from public,anon,authenticated;
revoke all on function public.flow_finalize_driver_panel_v2() from public,anon,authenticated;
grant execute on function public.flow_refresh_driver_signal_stage_v2() to service_role;
grant execute on function public.flow_finalize_driver_panel_v2() to service_role;
