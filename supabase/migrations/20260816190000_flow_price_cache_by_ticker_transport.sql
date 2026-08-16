create or replace function public.flow_load_price_cache_by_ticker(
  p_tickers text[],
  p_limit integer default 320
)
returns table(ticker text, payload jsonb)
language sql
stable
security invoker
set search_path = 'public'
as $function$
  with requested as (
    select distinct upper(trim(x)) as ticker
    from unnest(coalesce(p_tickers, array[]::text[])) as x
    where trim(coalesce(x,'')) <> ''
  ),
  dedup as (
    select distinct on (p.ticker, p.trade_date)
      p.ticker, p.trade_date, p.open, p.high, p.low, p.close, p.volume
    from public.flow_daily_prices p
    join requested r on r.ticker = p.ticker
    order by p.ticker, p.trade_date desc, p.ingested_at desc nulls last, p.source asc
  ),
  ranked as (
    select d.*,
           row_number() over (partition by d.ticker order by d.trade_date desc) as rn
    from dedup d
  )
  select r.ticker,
         jsonb_agg(
           jsonb_build_object(
             'trade_date', r.trade_date,
             'open', r.open,
             'high', r.high,
             'low', r.low,
             'close', r.close,
             'volume', r.volume
           ) order by r.trade_date
         ) as payload
  from ranked r
  where r.rn <= greatest(1, least(coalesce(p_limit,320),600))
  group by r.ticker
  order by r.ticker;
$function$;

revoke all on function public.flow_load_price_cache_by_ticker(text[], integer) from public;
revoke all on function public.flow_load_price_cache_by_ticker(text[], integer) from anon;
revoke all on function public.flow_load_price_cache_by_ticker(text[], integer) from authenticated;
grant execute on function public.flow_load_price_cache_by_ticker(text[], integer) to service_role;
