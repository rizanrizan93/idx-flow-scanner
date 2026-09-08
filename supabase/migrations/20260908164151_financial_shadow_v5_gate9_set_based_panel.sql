-- Final set-based historical panel implementation used by Gate 9.

create or replace function public.flow_refresh_financial_shadow_panel_v5(p_start_date date,p_end_date date)
returns jsonb
language plpgsql
security invoker
set search_path=''
as $fn$
declare
  v_contract constant text := 'FINANCIAL_V5_WEEKLY_LAST_TRADING_DAY_PIT_1';
  v_result jsonb;
begin
  if p_start_date is null or p_end_date is null or p_start_date > p_end_date then
    raise exception 'FINANCIAL_SHADOW_PANEL_INVALID_DATE_RANGE';
  end if;

  delete from public.flow_financial_shadow_panel_v5
   where sample_contract=v_contract and as_of_date between p_start_date and p_end_date;

  with obs_dates as (
    select max(s.trade_date)::date as as_of_date
    from public.flow_official_stock_summary s
    where s.source='IDX_OFFICIAL_STOCK_SUMMARY' and s.source_verified
      and s.trade_date between p_start_date and p_end_date
    group by date_trunc('week',s.trade_date)
  ), labels as (
    select l.as_of_date,l.ticker,coalesce(nullif(l.sector,''),'UNKNOWN') as sector,
      l.target_date_5d,l.target_date_20d,l.target_date_60d,
      l.clean_alpha_vs_sector_5d_pct,l.clean_alpha_vs_sector_20d_pct,l.clean_alpha_vs_sector_60d_pct
    from public.flow_market_learning_labels_clean_v4c l
    join obs_dates d on d.as_of_date=l.as_of_date
  ), daily_latest as (
    select * from (
      select f.*,row_number() over(partition by f.ticker,f.available_from_date order by f.published_at desc,f.filing_id desc) rn
      from public.flow_financial_filing_feature_v5 f
    ) z where rn=1
  ), intervals as (
    select f.*,lead(f.available_from_date) over(partition by f.ticker order by f.available_from_date) as next_available_date
    from daily_latest f
  ), current_rows as (
    select l.*,
      f.filing_id as current_filing_id,f.report_year,f.report_period,f.report_period_end,f.published_at,
      f.currency as current_currency,f.metric_count,
      f.sales,f.interest_income,f.gross_profit,f.profit_parent,f.profit_loss,
      f.assets,f.liabilities,f.equity,f.current_assets,f.current_liabilities,f.ocf
    from labels l
    left join intervals f on f.ticker=l.ticker
      and f.available_from_date<=l.as_of_date
      and (f.next_available_date is null or l.as_of_date<f.next_available_date)
  ), comparable as (
    select c.*,p.filing_id as prior_filing_id,p.currency as prior_currency,
      p.sales as prior_sales,p.interest_income as prior_interest_income,
      p.profit_parent as prior_profit_parent,p.profit_loss as prior_profit_loss
    from current_rows c
    left join lateral (
      select p.* from public.flow_financial_filing_feature_v5 p
      where p.ticker=c.ticker
        and p.report_year=c.report_year-1
        and p.report_period=c.report_period
        and p.available_from_date<=c.as_of_date
      order by p.available_from_date desc,p.published_at desc,p.filing_id desc
      limit 1
    ) p on c.current_filing_id is not null
  ), base as (
    select c.*,
      case when c.sector='Keuangan' then coalesce(c.interest_income,c.sales) else coalesce(c.sales,c.interest_income) end as revenue,
      case when c.sector='Keuangan' then coalesce(c.prior_interest_income,c.prior_sales) else coalesce(c.prior_sales,c.prior_interest_income) end as prior_revenue,
      coalesce(c.profit_parent,c.profit_loss) as profit,
      coalesce(c.prior_profit_parent,c.prior_profit_loss) as prior_profit,
      case when c.current_filing_id is null then 'MISSING'
           when c.report_period_end is null or coalesce(c.metric_count,0)<5 then 'INVALID'
           when c.as_of_date-c.report_period_end>220 then 'STALE'
           when c.prior_filing_id is null then 'INSUFFICIENT_HISTORY'
           else 'AVAILABLE' end as row_state
    from comparable c
  ), raw as (
    select b.*,
      case when b.row_state='AVAILABLE' and b.current_currency is not distinct from b.prior_currency and b.prior_revenue is not null and b.prior_revenue<>0
           then 100.0*(b.revenue/b.prior_revenue-1.0) end as revenue_growth,
      case when b.row_state='AVAILABLE' and b.current_currency is not distinct from b.prior_currency and b.prior_profit is not null and b.prior_profit<>0
           then 100.0*(b.profit/abs(b.prior_profit)-case when b.prior_profit<0 then -1.0 else 1.0 end) end as profit_growth,
      case when b.row_state not in ('MISSING','STALE','INVALID') and b.revenue is not null and b.revenue<>0 and b.profit is not null
           then 100.0*b.profit/abs(b.revenue) end as net_margin,
      case when b.sector<>'Keuangan' and b.row_state not in ('MISSING','STALE','INVALID') and b.revenue is not null and b.revenue<>0 and b.gross_profit is not null
           then 100.0*b.gross_profit/abs(b.revenue) end as gross_margin_raw,
      case when b.row_state not in ('MISSING','STALE','INVALID') and b.assets is not null and b.assets<>0 and b.equity is not null
           then 100.0*b.equity/abs(b.assets) end as equity_ratio_raw,
      case when b.sector<>'Keuangan' and b.row_state not in ('MISSING','STALE','INVALID') and b.current_liabilities is not null and b.current_liabilities<>0 and b.current_assets is not null
           then b.current_assets/abs(b.current_liabilities) end as current_ratio_raw,
      case when b.sector<>'Keuangan' and b.row_state not in ('MISSING','STALE','INVALID') and b.revenue is not null and b.revenue<>0 and b.ocf is not null
           then 100.0*b.ocf/abs(b.revenue) end as ocf_margin_raw,
      case when b.sector<>'Keuangan' and b.row_state not in ('MISSING','STALE','INVALID') and b.profit is not null and b.profit>0 and b.ocf is not null
           then b.ocf/b.profit end as ocf_conversion_raw
    from base b
  ), ranked as (
    select r.*,
      case when r.net_margin is not null then 100.0*percent_rank() over(partition by r.as_of_date,r.sector,(r.net_margin is null) order by r.net_margin) end as net_margin_rank,
      case when r.gross_margin_raw is not null then 100.0*percent_rank() over(partition by r.as_of_date,r.sector,(r.gross_margin_raw is null) order by r.gross_margin_raw) end as gross_margin_rank,
      case when r.equity_ratio_raw is not null then 100.0*percent_rank() over(partition by r.as_of_date,r.sector,(r.equity_ratio_raw is null) order by r.equity_ratio_raw) end as equity_ratio_rank,
      case when r.current_ratio_raw is not null then 100.0*percent_rank() over(partition by r.as_of_date,r.sector,(r.current_ratio_raw is null) order by r.current_ratio_raw) end as current_ratio_rank,
      case when r.ocf_margin_raw is not null then 100.0*percent_rank() over(partition by r.as_of_date,r.sector,(r.ocf_margin_raw is null) order by r.ocf_margin_raw) end as ocf_margin_rank,
      case when r.ocf_conversion_raw is not null then 100.0*percent_rank() over(partition by r.as_of_date,r.sector,(r.ocf_conversion_raw is null) order by r.ocf_conversion_raw) end as ocf_conversion_rank,
      case when r.revenue_growth is not null then 100.0*percent_rank() over(partition by r.as_of_date,r.sector,(r.revenue_growth is null) order by r.revenue_growth) end as revenue_growth_rank,
      case when r.profit_growth is not null then 100.0*percent_rank() over(partition by r.as_of_date,r.sector,(r.profit_growth is null) order by r.profit_growth) end as profit_growth_rank
    from raw r
  ), families as (
    select r.*,
      case when r.row_state in ('MISSING','STALE','INVALID') then null
           when r.sector='Keuangan' then r.net_margin_rank
           when num_nonnulls(r.net_margin_rank,r.gross_margin_rank)>0 then (coalesce(r.net_margin_rank,0)+coalesce(r.gross_margin_rank,0))/num_nonnulls(r.net_margin_rank,r.gross_margin_rank) end as quality,
      case when r.row_state='AVAILABLE' and num_nonnulls(r.revenue_growth_rank,r.profit_growth_rank)>0 then (coalesce(r.revenue_growth_rank,0)+coalesce(r.profit_growth_rank,0))/num_nonnulls(r.revenue_growth_rank,r.profit_growth_rank) end as growth,
      case when r.row_state in ('MISSING','STALE','INVALID') then null
           when r.sector='Keuangan' then r.equity_ratio_rank
           when num_nonnulls(r.equity_ratio_rank,r.current_ratio_rank)>0 then (coalesce(r.equity_ratio_rank,0)+coalesce(r.current_ratio_rank,0))/num_nonnulls(r.equity_ratio_rank,r.current_ratio_rank) end as balance,
      case when r.sector='Keuangan' or r.row_state in ('MISSING','STALE','INVALID') then null
           when num_nonnulls(r.ocf_margin_rank,r.ocf_conversion_rank)>0 then (coalesce(r.ocf_margin_rank,0)+coalesce(r.ocf_conversion_rank,0))/num_nonnulls(r.ocf_margin_rank,r.ocf_conversion_rank) end as cashflow
    from ranked r
  )
  insert into public.flow_financial_shadow_panel_v5(
    sample_contract,as_of_date,ticker,sector,financial_state,current_filing_id,prior_filing_id,
    quality_score,growth_score,balance_score,cashflow_score,financial_shadow_score,
    target_date_5d,target_date_20d,target_date_60d,
    clean_alpha_vs_sector_5d_pct,clean_alpha_vs_sector_20d_pct,clean_alpha_vs_sector_60d_pct,
    feature_states,source_verified,production_influence_enabled
  )
  select v_contract,f.as_of_date,f.ticker,f.sector,f.row_state,f.current_filing_id,f.prior_filing_id,
    f.quality,f.growth,f.balance,f.cashflow,
    case when f.row_state='AVAILABLE' and num_nonnulls(f.quality,f.growth,f.balance,f.cashflow)>=2
         then (coalesce(f.quality,0)+coalesce(f.growth,0)+coalesce(f.balance,0)+coalesce(f.cashflow,0))/num_nonnulls(f.quality,f.growth,f.balance,f.cashflow) end,
    f.target_date_5d,f.target_date_20d,f.target_date_60d,
    f.clean_alpha_vs_sector_5d_pct,f.clean_alpha_vs_sector_20d_pct,f.clean_alpha_vs_sector_60d_pct,
    jsonb_build_object(
      'row_state',f.row_state,
      'cashflow',case when f.sector='Keuangan' then 'NOT_APPLICABLE' when f.cashflow is null then 'MISSING' else 'AVAILABLE' end,
      'growth',case when f.row_state='INSUFFICIENT_HISTORY' then 'INSUFFICIENT_HISTORY' when f.growth is null then 'MISSING' else 'AVAILABLE' end
    ),
    true,false
  from families f
  on conflict(sample_contract,as_of_date,ticker) do update set
    sector=excluded.sector,financial_state=excluded.financial_state,current_filing_id=excluded.current_filing_id,prior_filing_id=excluded.prior_filing_id,
    quality_score=excluded.quality_score,growth_score=excluded.growth_score,balance_score=excluded.balance_score,cashflow_score=excluded.cashflow_score,
    financial_shadow_score=excluded.financial_shadow_score,target_date_5d=excluded.target_date_5d,target_date_20d=excluded.target_date_20d,target_date_60d=excluded.target_date_60d,
    clean_alpha_vs_sector_5d_pct=excluded.clean_alpha_vs_sector_5d_pct,clean_alpha_vs_sector_20d_pct=excluded.clean_alpha_vs_sector_20d_pct,
    clean_alpha_vs_sector_60d_pct=excluded.clean_alpha_vs_sector_60d_pct,feature_states=excluded.feature_states,
    source_verified=true,production_influence_enabled=false,captured_at=now();

  select jsonb_build_object(
    'status','OK','sample_contract',v_contract,'rows',count(*),'dates',count(distinct as_of_date),'tickers',count(distinct ticker),
    'min_date',min(as_of_date),'max_date',max(as_of_date),'available_rows',count(*) filter(where financial_state='AVAILABLE'),
    'scored_rows',count(*) filter(where financial_shadow_score is not null),
    'coverage_pct',round(100.0*count(*) filter(where financial_shadow_score is not null)/nullif(count(*),0),2),
    'production_influence_enabled',false
  ) into v_result
  from public.flow_financial_shadow_panel_v5
  where sample_contract=v_contract and as_of_date between p_start_date and p_end_date;
  return v_result;
end;
$fn$;

revoke all on function public.flow_refresh_financial_shadow_panel_v5(date,date) from public,anon,authenticated,service_role;
grant execute on function public.flow_refresh_financial_shadow_panel_v5(date,date) to service_role;
