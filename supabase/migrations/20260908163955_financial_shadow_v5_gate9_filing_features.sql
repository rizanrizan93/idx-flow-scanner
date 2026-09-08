-- Gate 9 performance foundation: one canonical feature row per parsed filing.

create table if not exists public.flow_financial_filing_feature_v5 (
  filing_id text primary key references public.flow_financial_filing_evidence_v5(filing_id) on delete cascade,
  ticker text not null,
  sector text not null,
  subsector text,
  report_year integer not null,
  report_period text not null,
  report_period_end date,
  published_at timestamptz not null,
  available_from_date date not null,
  currency text,
  metric_count integer not null,
  sales numeric,
  interest_income numeric,
  gross_profit numeric,
  profit_parent numeric,
  profit_loss numeric,
  assets numeric,
  liabilities numeric,
  equity numeric,
  current_assets numeric,
  current_liabilities numeric,
  ocf numeric,
  source_verified boolean not null check(source_verified=true),
  point_in_time_eligible boolean not null check(point_in_time_eligible=true),
  refreshed_at timestamptz not null default now()
);
create index if not exists flow_financial_filing_feature_v5_pit_idx
  on public.flow_financial_filing_feature_v5(ticker,available_from_date desc,published_at desc);
create index if not exists flow_financial_filing_feature_v5_comparable_idx
  on public.flow_financial_filing_feature_v5(ticker,report_year,report_period,available_from_date desc,published_at desc);
alter table public.flow_financial_filing_feature_v5 enable row level security;
revoke all on public.flow_financial_filing_feature_v5 from public,anon,authenticated,service_role;
grant select,insert,update,delete on public.flow_financial_filing_feature_v5 to service_role;

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
  join public.flow_financial_fact_evidence_v5 x on x.filing_id=f.filing_id
  where f.source_verified and f.publication_time_verified and f.point_in_time_eligible and f.extraction_state='FACTS_PARSED'
  group by f.filing_id,f.ticker,i.sector,i.subsector,f.report_year,f.report_period,f.report_period_end,f.published_at;

  select jsonb_build_object('status','OK','rows',count(*),'tickers',count(distinct ticker),
    'min_available_date',min(available_from_date),'max_available_date',max(available_from_date),
    'source_verified_rows',count(*) filter(where source_verified),'point_in_time_eligible_rows',count(*) filter(where point_in_time_eligible))
  into v_result from public.flow_financial_filing_feature_v5;
  return v_result;
end;
$fn$;
revoke all on function public.flow_refresh_financial_filing_feature_v5() from public,anon,authenticated,service_role;
grant execute on function public.flow_refresh_financial_filing_feature_v5() to service_role;
