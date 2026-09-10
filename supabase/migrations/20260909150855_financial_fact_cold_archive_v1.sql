-- Keep prospective financial scoring on compact filing-level features, while
-- preserving every raw relational fact in a lossless, hashed cold archive.
create or replace function public.flow_financial_shadow_snapshot_v6(p_as_of_date date)
returns table (
  as_of_date date,
  ticker text,
  sector text,
  subsector text,
  financial_state text,
  current_filing_id text,
  prior_filing_id text,
  report_year integer,
  report_period text,
  report_period_end date,
  published_at timestamptz,
  current_currency text,
  prior_currency text,
  feature_states jsonb,
  revenue_growth_yoy_pct numeric,
  profit_growth_yoy_pct numeric,
  net_margin_pct numeric,
  gross_margin_pct numeric,
  equity_ratio_pct numeric,
  current_ratio numeric,
  ocf_margin_pct numeric,
  ocf_conversion numeric,
  quality_score numeric,
  growth_score numeric,
  balance_score numeric,
  cashflow_score numeric,
  financial_shadow_score numeric,
  production_influence_enabled boolean
)
language sql
stable
security invoker
set search_path=''
as $fn$
with policy as (
  select stale_after_days
  from public.flow_financial_shadow_policy_v5
  where policy_contract='FINANCIAL_EVIDENCE_V5_PIT_SHADOW_GATE8_1'
), current_filing as (
  select distinct on(i.ticker)
    i.ticker,coalesce(nullif(i.sector,''),'UNKNOWN') sector,i.subsector,
    f.filing_id,f.report_year,f.report_period,f.report_period_end,
    f.published_at,f.available_from_date,f.currency,f.metric_count,
    f.sales,f.interest_income,f.gross_profit,f.profit_parent,f.profit_loss,
    f.assets,f.liabilities,f.equity,f.current_assets,f.current_liabilities,f.ocf
  from public.flow_issuers i
  left join public.flow_financial_filing_feature_v5 f
    on f.ticker=i.ticker and f.available_from_date<=p_as_of_date
    and f.source_verified and f.point_in_time_eligible
  where i.active
  order by i.ticker,f.available_from_date desc nulls last,
    f.published_at desc nulls last,f.filing_id desc nulls last
), comparable as (
  select c.*,p.filing_id prior_filing_id,p.currency prior_currency,
    p.sales prior_sales,p.interest_income prior_interest_income,
    p.profit_parent prior_profit_parent,p.profit_loss prior_profit_loss
  from current_filing c
  left join lateral (
    select f.filing_id,f.currency,f.sales,f.interest_income,
      f.profit_parent,f.profit_loss
    from public.flow_financial_filing_feature_v5 f
    where f.ticker=c.ticker and f.report_year=c.report_year-1
      and f.report_period=c.report_period and f.available_from_date<=p_as_of_date
      and f.source_verified and f.point_in_time_eligible
    order by f.available_from_date desc,f.published_at desc,f.filing_id desc
    limit 1
  ) p on true
), base as (
  select c.*,
    case when c.sector='Keuangan' then coalesce(c.interest_income,c.sales)
      else coalesce(c.sales,c.interest_income) end revenue,
    case when c.sector='Keuangan' then coalesce(c.prior_interest_income,c.prior_sales)
      else coalesce(c.prior_sales,c.prior_interest_income) end prior_revenue,
    coalesce(c.profit_parent,c.profit_loss) profit,
    coalesce(c.prior_profit_parent,c.prior_profit_loss) prior_profit,
    case
      when c.filing_id is null then 'MISSING'
      when c.report_period_end is null or coalesce(c.metric_count,0)<5 then 'INVALID'
      when p_as_of_date-c.report_period_end>(select stale_after_days from policy) then 'STALE'
      when c.prior_filing_id is null then 'INSUFFICIENT_HISTORY'
      else 'AVAILABLE'
    end row_state
  from comparable c
), raw as (
  select b.*,
    case when b.row_state in('MISSING','STALE','INVALID') then null
      when b.prior_filing_id is null or b.prior_revenue is null or b.prior_revenue=0 then null
      when b.currency is distinct from b.prior_currency then null
      else 100.0*(b.revenue/b.prior_revenue-1.0) end revenue_growth,
    case when b.row_state in('MISSING','STALE','INVALID') then null
      when b.prior_filing_id is null or b.prior_profit is null or b.prior_profit=0 then null
      when b.currency is distinct from b.prior_currency then null
      else 100.0*(b.profit/abs(b.prior_profit)
        -case when b.prior_profit<0 then -1.0 else 1.0 end) end profit_growth,
    case when b.row_state in('MISSING','STALE','INVALID') or b.revenue is null
      or b.revenue=0 or b.profit is null then null
      else 100.0*b.profit/abs(b.revenue) end net_margin,
    case when b.sector='Keuangan' or b.row_state in('MISSING','STALE','INVALID')
      or b.revenue is null or b.revenue=0 or b.gross_profit is null then null
      else 100.0*b.gross_profit/abs(b.revenue) end gross_margin,
    case when b.row_state in('MISSING','STALE','INVALID') or b.assets is null
      or b.assets=0 or b.equity is null then null
      else 100.0*b.equity/abs(b.assets) end equity_ratio,
    case when b.sector='Keuangan' or b.row_state in('MISSING','STALE','INVALID')
      or b.current_liabilities is null or b.current_liabilities=0
      or b.current_assets is null then null
      else b.current_assets/abs(b.current_liabilities) end current_ratio_raw,
    case when b.sector='Keuangan' or b.row_state in('MISSING','STALE','INVALID')
      or b.revenue is null or b.revenue=0 or b.ocf is null then null
      else 100.0*b.ocf/abs(b.revenue) end ocf_margin,
    case when b.sector='Keuangan' or b.row_state in('MISSING','STALE','INVALID')
      or b.profit is null or b.profit<=0 or b.ocf is null then null
      else b.ocf/b.profit end ocf_conversion_raw
  from base b
), ranked as (
  select r.*,
    case when r.net_margin is not null then 100.0*percent_rank()
      over(partition by r.sector,(r.net_margin is null) order by r.net_margin) end net_margin_rank,
    case when r.gross_margin is not null then 100.0*percent_rank()
      over(partition by r.sector,(r.gross_margin is null) order by r.gross_margin) end gross_margin_rank,
    case when r.equity_ratio is not null then 100.0*percent_rank()
      over(partition by r.sector,(r.equity_ratio is null) order by r.equity_ratio) end equity_ratio_rank,
    case when r.current_ratio_raw is not null then 100.0*percent_rank()
      over(partition by r.sector,(r.current_ratio_raw is null) order by r.current_ratio_raw) end current_ratio_rank,
    case when r.ocf_margin is not null then 100.0*percent_rank()
      over(partition by r.sector,(r.ocf_margin is null) order by r.ocf_margin) end ocf_margin_rank,
    case when r.ocf_conversion_raw is not null then 100.0*percent_rank()
      over(partition by r.sector,(r.ocf_conversion_raw is null) order by r.ocf_conversion_raw) end ocf_conversion_rank,
    case when r.revenue_growth is not null then 100.0*percent_rank()
      over(partition by r.sector,(r.revenue_growth is null) order by r.revenue_growth) end revenue_growth_rank,
    case when r.profit_growth is not null then 100.0*percent_rank()
      over(partition by r.sector,(r.profit_growth is null) order by r.profit_growth) end profit_growth_rank
  from raw r
), families as (
  select q.*,
    case when q.row_state in('MISSING','STALE','INVALID') then null
      when q.sector='Keuangan' then q.net_margin_rank
      when num_nonnulls(q.net_margin_rank,q.gross_margin_rank)>0
        then (coalesce(q.net_margin_rank,0)+coalesce(q.gross_margin_rank,0))
          /num_nonnulls(q.net_margin_rank,q.gross_margin_rank) end quality,
    case when q.row_state='AVAILABLE'
      and num_nonnulls(q.revenue_growth_rank,q.profit_growth_rank)>0
        then (coalesce(q.revenue_growth_rank,0)+coalesce(q.profit_growth_rank,0))
          /num_nonnulls(q.revenue_growth_rank,q.profit_growth_rank) end growth,
    case when q.row_state in('MISSING','STALE','INVALID') then null
      when q.sector='Keuangan' then q.equity_ratio_rank
      when num_nonnulls(q.equity_ratio_rank,q.current_ratio_rank)>0
        then (coalesce(q.equity_ratio_rank,0)+coalesce(q.current_ratio_rank,0))
          /num_nonnulls(q.equity_ratio_rank,q.current_ratio_rank) end balance,
    case when q.sector='Keuangan' or q.row_state in('MISSING','STALE','INVALID') then null
      when num_nonnulls(q.ocf_margin_rank,q.ocf_conversion_rank)>0
        then (coalesce(q.ocf_margin_rank,0)+coalesce(q.ocf_conversion_rank,0))
          /num_nonnulls(q.ocf_margin_rank,q.ocf_conversion_rank) end cashflow
  from ranked q
)
select p_as_of_date,f.ticker,f.sector,f.subsector,f.row_state,
  f.filing_id,f.prior_filing_id,f.report_year,f.report_period,f.report_period_end,
  f.published_at,f.currency,f.prior_currency,
  jsonb_build_object(
    'revenue_growth_yoy',case when f.row_state in('MISSING','STALE','INVALID') then f.row_state when f.prior_filing_id is null then 'INSUFFICIENT_HISTORY' when f.currency is distinct from f.prior_currency then 'INVALID' when f.revenue_growth is null then 'MISSING' else 'AVAILABLE' end,
    'profit_growth_yoy',case when f.row_state in('MISSING','STALE','INVALID') then f.row_state when f.prior_filing_id is null then 'INSUFFICIENT_HISTORY' when f.currency is distinct from f.prior_currency then 'INVALID' when f.profit_growth is null then 'MISSING' else 'AVAILABLE' end,
    'net_margin',case when f.row_state in('MISSING','STALE','INVALID') then f.row_state when f.net_margin is null then 'MISSING' else 'AVAILABLE' end,
    'gross_margin',case when f.sector='Keuangan' then 'NOT_APPLICABLE' when f.row_state in('MISSING','STALE','INVALID') then f.row_state when f.gross_margin is null then 'MISSING' else 'AVAILABLE' end,
    'equity_ratio',case when f.row_state in('MISSING','STALE','INVALID') then f.row_state when f.equity_ratio is null then 'MISSING' else 'AVAILABLE' end,
    'current_ratio',case when f.sector='Keuangan' then 'NOT_APPLICABLE' when f.row_state in('MISSING','STALE','INVALID') then f.row_state when f.current_ratio_raw is null then 'MISSING' else 'AVAILABLE' end,
    'cashflow',case when f.sector='Keuangan' then 'NOT_APPLICABLE' when f.row_state in('MISSING','STALE','INVALID') then f.row_state when f.cashflow is null then 'MISSING' else 'AVAILABLE' end
  ),
  f.revenue_growth,f.profit_growth,f.net_margin,f.gross_margin,f.equity_ratio,
  f.current_ratio_raw,f.ocf_margin,f.ocf_conversion_raw,
  f.quality,f.growth,f.balance,f.cashflow,
  case when f.row_state='AVAILABLE' and num_nonnulls(f.quality,f.growth,f.balance,f.cashflow)>=2
    then (coalesce(f.quality,0)+coalesce(f.growth,0)+coalesce(f.balance,0)+coalesce(f.cashflow,0))
      /num_nonnulls(f.quality,f.growth,f.balance,f.cashflow) else null end,
  false
from families f order by f.ticker
$fn$;

revoke all on function public.flow_financial_shadow_snapshot_v6(date)
  from public,anon,authenticated,service_role;
grant execute on function public.flow_financial_shadow_snapshot_v6(date) to service_role;

insert into public.flow_cold_archive_contract_v1(
  archive_contract,purpose,source_contracts,restore_policy,production_dependency_state
) values(
  'FINANCIAL_FACT_EVIDENCE_ARCHIVE_V1',
  'Lossless compact archive of relational financial facts after filing-level PIT features are proven equivalent for prospective scoring.',
  array['FINANCIAL_EVIDENCE_V5_FACT_CACHE'],
  'Restore explicitly for raw-fact audit or historical financial feature rebuild. Prospective scoring uses the verified filing-level feature materialization.',
  'NO_DIRECT_PRODUCTION_SCORE_DEPENDENCY_AFTER_FINANCIAL_SNAPSHOT_V6_PARITY'
) on conflict(archive_contract) do nothing;

create or replace function public.flow_archive_financial_facts_v1(p_finalize boolean default false)
returns jsonb
language plpgsql
security invoker
set search_path=''
set work_mem='64MB'
as $fn$
declare v_source_rows bigint;v_archived_rows bigint;v_chunks integer;
  v_before bigint;v_after bigint;v_digest text;v_missing_features bigint;
begin
  lock table public.flow_financial_fact_evidence_v5 in access exclusive mode;
  select count(*),pg_total_relation_size('public.flow_financial_fact_evidence_v5'::regclass)
    into v_source_rows,v_before from public.flow_financial_fact_evidence_v5;
  if v_source_rows=0 then
    return jsonb_build_object('status','NO_HOT_FACTS','rows',0,
      'production_influence_enabled',false);
  end if;
  select count(*) into v_missing_features
  from public.flow_financial_fact_evidence_v5 x
  left join public.flow_financial_filing_feature_v5 f using(filing_id)
  where f.filing_id is null or not f.source_verified or not f.point_in_time_eligible;
  if v_missing_features>0 then
    raise exception 'financial fact archive denied: % rows lack verified filing features',v_missing_features;
  end if;

  delete from public.flow_cold_archive_chunk_v1
  where archive_contract='FINANCIAL_FACT_EVIDENCE_ARCHIVE_V1'
    and source_table='flow_financial_fact_evidence_v5';
  insert into public.flow_cold_archive_chunk_v1(
    archive_contract,source_table,source_contract,partition_key,source_schema_sha256,
    row_count,min_observed_date,max_observed_date,payload,payload_sha256,
    production_influence_enabled
  )
  with schema_hash as(
    select encode(extensions.digest(convert_to(string_agg(
      c.column_name||':'||c.data_type||':'||c.is_nullable,'|' order by c.ordinal_position
    ),'UTF8'),'sha256'),'hex') value
    from information_schema.columns c
    where c.table_schema='public' and c.table_name='flow_financial_fact_evidence_v5'
  ), grouped as(
    select f.ticker||':'||f.report_year::text partition_key,
      min(f.report_period_end) min_date,max(f.report_period_end) max_date,
      jsonb_agg(to_jsonb(x) order by x.filing_id,x.metric_key,x.fact_id) payload,
      count(*)::int row_count
    from public.flow_financial_fact_evidence_v5 x
    join public.flow_financial_filing_evidence_v5 f using(filing_id)
    group by f.ticker,f.report_year
  )
  select 'FINANCIAL_FACT_EVIDENCE_ARCHIVE_V1','flow_financial_fact_evidence_v5',
    'FINANCIAL_EVIDENCE_V5_FACT_CACHE',g.partition_key,s.value,g.row_count,
    g.min_date,g.max_date,g.payload,
    encode(extensions.digest(convert_to(g.payload::text,'UTF8'),'sha256'),'hex'),false
  from grouped g cross join schema_hash s;

  select coalesce(sum(row_count),0),count(*)::int,
    encode(extensions.digest(convert_to(string_agg(payload_sha256,'|' order by partition_key),
      'UTF8'),'sha256'),'hex')
  into v_archived_rows,v_chunks,v_digest
  from public.flow_cold_archive_chunk_v1
  where archive_contract='FINANCIAL_FACT_EVIDENCE_ARCHIVE_V1'
    and source_table='flow_financial_fact_evidence_v5'
    and payload_sha256=encode(extensions.digest(convert_to(payload::text,'UTF8'),'sha256'),'hex')
    and jsonb_array_length(payload)=row_count;
  if v_archived_rows<>v_source_rows or v_digest is null then
    raise exception 'financial fact archive verification failed: source %, archive %',
      v_source_rows,v_archived_rows;
  end if;

  insert into public.flow_cold_archive_manifest_v1(
    archive_contract,source_table,source_row_count,archived_row_count,chunk_count,
    source_bytes_before,aggregate_payload_sha256,closure_evidence,archive_state,
    source_truncated,production_influence_enabled
  ) values(
    'FINANCIAL_FACT_EVIDENCE_ARCHIVE_V1','flow_financial_fact_evidence_v5',
    v_source_rows,v_archived_rows,v_chunks,v_before,v_digest,
    jsonb_build_object('filing_feature_coverage_rows',v_source_rows,
      'missing_feature_rows',v_missing_features,'recordset_shape_verified',true,
      'snapshot_v6_required_before_finalize',true),
    'STAGED_VERIFIED',false,false
  ) on conflict(archive_contract,source_table) do update set
    source_row_count=excluded.source_row_count,archived_row_count=excluded.archived_row_count,
    chunk_count=excluded.chunk_count,source_bytes_before=excluded.source_bytes_before,
    aggregate_payload_sha256=excluded.aggregate_payload_sha256,
    closure_evidence=excluded.closure_evidence,archive_state='STAGED_VERIFIED',
    source_truncated=false,verified_at=statement_timestamp();

  if not coalesce(p_finalize,false) then
    return jsonb_build_object('status','STAGED_VERIFIED','rows',v_archived_rows,
      'chunks',v_chunks,'source_bytes_before',v_before,
      'production_influence_enabled',false);
  end if;
  truncate table public.flow_financial_fact_evidence_v5;
  select pg_total_relation_size('public.flow_financial_fact_evidence_v5'::regclass) into v_after;
  update public.flow_cold_archive_manifest_v1 set source_bytes_after=v_after,
    archive_relation_bytes=pg_total_relation_size('public.flow_cold_archive_chunk_v1'::regclass),
    archive_state='ARCHIVED_SOURCE_TRUNCATED',source_truncated=true,
    verified_at=statement_timestamp()
  where archive_contract='FINANCIAL_FACT_EVIDENCE_ARCHIVE_V1'
    and source_table='flow_financial_fact_evidence_v5';
  return jsonb_build_object('status','ARCHIVED_SOURCE_TRUNCATED','rows',v_archived_rows,
    'chunks',v_chunks,'source_bytes_before',v_before,'source_bytes_after',v_after,
    'gross_source_bytes_reclaimed',v_before-v_after,
    'archive_relation_bytes',pg_total_relation_size('public.flow_cold_archive_chunk_v1'::regclass),
    'production_influence_enabled',false);
end
$fn$;

create or replace function public.flow_restore_financial_facts_v1(p_confirm_capacity boolean default false)
returns jsonb
language plpgsql
security invoker
set search_path=''
set work_mem='64MB'
as $fn$
declare v_expected bigint;v_restored bigint;
begin
  if not coalesce(p_confirm_capacity,false) then
    raise exception 'explicit capacity confirmation is required before restoring financial facts';
  end if;
  if (select count(*) from public.flow_financial_fact_evidence_v5)>0 then
    raise exception 'financial fact restore target must be empty';
  end if;
  select archived_row_count into strict v_expected
  from public.flow_cold_archive_manifest_v1
  where archive_contract='FINANCIAL_FACT_EVIDENCE_ARCHIVE_V1'
    and source_table='flow_financial_fact_evidence_v5'
    and archive_state='ARCHIVED_SOURCE_TRUNCATED' and source_truncated;
  insert into public.flow_financial_fact_evidence_v5
  select x.*
  from public.flow_cold_archive_chunk_v1 c
  cross join lateral jsonb_populate_recordset(
    null::public.flow_financial_fact_evidence_v5,c.payload
  ) x
  where c.archive_contract='FINANCIAL_FACT_EVIDENCE_ARCHIVE_V1'
    and c.source_table='flow_financial_fact_evidence_v5'
  order by c.partition_key;
  get diagnostics v_restored=row_count;
  if v_restored<>v_expected then
    raise exception 'financial fact restore mismatch: expected %, restored %',v_expected,v_restored;
  end if;
  update public.flow_cold_archive_manifest_v1 set archive_state='RESTORED_EXPLICITLY',
    source_truncated=false,verified_at=statement_timestamp()
  where archive_contract='FINANCIAL_FACT_EVIDENCE_ARCHIVE_V1'
    and source_table='flow_financial_fact_evidence_v5';
  return jsonb_build_object('status','RESTORED_EXPLICITLY','rows',v_restored,
    'production_influence_enabled',false);
end
$fn$;

revoke all on function public.flow_archive_financial_facts_v1(boolean),
  public.flow_restore_financial_facts_v1(boolean)
  from public,anon,authenticated,service_role;
grant execute on function public.flow_archive_financial_facts_v1(boolean),
  public.flow_restore_financial_facts_v1(boolean) to service_role;
