create table if not exists public.flow_official_broker_activity (
  trade_date date not null,
  broker_code text not null,
  broker_name text,
  traded_value numeric not null default 0,
  volume numeric not null default 0,
  frequency numeric not null default 0,
  source text not null default 'IDX_OFFICIAL_BROKER_SUMMARY',
  source_verified boolean not null default true,
  source_url text,
  provenance_state text,
  ingested_at timestamptz not null default now(),
  primary key (trade_date, broker_code, source)
);

create index if not exists flow_official_broker_activity_date_idx
  on public.flow_official_broker_activity (trade_date desc, broker_code);

alter table public.flow_official_broker_activity enable row level security;
revoke all on table public.flow_official_broker_activity from public, anon, authenticated;
grant select, insert, update, delete on table public.flow_official_broker_activity to service_role;

create or replace function public.flow_refresh_official_idx_broker_activity(
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
  url := 'https://block.idx.id/primary/TradingSummary/GetBrokerSummary?length=200&start=0&date=' || req;

  select h.status, h.content::jsonb
    into http_status, payload
  from extensions.http_get(url) h;

  if http_status <> 200 then
    raise exception 'IDX broker summary HTTP % for %', http_status, p_date;
  end if;

  api_rows := coalesce(jsonb_array_length(coalesce(payload->'data','[]'::jsonb)),0);
  if api_rows = 0 then
    return 0;
  end if;
  if api_rows < 70 then
    raise exception 'IDX broker summary unexpectedly small for %: % rows', p_date, api_rows;
  end if;

  select min((x->>'Date')::date), max((x->>'Date')::date)
    into payload_min, payload_max
  from jsonb_array_elements(payload->'data') x;

  if payload_min is distinct from p_date or payload_max is distinct from p_date then
    raise exception 'IDX broker summary date mismatch: requested %, got % to %',
      p_date, payload_min, payload_max;
  end if;

  insert into public.flow_official_broker_activity
    (trade_date,broker_code,broker_name,traded_value,volume,frequency,
     source,source_verified,source_url,provenance_state,ingested_at)
  select
    (x->>'Date')::date,
    upper(trim(x->>'IDFirm')),
    nullif(trim(x->>'FirmName'),''),
    coalesce(nullif(x->>'Value','')::numeric,0),
    coalesce(nullif(x->>'Volume','')::numeric,0),
    coalesce(nullif(x->>'Frequency','')::numeric,0),
    'IDX_OFFICIAL_BROKER_SUMMARY',
    true,
    url,
    'VERIFIED_OFFICIAL_IDX_MARKET_WIDE_BROKER_ACTIVITY_NO_BUY_SELL_SPLIT',
    now()
  from jsonb_array_elements(payload->'data') x
  where nullif(trim(x->>'IDFirm'),'') is not null
    and (x->>'Date')::date=p_date
    and coalesce(nullif(x->>'Value','')::numeric,0) >= 0
    and coalesce(nullif(x->>'Volume','')::numeric,0) >= 0
    and coalesce(nullif(x->>'Frequency','')::numeric,0) >= 0
  on conflict (trade_date,broker_code,source) do update set
    broker_name=excluded.broker_name,
    traded_value=excluded.traded_value,
    volume=excluded.volume,
    frequency=excluded.frequency,
    source_verified=excluded.source_verified,
    source_url=excluded.source_url,
    provenance_state=excluded.provenance_state,
    ingested_at=excluded.ingested_at;

  get diagnostics affected = row_count;
  return affected;
end;
$$;

revoke all on function public.flow_refresh_official_idx_broker_activity(date)
  from public, anon, authenticated;
grant execute on function public.flow_refresh_official_idx_broker_activity(date)
  to service_role;

create extension if not exists pg_cron;
do $$
declare r record;
begin
  for r in select jobid from cron.job where jobname='flow-official-idx-broker-daily' loop
    perform cron.unschedule(r.jobid);
  end loop;
  perform cron.schedule(
    'flow-official-idx-broker-daily',
    '50 10 * * 1-5',
    $cron$select public.flow_refresh_official_idx_broker_activity((now() at time zone 'Asia/Jakarta')::date);$cron$
  );
end $$;
