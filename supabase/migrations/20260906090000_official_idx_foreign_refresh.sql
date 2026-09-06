create extension if not exists pg_cron;

create or replace function public.flow_refresh_official_idx_foreign(
  p_date date default ((now() at time zone 'Asia/Jakarta')::date)
)
returns integer
language plpgsql
security definer
set search_path = pg_catalog, public, extensions
as $$
declare
  req text;
  url text;
  payload jsonb;
  http_status integer;
  api_rows integer;
  payload_min date;
  payload_max date;
  affected integer := 0;
begin
  if extract(isodow from p_date) not between 1 and 5 then
    return 0;
  end if;

  req := to_char(p_date,'YYYYMMDD');
  url := 'https://block.idx.id/primary/TradingSummary/GetStockSummary?length=1000&start=0&date=' || req;

  select h.status, h.content::jsonb
    into http_status, payload
  from extensions.http_get(url) h;

  if http_status <> 200 then
    raise exception 'IDX stock summary HTTP % for %', http_status, p_date;
  end if;

  api_rows := coalesce(jsonb_array_length(coalesce(payload->'data','[]'::jsonb)),0);
  if api_rows = 0 then
    return 0;
  end if;
  if api_rows < 900 then
    raise exception 'IDX stock summary unexpectedly small for %: % rows', p_date, api_rows;
  end if;

  select min((x->>'Date')::date), max((x->>'Date')::date)
    into payload_min, payload_max
  from jsonb_array_elements(payload->'data') x;

  if payload_min is distinct from p_date or payload_max is distinct from p_date then
    raise exception 'IDX stock summary date mismatch: requested %, got % to %',
      p_date, payload_min, payload_max;
  end if;

  insert into public.flow_vendor_foreign_flows
    (ticker,trade_date,foreign_buy,foreign_sell,foreign_net,volume,traded_value,
     flow_unit,market_type,source,source_verified,source_url,provenance_state,retrieved_at)
  select
    upper(trim(x->>'StockCode')),
    (x->>'Date')::date,
    coalesce(nullif(x->>'ForeignBuy','')::numeric,0),
    coalesce(nullif(x->>'ForeignSell','')::numeric,0),
    coalesce(nullif(x->>'ForeignBuy','')::numeric,0)-coalesce(nullif(x->>'ForeignSell','')::numeric,0),
    coalesce(nullif(x->>'Volume','')::numeric,0),
    coalesce(nullif(x->>'Value','')::numeric,0),
    'SHARES',
    'ALL',
    'IDX_OFFICIAL_STOCK_SUMMARY',
    true,
    url,
    'VERIFIED_OFFICIAL_IDX_STOCK_SUMMARY_SHARE_FLOW',
    now()
  from jsonb_array_elements(payload->'data') x
  join public.flow_issuers i
    on upper(trim(i.ticker))=upper(trim(x->>'StockCode'))
  where nullif(trim(x->>'StockCode'),'') is not null
    and (x->>'Date')::date=p_date
    and coalesce(nullif(x->>'ForeignBuy','')::numeric,0) >= 0
    and coalesce(nullif(x->>'ForeignSell','')::numeric,0) >= 0
    and coalesce(nullif(x->>'Volume','')::numeric,0) >= 0
    and coalesce(nullif(x->>'Value','')::numeric,0) >= 0
  on conflict (ticker,trade_date,source,market_type) do update set
    foreign_buy=excluded.foreign_buy,
    foreign_sell=excluded.foreign_sell,
    foreign_net=excluded.foreign_net,
    volume=excluded.volume,
    traded_value=excluded.traded_value,
    flow_unit=excluded.flow_unit,
    source_verified=excluded.source_verified,
    source_url=excluded.source_url,
    provenance_state=excluded.provenance_state,
    retrieved_at=excluded.retrieved_at;

  get diagnostics affected = row_count;
  return affected;
end;
$$;

revoke all on function public.flow_refresh_official_idx_foreign(date)
  from public, anon, authenticated;
grant execute on function public.flow_refresh_official_idx_foreign(date)
  to service_role;

do $$
declare r record;
begin
  for r in
    select jobid from cron.job where jobname='flow-official-idx-foreign-daily'
  loop
    perform cron.unschedule(r.jobid);
  end loop;

  perform cron.schedule(
    'flow-official-idx-foreign-daily',
    '45 10 * * 1-5',
    $cron$select public.flow_refresh_official_idx_foreign((now() at time zone 'Asia/Jakarta')::date);$cron$
  );
end $$;
