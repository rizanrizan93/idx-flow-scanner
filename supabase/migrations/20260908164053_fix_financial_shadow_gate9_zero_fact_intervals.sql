-- Preserve all FACTS_PARSED filing validity intervals, including filings that
-- legitimately produce zero target metrics from the 19-metric Evidence v5 catalog.
-- A zero-fact current filing must surface INVALID/MISSING semantics rather than
-- silently falling back to an older filing.

create or replace function public.flow_refresh_financial_filing_feature_v5()
returns jsonb
language plpgsql
security invoker
set search_path=''
as $fn$
declare v_result jsonb;
begin
  delete from public.flow_financial_filing_feature_v5;
  insert into public.flow_financial_filing_feature_v5(
    filing_id,ticker,sector,subsector,report_year,report_period,report_period_end,published_at,available_from_date,
    currency,metric_count,sales,interest_income,gross_profit,profit_parent,profit_loss,assets,liabilities,equity,current_assets,current_liabilities,ocf,
    source_verified,point_in_time_eligible
  )
  select f.filing_id,f.ticker,coalesce(nullif(i.sector,''),'UNKNOWN'),i.subsector,
    f.report_year,f.report_period,f.report_period_end,f.published_at,
    ((f.published_at at time zone 'Asia/Jakarta')::date + case when (f.published_at at time zone 'Asia/Jakarta')::time > time '16:15' then 1 else 0 end)::date,
    max(x.currency),count(x.fact_id),
    max(x.metric_value) filter(where x.metric_key='sales_and_revenue'),
    max(x.metric_value) filter(where x.metric_key='interest_and_sharia_income'),
    max(x.metric_value) filter(where x.metric_key='gross_profit'),
    max(x.metric_value) filter(where x.metric_key='profit_attributable_to_parent'),
    max(x.metric_value) filter(where x.metric_key='profit_loss'),
    max(x.metric_value) filter(where x.metric_key='total_assets'),
    max(x.metric_value) filter(where x.metric_key='total_liabilities'),
    max(x.metric_value) filter(where x.metric_key='total_equity'),
    max(x.metric_value) filter(where x.metric_key='current_assets'),
    max(x.metric_value) filter(where x.metric_key='current_liabilities'),
    max(x.metric_value) filter(where x.metric_key='operating_cash_flow'),
    true,true
  from public.flow_financial_filing_evidence_v5 f
  left join public.flow_issuers i on i.ticker=f.ticker
  left join public.flow_financial_fact_evidence_v5 x on x.filing_id=f.filing_id
  where f.source_verified and f.publication_time_verified and f.point_in_time_eligible and f.extraction_state='FACTS_PARSED'
  group by f.filing_id,f.ticker,i.sector,i.subsector,f.report_year,f.report_period,f.report_period_end,f.published_at;

  select jsonb_build_object('status','OK','rows',count(*),'tickers',count(distinct ticker),
    'zero_fact_filings',count(*) filter(where metric_count=0),
    'min_available_date',min(available_from_date),'max_available_date',max(available_from_date),
    'source_verified_rows',count(*) filter(where source_verified),'point_in_time_eligible_rows',count(*) filter(where point_in_time_eligible))
  into v_result from public.flow_financial_filing_feature_v5;
  return v_result;
end;
$fn$;
revoke all on function public.flow_refresh_financial_filing_feature_v5() from public,anon,authenticated,service_role;
grant execute on function public.flow_refresh_financial_filing_feature_v5() to service_role;
