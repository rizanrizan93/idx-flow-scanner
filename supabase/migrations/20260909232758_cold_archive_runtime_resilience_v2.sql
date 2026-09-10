-- Make the completed archives immutable to the runtime role and keep future
-- financial filing features incremental.  A full V5 feature rebuild would be
-- unsafe after raw facts moved to cold storage.

create or replace function public.flow_refresh_financial_filing_feature_incremental_v6()
returns jsonb
language plpgsql
security invoker
set search_path=''
as $fn$
declare v_upserted integer;v_hot_facts bigint;v_total_features bigint;
begin
  select count(*) into v_hot_facts from public.flow_financial_fact_evidence_v5;
  with feature_rows as(
    select f.filing_id,f.ticker,coalesce(nullif(i.sector,''),'UNKNOWN') sector,i.subsector,
      f.report_year,f.report_period,f.report_period_end,f.published_at,
      ((f.published_at at time zone 'Asia/Jakarta')::date+
        case when (f.published_at at time zone 'Asia/Jakarta')::time>time '16:15'
          then 1 else 0 end)::date available_from_date,
      max(x.currency) currency,count(x.fact_id)::int metric_count,
      max(x.metric_value) filter(where x.metric_key='sales_and_revenue') sales,
      max(x.metric_value) filter(where x.metric_key='interest_and_sharia_income') interest_income,
      max(x.metric_value) filter(where x.metric_key='gross_profit') gross_profit,
      max(x.metric_value) filter(where x.metric_key='profit_attributable_to_parent') profit_parent,
      max(x.metric_value) filter(where x.metric_key='profit_loss') profit_loss,
      max(x.metric_value) filter(where x.metric_key='total_assets') assets,
      max(x.metric_value) filter(where x.metric_key='total_liabilities') liabilities,
      max(x.metric_value) filter(where x.metric_key='total_equity') equity,
      max(x.metric_value) filter(where x.metric_key='current_assets') current_assets,
      max(x.metric_value) filter(where x.metric_key='current_liabilities') current_liabilities,
      max(x.metric_value) filter(where x.metric_key='operating_cash_flow') ocf
    from public.flow_financial_filing_evidence_v5 f
    left join public.flow_issuers i on i.ticker=f.ticker
    join public.flow_financial_fact_evidence_v5 x on x.filing_id=f.filing_id
    where f.source_verified and f.publication_time_verified and f.point_in_time_eligible
      and f.extraction_state='FACTS_PARSED'
    group by f.filing_id,f.ticker,i.sector,i.subsector,f.report_year,f.report_period,
      f.report_period_end,f.published_at
  )
  insert into public.flow_financial_filing_feature_v5(
    filing_id,ticker,sector,subsector,report_year,report_period,report_period_end,
    published_at,available_from_date,currency,metric_count,sales,interest_income,
    gross_profit,profit_parent,profit_loss,assets,liabilities,equity,current_assets,
    current_liabilities,ocf,source_verified,point_in_time_eligible,refreshed_at
  )
  select filing_id,ticker,sector,subsector,report_year,report_period,report_period_end,
    published_at,available_from_date,currency,metric_count,sales,interest_income,
    gross_profit,profit_parent,profit_loss,assets,liabilities,equity,current_assets,
    current_liabilities,ocf,true,true,statement_timestamp() from feature_rows
  on conflict(filing_id) do update set ticker=excluded.ticker,sector=excluded.sector,
    subsector=excluded.subsector,report_year=excluded.report_year,
    report_period=excluded.report_period,report_period_end=excluded.report_period_end,
    published_at=excluded.published_at,available_from_date=excluded.available_from_date,
    currency=excluded.currency,metric_count=excluded.metric_count,sales=excluded.sales,
    interest_income=excluded.interest_income,gross_profit=excluded.gross_profit,
    profit_parent=excluded.profit_parent,profit_loss=excluded.profit_loss,
    assets=excluded.assets,liabilities=excluded.liabilities,equity=excluded.equity,
    current_assets=excluded.current_assets,current_liabilities=excluded.current_liabilities,
    ocf=excluded.ocf,source_verified=true,point_in_time_eligible=true,
    refreshed_at=statement_timestamp();
  get diagnostics v_upserted=row_count;
  select count(*) into v_total_features from public.flow_financial_filing_feature_v5;
  return jsonb_build_object('status','COMPLETED','hot_fact_rows',v_hot_facts,
    'upserted_feature_rows',v_upserted,'retained_total_feature_rows',v_total_features,
    'destructive_rebuild',false,'production_influence_enabled',false);
end
$fn$;

create or replace function public.flow_verify_cold_archive_v2()
returns jsonb
language sql
stable
security invoker
set search_path=''
as $fn$
with chunk_check as(
  select c.archive_contract,c.source_table,count(*)::int chunks,sum(c.row_count)::bigint rows,
    count(*) filter(where c.payload_sha256<>encode(extensions.digest(
      convert_to(c.payload::text,'UTF8'),'sha256'),'hex'))::int bad_hashes,
    count(*) filter(where jsonb_array_length(c.payload)<>c.row_count)::int bad_row_counts,
    encode(extensions.digest(convert_to(string_agg(c.payload_sha256,'|' order by
      case when c.archive_contract='GATE11_CLOSED_PANEL_ARCHIVE_V1'
        then c.source_contract||'|'||c.partition_key else c.partition_key end),
      'UTF8'),'sha256'),'hex') aggregate_hash
  from public.flow_cold_archive_chunk_v1 c group by c.archive_contract,c.source_table
), manifest_check as(
  select m.archive_contract,m.source_table,m.source_row_count,m.archived_row_count,
    m.chunk_count,m.aggregate_payload_sha256,m.archive_state,m.source_truncated,
    c.rows,c.chunks,c.bad_hashes,c.bad_row_counts,c.aggregate_hash,
    (m.source_row_count=m.archived_row_count and m.archived_row_count=c.rows
      and m.chunk_count=c.chunks and m.aggregate_payload_sha256=c.aggregate_hash
      and c.bad_hashes=0 and c.bad_row_counts=0
      and m.archive_state='ARCHIVED_SOURCE_TRUNCATED' and m.source_truncated) pass
  from public.flow_cold_archive_manifest_v1 m left join chunk_check c
    using(archive_contract,source_table)
), summary as(
  select count(*)::int manifests,count(*) filter(where pass)::int passed,
    coalesce(sum(archived_row_count),0)::bigint archived_rows,
    coalesce(sum(bad_hashes),0)::int bad_hashes,
    coalesce(sum(bad_row_counts),0)::int bad_row_counts,
    coalesce(jsonb_agg(jsonb_build_object('archive_contract',archive_contract,
      'source_table',source_table,'rows',archived_row_count,'chunks',chunk_count,
      'archive_state',archive_state,'pass',pass) order by archive_contract,source_table),
      '[]'::jsonb) manifests_detail
  from manifest_check
)
select jsonb_build_object('status',case when manifests=4 and passed=4
    and bad_hashes=0 and bad_row_counts=0 then 'PASS' else 'FAIL_CLOSED' end,
  'manifest_count',manifests,'passed_manifest_count',passed,
  'archived_rows',archived_rows,'bad_payload_hashes',bad_hashes,
  'bad_payload_row_counts',bad_row_counts,'manifests',manifests_detail,
  'production_influence_enabled',false) from summary
$fn$;

revoke all on function public.flow_refresh_financial_filing_feature_v5(),
  public.flow_capture_financial_shadow_scan_v5(uuid,numeric),
  public.flow_capture_attribution_prospective_signals_v1(date),
  public.flow_archive_gate11_table_v1(text,text),
  public.flow_finalize_gate11_cold_archive_v1(),
  public.flow_restore_gate11_cold_archive_v1(boolean),
  public.flow_archive_financial_facts_v1(boolean),
  public.flow_restore_financial_facts_v1(boolean),
  public.flow_refresh_financial_filing_feature_incremental_v6(),
  public.flow_verify_cold_archive_v2()
  from public,anon,authenticated,service_role;
grant execute on function public.flow_refresh_financial_filing_feature_incremental_v6(),
  public.flow_verify_cold_archive_v2() to service_role;

revoke insert,update,delete on public.flow_cold_archive_contract_v1,
  public.flow_cold_archive_chunk_v1,public.flow_cold_archive_manifest_v1 from service_role;

do $do$
declare r record;
begin
  for r in select jobid from cron.job where jobname in(
    'flow-financial-filing-feature-incremental-v6-evening',
    'flow-financial-filing-feature-incremental-v6-morning'
  ) loop perform cron.unschedule(r.jobid); end loop;
  perform cron.schedule('flow-financial-filing-feature-incremental-v6-evening',
    '55 10 * * 1-5','select public.flow_refresh_financial_filing_feature_incremental_v6();');
  perform cron.schedule('flow-financial-filing-feature-incremental-v6-morning',
    '0 0 * * 1-5','select public.flow_refresh_financial_filing_feature_incremental_v6();');
end
$do$;
