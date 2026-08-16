with ranked as (
  select id,
         row_number() over (
           partition by config->>'universe_signature'
           order by heartbeat_at desc nulls last, started_at desc, id desc
         ) as rn
  from public.flow_scan_runs
  where status='RUNNING'
    and coalesce(config->>'universe_signature','') <> ''
)
update public.flow_scan_runs r
set status='FAILED', completed_at=now(), current_ticker=null
from ranked x
where r.id=x.id and x.rn>1;

drop index if exists public.flow_scan_runs_single_active_managed_idx;
create unique index if not exists flow_scan_runs_single_active_universe_idx
on public.flow_scan_runs ((config->>'universe_signature'))
where status='RUNNING' and coalesce(config->>'universe_signature','') <> '';

create or replace function public.flow_load_price_cache(
  p_tickers text[], p_limit integer default 450
)
returns table(
  ticker text, trade_date date, open numeric, high numeric, low numeric, close numeric, volume numeric
)
language sql
stable
security invoker
set search_path=public
as $$
  with ranked as (
    select p.ticker,p.trade_date,p.open,p.high,p.low,p.close,p.volume,
           row_number() over (partition by p.ticker order by p.trade_date desc) as rn
    from public.flow_daily_prices p
    where p.ticker = any(p_tickers)
  )
  select ticker,trade_date,open,high,low,close,volume
  from ranked
  where rn <= greatest(1, least(coalesce(p_limit,450),600))
  order by ticker,trade_date;
$$;

revoke all on function public.flow_load_price_cache(text[],integer) from public, anon, authenticated;
grant execute on function public.flow_load_price_cache(text[],integer) to service_role;

create or replace function public.flow_load_price_cache_json(
  p_tickers text[], p_limit integer default 450
)
returns table(payload jsonb)
language sql
stable
security invoker
set search_path=public
as $$
  with ranked as (
    select p.ticker,p.trade_date,p.open,p.high,p.low,p.close,p.volume,
           row_number() over (partition by p.ticker order by p.trade_date desc) as rn
    from public.flow_daily_prices p
    where p.ticker = any(p_tickers)
  )
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'ticker',ticker,'trade_date',trade_date,'open',open,'high',high,
        'low',low,'close',close,'volume',volume
      ) order by ticker,trade_date
    ),
    '[]'::jsonb
  ) as payload
  from ranked
  where rn <= greatest(1, least(coalesce(p_limit,450),600));
$$;

revoke all on function public.flow_load_price_cache_json(text[],integer) from public, anon, authenticated;
grant execute on function public.flow_load_price_cache_json(text[],integer) to service_role;