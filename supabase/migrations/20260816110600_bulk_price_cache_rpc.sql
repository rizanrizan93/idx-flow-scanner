create or replace function public.flow_load_price_cache(
  p_tickers text[],
  p_limit integer default 450
)
returns table (
  ticker text,
  trade_date date,
  open numeric,
  high numeric,
  low numeric,
  close numeric,
  volume numeric
)
language sql
stable
security definer
set search_path = public
as $$
  with ranked as (
    select
      p.ticker,
      p.trade_date,
      p.open,
      p.high,
      p.low,
      p.close,
      p.volume,
      row_number() over (
        partition by p.ticker
        order by p.trade_date desc
      ) as rn
    from public.flow_daily_prices p
    where p.ticker = any(p_tickers)
  )
  select
    ranked.ticker,
    ranked.trade_date,
    ranked.open,
    ranked.high,
    ranked.low,
    ranked.close,
    ranked.volume
  from ranked
  where ranked.rn <= greatest(1, least(coalesce(p_limit, 450), 600))
  order by ranked.ticker, ranked.trade_date;
$$;

revoke all on function public.flow_load_price_cache(text[], integer) from public, anon, authenticated;
grant execute on function public.flow_load_price_cache(text[], integer) to service_role;

comment on function public.flow_load_price_cache(text[], integer) is
  'Bulk database-first OHLCV loader: returns at most p_limit recent rows per ticker to avoid one PostgREST request per symbol.';
