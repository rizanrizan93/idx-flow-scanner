create table if not exists public.flow_official_index_summary (
  trade_date date not null,
  index_code text not null,
  previous numeric,
  highest numeric,
  lowest numeric,
  close numeric,
  number_of_stock numeric,
  change numeric,
  volume numeric,
  traded_value numeric,
  frequency numeric,
  market_capital numeric,
  source text not null default 'IDX_OFFICIAL_INDEX_SUMMARY',
  source_verified boolean not null default true,
  source_url text,
  provenance_state text not null default 'VERIFIED_OFFICIAL_IDX_INDEX_SUMMARY',
  ingested_at timestamptz not null default now(),
  primary key (trade_date,index_code,source)
);

create index if not exists flow_official_index_summary_code_date_idx
  on public.flow_official_index_summary (index_code,trade_date desc);

revoke all on public.flow_official_index_summary from public, anon, authenticated;
grant all on public.flow_official_index_summary to service_role;

create or replace function public.flow_refresh_official_idx_index(
  p_date date default ((now() at time zone 'Asia/Jakarta')::date)
)
returns integer
language plpgsql
security definer
set search_path = pg_catalog, public, extensions
as $$
declare
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

  url := 'https://block.idx.id/primary/TradingSummary/GetIndexSummary?length=1000&start=0&date=' ||
    to_char(p_date,'YYYYMMDD');
  select h.status,h.content::jsonb
    into http_status,payload
  from extensions.http_get(url) h;

  if http_status <> 200 then
    raise exception 'IDX index summary HTTP % for %', http_status,p_date;
  end if;

  api_rows := coalesce(jsonb_array_length(coalesce(payload->'data','[]'::jsonb)),0);
  if api_rows = 0 then
    return 0;
  end if;
  if api_rows < 40 then
    raise exception 'IDX index summary unexpectedly small for %: % rows', p_date,api_rows;
  end if;

  select min((x->>'Date')::date),max((x->>'Date')::date)
    into payload_min,payload_max
  from jsonb_array_elements(payload->'data') x;

  if payload_min is distinct from p_date or payload_max is distinct from p_date then
    raise exception 'IDX index summary date mismatch: requested %, got % to %',
      p_date,payload_min,payload_max;
  end if;

  insert into public.flow_official_index_summary
    (trade_date,index_code,previous,highest,lowest,close,number_of_stock,change,
     volume,traded_value,frequency,market_capital,source,source_verified,source_url,
     provenance_state,ingested_at)
  select
    (x->>'Date')::date,
    upper(trim(x->>'IndexCode')),
    nullif(x->>'Previous','')::numeric,
    nullif(x->>'Highest','')::numeric,
    nullif(x->>'Lowest','')::numeric,
    nullif(x->>'Close','')::numeric,
    nullif(x->>'NumberOfStock','')::numeric,
    nullif(x->>'Change','')::numeric,
    nullif(x->>'Volume','')::numeric,
    nullif(x->>'Value','')::numeric,
    nullif(x->>'Frequency','')::numeric,
    nullif(x->>'MarketCapital','')::numeric,
    'IDX_OFFICIAL_INDEX_SUMMARY',
    true,
    url,
    'VERIFIED_OFFICIAL_IDX_INDEX_SUMMARY',
    now()
  from jsonb_array_elements(payload->'data') x
  where nullif(trim(x->>'IndexCode'),'') is not null
    and (x->>'Date')::date=p_date
    and coalesce(nullif(x->>'Close','')::numeric,0) > 0
  on conflict (trade_date,index_code,source) do update set
    previous=excluded.previous,
    highest=excluded.highest,
    lowest=excluded.lowest,
    close=excluded.close,
    number_of_stock=excluded.number_of_stock,
    change=excluded.change,
    volume=excluded.volume,
    traded_value=excluded.traded_value,
    frequency=excluded.frequency,
    market_capital=excluded.market_capital,
    source_verified=excluded.source_verified,
    source_url=excluded.source_url,
    provenance_state=excluded.provenance_state,
    ingested_at=excluded.ingested_at;

  get diagnostics affected=row_count;
  return affected;
end;
$$;

revoke all on function public.flow_refresh_official_idx_index(date)
  from public, anon, authenticated;
grant execute on function public.flow_refresh_official_idx_index(date)
  to service_role;

do $$
declare r record;
begin
  for r in
    select jobid from cron.job where jobname='flow-official-idx-index-daily'
  loop
    perform cron.unschedule(r.jobid);
  end loop;

  perform cron.schedule(
    'flow-official-idx-index-daily',
    '5 11 * * 1-5',
    $cron$select public.flow_refresh_official_idx_index((now() at time zone 'Asia/Jakarta')::date);$cron$
  );
end $$;
