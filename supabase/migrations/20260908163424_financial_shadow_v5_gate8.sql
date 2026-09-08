-- Gate 8: PIT-safe Financial Evidence v5 shadow adapter.
-- Financial evidence is strictly diagnostic/shadow at this gate.
-- No production scoring/ranking/decision path is modified.

create index if not exists flow_financial_filing_v5_pit_lookup_idx
  on public.flow_financial_filing_evidence_v5(ticker, published_at desc, report_year, report_period)
  where source_verified and publication_time_verified and point_in_time_eligible and extraction_state = 'FACTS_PARSED';

create table if not exists public.flow_financial_shadow_policy_v5 (
  policy_contract text primary key,
  stale_after_days integer not null check (stale_after_days between 90 and 365),
  market_close_cutoff time not null,
  max_evaluation_blend_weight_pct numeric not null check (max_evaluation_blend_weight_pct between 0 and 10),
  production_influence_enabled boolean not null check (production_influence_enabled = false),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

insert into public.flow_financial_shadow_policy_v5(
  policy_contract, stale_after_days, market_close_cutoff,
  max_evaluation_blend_weight_pct, production_influence_enabled
) values (
  'FINANCIAL_EVIDENCE_V5_PIT_SHADOW_GATE8_1', 220, time '16:15', 10, false
)
on conflict (policy_contract) do update set
  stale_after_days = excluded.stale_after_days,
  market_close_cutoff = excluded.market_close_cutoff,
  max_evaluation_blend_weight_pct = excluded.max_evaluation_blend_weight_pct,
  production_influence_enabled = false,
  updated_at = now();

alter table public.flow_financial_shadow_policy_v5 enable row level security;
revoke all on public.flow_financial_shadow_policy_v5 from public, anon, authenticated, service_role;
grant select on public.flow_financial_shadow_policy_v5 to service_role;

create or replace function public.flow_financial_shadow_snapshot_v5(p_as_of_date date)
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
set search_path = ''
as $fn$
with policy as (
  select stale_after_days, market_close_cutoff
  from public.flow_financial_shadow_policy_v5
  where policy_contract = 'FINANCIAL_EVIDENCE_V5_PIT_SHADOW_GATE8_1'
), eligible_filings as (
  select f.*,
    ((f.published_at at time zone 'Asia/Jakarta')::date
      + case when (f.published_at at time zone 'Asia/Jakarta')::time > p.market_close_cutoff then 1 else 0 end
    )::date as available_from_date
  from public.flow_financial_filing_evidence_v5 f
  cross join policy p
  where f.source_verified
    and f.publication_time_verified
    and f.point_in_time_eligible
    and f.extraction_state = 'FACTS_PARSED'
), current_filing as (
  select distinct on (i.ticker)
    i.ticker,
    coalesce(nullif(i.sector,''), 'UNKNOWN') as sector,
    i.subsector,
    f.filing_id,
    f.report_year,
    f.report_period,
    f.report_period_end,
    f.published_at,
    f.available_from_date
  from public.flow_issuers i
  left join eligible_filings f
    on f.ticker = i.ticker and f.available_from_date <= p_as_of_date
  where i.active
  order by i.ticker, f.available_from_date desc nulls last, f.published_at desc nulls last, f.filing_id desc nulls last
), comparable as (
  select c.*,
    p.filing_id as prior_filing_id,
    p.published_at as prior_published_at
  from current_filing c
  left join lateral (
    select f.filing_id, f.published_at
    from eligible_filings f
    where f.ticker = c.ticker
      and f.report_year = c.report_year - 1
      and f.report_period = c.report_period
      and f.available_from_date <= p_as_of_date
    order by f.available_from_date desc, f.published_at desc, f.filing_id desc
    limit 1
  ) p on true
), current_facts as (
  select c.ticker,
    count(x.fact_id) as metric_count,
    max(x.currency) as currency,
    max(x.metric_value) filter (where x.metric_key='sales_and_revenue') as sales,
    max(x.metric_value) filter (where x.metric_key='interest_and_sharia_income') as interest_income,
    max(x.metric_value) filter (where x.metric_key='gross_profit') as gross_profit,
    max(x.metric_value) filter (where x.metric_key='profit_attributable_to_parent') as profit_parent,
    max(x.metric_value) filter (where x.metric_key='profit_loss') as profit_loss,
    max(x.metric_value) filter (where x.metric_key='total_assets') as assets,
    max(x.metric_value) filter (where x.metric_key='total_liabilities') as liabilities,
    max(x.metric_value) filter (where x.metric_key='total_equity') as equity,
    max(x.metric_value) filter (where x.metric_key='current_assets') as current_assets,
    max(x.metric_value) filter (where x.metric_key='current_liabilities') as current_liabilities,
    max(x.metric_value) filter (where x.metric_key='operating_cash_flow') as ocf
  from comparable c
  left join public.flow_financial_fact_evidence_v5 x on x.filing_id=c.filing_id
  group by c.ticker
), prior_facts as (
  select c.ticker,
    count(x.fact_id) as metric_count,
    max(x.currency) as currency,
    max(x.metric_value) filter (where x.metric_key='sales_and_revenue') as sales,
    max(x.metric_value) filter (where x.metric_key='interest_and_sharia_income') as interest_income,
    max(x.metric_value) filter (where x.metric_key='profit_attributable_to_parent') as profit_parent,
    max(x.metric_value) filter (where x.metric_key='profit_loss') as profit_loss
  from comparable c
  left join public.flow_financial_fact_evidence_v5 x on x.filing_id=c.prior_filing_id
  group by c.ticker
), base as (
  select c.*,
    cf.metric_count,
    cf.currency as current_currency,
    pf.currency as prior_currency,
    case when c.sector='Keuangan' then coalesce(cf.interest_income, cf.sales) else coalesce(cf.sales, cf.interest_income) end as revenue,
    case when c.sector='Keuangan' then coalesce(pf.interest_income, pf.sales) else coalesce(pf.sales, pf.interest_income) end as prior_revenue,
    coalesce(cf.profit_parent,cf.profit_loss) as profit,
    coalesce(pf.profit_parent,pf.profit_loss) as prior_profit,
    cf.gross_profit, cf.assets, cf.liabilities, cf.equity, cf.current_assets, cf.current_liabilities, cf.ocf,
    case
      when c.filing_id is null then 'MISSING'
      when c.report_period_end is null or coalesce(cf.metric_count,0) < 5 then 'INVALID'
      when p_as_of_date - c.report_period_end > (select stale_after_days from policy) then 'STALE'
      when c.prior_filing_id is null then 'INSUFFICIENT_HISTORY'
      else 'AVAILABLE'
    end as row_state
  from comparable c
  left join current_facts cf using (ticker)
  left join prior_facts pf using (ticker)
), raw as (
  select b.*,
    case when b.row_state in ('MISSING','STALE','INVALID') then null
         when b.prior_filing_id is null or b.prior_revenue is null or b.prior_revenue=0 then null
         when b.current_currency is distinct from b.prior_currency then null
         else 100.0*(b.revenue/b.prior_revenue-1.0) end as revenue_growth,
    case when b.row_state in ('MISSING','STALE','INVALID') then null
         when b.prior_filing_id is null or b.prior_profit is null or b.prior_profit=0 then null
         when b.current_currency is distinct from b.prior_currency then null
         else 100.0*(b.profit/abs(b.prior_profit)-case when b.prior_profit<0 then -1.0 else 1.0 end) end as profit_growth,
    case when b.row_state in ('MISSING','STALE','INVALID') or b.revenue is null or b.revenue=0 or b.profit is null then null
         else 100.0*b.profit/abs(b.revenue) end as net_margin,
    case when b.sector='Keuangan' or b.row_state in ('MISSING','STALE','INVALID') or b.revenue is null or b.revenue=0 or b.gross_profit is null then null
         else 100.0*b.gross_profit/abs(b.revenue) end as gross_margin,
    case when b.row_state in ('MISSING','STALE','INVALID') or b.assets is null or b.assets=0 or b.equity is null then null
         else 100.0*b.equity/abs(b.assets) end as equity_ratio,
    case when b.sector='Keuangan' or b.row_state in ('MISSING','STALE','INVALID') or b.current_liabilities is null or b.current_liabilities=0 or b.current_assets is null then null
         else b.current_assets/abs(b.current_liabilities) end as current_ratio_raw,
    case when b.sector='Keuangan' or b.row_state in ('MISSING','STALE','INVALID') or b.revenue is null or b.revenue=0 or b.ocf is null then null
         else 100.0*b.ocf/abs(b.revenue) end as ocf_margin,
    case when b.sector='Keuangan' or b.row_state in ('MISSING','STALE','INVALID') or b.profit is null or b.profit<=0 or b.ocf is null then null
         else b.ocf/b.profit end as ocf_conversion_raw
  from base b
), ranked as (
  select r.*,
    case when r.net_margin is not null then 100.0*percent_rank() over(partition by r.sector,(r.net_margin is null) order by r.net_margin) end as net_margin_rank,
    case when r.gross_margin is not null then 100.0*percent_rank() over(partition by r.sector,(r.gross_margin is null) order by r.gross_margin) end as gross_margin_rank,
    case when r.equity_ratio is not null then 100.0*percent_rank() over(partition by r.sector,(r.equity_ratio is null) order by r.equity_ratio) end as equity_ratio_rank,
    case when r.current_ratio_raw is not null then 100.0*percent_rank() over(partition by r.sector,(r.current_ratio_raw is null) order by r.current_ratio_raw) end as current_ratio_rank,
    case when r.ocf_margin is not null then 100.0*percent_rank() over(partition by r.sector,(r.ocf_margin is null) order by r.ocf_margin) end as ocf_margin_rank,
    case when r.ocf_conversion_raw is not null then 100.0*percent_rank() over(partition by r.sector,(r.ocf_conversion_raw is null) order by r.ocf_conversion_raw) end as ocf_conversion_rank,
    case when r.revenue_growth is not null then 100.0*percent_rank() over(partition by r.sector,(r.revenue_growth is null) order by r.revenue_growth) end as revenue_growth_rank,
    case when r.profit_growth is not null then 100.0*percent_rank() over(partition by r.sector,(r.profit_growth is null) order by r.profit_growth) end as profit_growth_rank
  from raw r
), families as (
  select q.*,
    case when q.row_state in ('MISSING','STALE','INVALID') then null
         when q.sector='Keuangan' then q.net_margin_rank
         when num_nonnulls(q.net_margin_rank,q.gross_margin_rank)>0 then (coalesce(q.net_margin_rank,0)+coalesce(q.gross_margin_rank,0))/num_nonnulls(q.net_margin_rank,q.gross_margin_rank) end as quality,
    case when q.row_state='AVAILABLE' and num_nonnulls(q.revenue_growth_rank,q.profit_growth_rank)>0 then (coalesce(q.revenue_growth_rank,0)+coalesce(q.profit_growth_rank,0))/num_nonnulls(q.revenue_growth_rank,q.profit_growth_rank) end as growth,
    case when q.row_state in ('MISSING','STALE','INVALID') then null
         when q.sector='Keuangan' then q.equity_ratio_rank
         when num_nonnulls(q.equity_ratio_rank,q.current_ratio_rank)>0 then (coalesce(q.equity_ratio_rank,0)+coalesce(q.current_ratio_rank,0))/num_nonnulls(q.equity_ratio_rank,q.current_ratio_rank) end as balance,
    case when q.sector='Keuangan' or q.row_state in ('MISSING','STALE','INVALID') then null
         when num_nonnulls(q.ocf_margin_rank,q.ocf_conversion_rank)>0 then (coalesce(q.ocf_margin_rank,0)+coalesce(q.ocf_conversion_rank,0))/num_nonnulls(q.ocf_margin_rank,q.ocf_conversion_rank) end as cashflow
  from ranked q
)
select
  p_as_of_date,
  f.ticker,f.sector,f.subsector,f.row_state,
  f.filing_id,f.prior_filing_id,f.report_year,f.report_period,f.report_period_end,f.published_at,
  f.current_currency,f.prior_currency,
  jsonb_build_object(
    'revenue_growth_yoy', case when f.row_state in ('MISSING','STALE','INVALID') then f.row_state when f.prior_filing_id is null then 'INSUFFICIENT_HISTORY' when f.current_currency is distinct from f.prior_currency then 'INVALID' when f.revenue_growth is null then 'MISSING' else 'AVAILABLE' end,
    'profit_growth_yoy', case when f.row_state in ('MISSING','STALE','INVALID') then f.row_state when f.prior_filing_id is null then 'INSUFFICIENT_HISTORY' when f.current_currency is distinct from f.prior_currency then 'INVALID' when f.profit_growth is null then 'MISSING' else 'AVAILABLE' end,
    'net_margin', case when f.row_state in ('MISSING','STALE','INVALID') then f.row_state when f.net_margin is null then 'MISSING' else 'AVAILABLE' end,
    'gross_margin', case when f.sector='Keuangan' then 'NOT_APPLICABLE' when f.row_state in ('MISSING','STALE','INVALID') then f.row_state when f.gross_margin is null then 'MISSING' else 'AVAILABLE' end,
    'equity_ratio', case when f.row_state in ('MISSING','STALE','INVALID') then f.row_state when f.equity_ratio is null then 'MISSING' else 'AVAILABLE' end,
    'current_ratio', case when f.sector='Keuangan' then 'NOT_APPLICABLE' when f.row_state in ('MISSING','STALE','INVALID') then f.row_state when f.current_ratio_raw is null then 'MISSING' else 'AVAILABLE' end,
    'cashflow', case when f.sector='Keuangan' then 'NOT_APPLICABLE' when f.row_state in ('MISSING','STALE','INVALID') then f.row_state when f.cashflow is null then 'MISSING' else 'AVAILABLE' end
  ),
  f.revenue_growth,f.profit_growth,f.net_margin,f.gross_margin,f.equity_ratio,f.current_ratio_raw,f.ocf_margin,f.ocf_conversion_raw,
  f.quality,f.growth,f.balance,f.cashflow,
  case when f.row_state='AVAILABLE' and num_nonnulls(f.quality,f.growth,f.balance,f.cashflow)>=2
       then (coalesce(f.quality,0)+coalesce(f.growth,0)+coalesce(f.balance,0)+coalesce(f.cashflow,0))/num_nonnulls(f.quality,f.growth,f.balance,f.cashflow)
       else null end,
  false
from families f
order by f.ticker;
$fn$;

revoke all on function public.flow_financial_shadow_snapshot_v5(date) from public, anon, authenticated, service_role;
grant execute on function public.flow_financial_shadow_snapshot_v5(date) to service_role;

create table if not exists public.flow_financial_shadow_scan_comparison_v5 (
  run_id uuid not null references public.flow_scan_runs(id) on delete cascade,
  ticker text not null,
  as_of_date date not null,
  sector text,
  financial_state text not null check (financial_state in ('AVAILABLE','MISSING','STALE','NOT_APPLICABLE','INVALID','INSUFFICIENT_HISTORY')),
  production_final_score numeric not null,
  production_rank integer not null,
  production_phase text,
  production_action text,
  production_real_money_state text,
  financial_shadow_score numeric,
  financial_shadow_rank integer,
  evaluation_weight_pct numeric not null check (evaluation_weight_pct between 0 and 10),
  evaluation_blend_score numeric not null,
  evaluation_blend_rank integer not null,
  feature_states jsonb not null,
  production_influence_enabled boolean not null check (production_influence_enabled=false),
  captured_at timestamptz not null default now(),
  primary key(run_id,ticker)
);
alter table public.flow_financial_shadow_scan_comparison_v5 enable row level security;
revoke all on public.flow_financial_shadow_scan_comparison_v5 from public, anon, authenticated, service_role;
grant select,insert,update,delete on public.flow_financial_shadow_scan_comparison_v5 to service_role;

-- Initial body is deliberately identical to the corrected canonical body. The
-- subsequent source-parity patch remains idempotent and documents the deployed fix.
create or replace function public.flow_capture_financial_shadow_scan_v5(p_run_id uuid, p_weight_pct numeric default 10)
returns jsonb
language plpgsql
security invoker
set search_path=''
as $fn$
declare
  v_weight numeric := greatest(0,least(10,coalesce(p_weight_pct,10)));
  v_result jsonb;
begin
  if not exists(select 1 from public.flow_scan_runs where id=p_run_id) then
    raise exception 'FINANCIAL_SHADOW_RUN_NOT_FOUND';
  end if;
  delete from public.flow_financial_shadow_scan_comparison_v5 where run_id=p_run_id;
  with base as (
    select r.*,row_number() over(order by r.final_score desc,r.ticker) as production_rank
    from public.flow_scan_results r where r.run_id=p_run_id
  ), dates as (
    select distinct b.as_of_date from base b
  ), shadow as (
    select s.* from dates d cross join lateral public.flow_financial_shadow_snapshot_v5(d.as_of_date) s
  ), joined as (
    select b.run_id,b.ticker,b.as_of_date,coalesce(s.sector,'UNKNOWN') sector,
      coalesce(s.financial_state,'MISSING') financial_state,b.final_score production_final_score,b.production_rank,
      b.phase production_phase,b.action production_action,b.real_money_state production_real_money_state,
      s.financial_shadow_score,s.feature_states,
      case when s.financial_shadow_score is null then b.final_score else (100-v_weight)/100.0*b.final_score+v_weight/100.0*s.financial_shadow_score end evaluation_blend_score
    from base b left join shadow s on s.as_of_date=b.as_of_date and s.ticker=b.ticker
  ), ranked as (
    select j.*,case when j.financial_shadow_score is not null then row_number() over(order by j.financial_shadow_score desc nulls last,j.ticker) end financial_shadow_rank,
      row_number() over(order by j.evaluation_blend_score desc,j.ticker) evaluation_blend_rank from joined j
  )
  insert into public.flow_financial_shadow_scan_comparison_v5
  select run_id,ticker,as_of_date,sector,financial_state,production_final_score,production_rank,production_phase,production_action,production_real_money_state,
    financial_shadow_score,financial_shadow_rank,v_weight,evaluation_blend_score,evaluation_blend_rank,coalesce(feature_states,'{}'::jsonb),false,now()
  from ranked;
  select jsonb_build_object('status','OK','run_id',p_run_id,'rows',count(*),'available_rows',count(*) filter(where financial_state='AVAILABLE'),
    'missing_rows',count(*) filter(where financial_state='MISSING'),'stale_rows',count(*) filter(where financial_state='STALE'),
    'insufficient_history_rows',count(*) filter(where financial_state='INSUFFICIENT_HISTORY'),'invalid_rows',count(*) filter(where financial_state='INVALID'),
    'scored_rows',count(*) filter(where financial_shadow_score is not null),'evaluation_weight_pct',v_weight,
    'top20_overlap',count(*) filter(where production_rank<=20 and evaluation_blend_rank<=20),'max_abs_rank_shift',max(abs(evaluation_blend_rank-production_rank)),
    'production_scoring_changed',false,'production_influence_enabled',false)
  into v_result from public.flow_financial_shadow_scan_comparison_v5 where run_id=p_run_id;
  return v_result;
end;
$fn$;

revoke all on function public.flow_capture_financial_shadow_scan_v5(uuid,numeric) from public,anon,authenticated,service_role;
grant execute on function public.flow_capture_financial_shadow_scan_v5(uuid,numeric) to service_role;
