-- Phase 1: historical official-data foundation for future broker-affinity research.
-- This migration does not change production scoring or weights.

create table if not exists public.flow_official_stock_summary (
  trade_date date not null,
  ticker text not null,
  stock_name text,
  previous numeric,
  open numeric,
  high numeric,
  low numeric,
  close numeric,
  change numeric,
  volume numeric not null default 0,
  traded_value numeric not null default 0,
  frequency numeric not null default 0,
  foreign_buy numeric not null default 0,
  foreign_sell numeric not null default 0,
  listed_shares numeric,
  tradable_shares numeric,
  bid numeric,
  offer numeric,
  bid_volume numeric,
  offer_volume numeric,
  non_regular_volume numeric,
  non_regular_value numeric,
  non_regular_frequency numeric,
  source text not null default 'IDX_OFFICIAL_STOCK_SUMMARY',
  source_verified boolean not null default true,
  source_url text,
  provenance_state text not null default 'VERIFIED_OFFICIAL_IDX_STOCK_SUMMARY_RAW_PANEL',
  ingested_at timestamptz not null default now(),
  primary key (trade_date,ticker,source)
);

create index if not exists flow_official_stock_summary_ticker_date_idx
  on public.flow_official_stock_summary (ticker,trade_date desc);
create index if not exists flow_official_stock_summary_date_idx
  on public.flow_official_stock_summary (trade_date desc,ticker);

alter table public.flow_official_stock_summary enable row level security;
revoke all on table public.flow_official_stock_summary from public, anon, authenticated;
grant select,insert,update,delete on table public.flow_official_stock_summary to service_role;

create or replace function public.flow_refresh_official_idx_stock_summary(
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
  records_total integer;
  payload_min date;
  payload_max date;
  affected integer := 0;
begin
  if extract(isodow from p_date) not between 1 and 5 then
    return 0;
  end if;

  url := 'https://block.idx.id/primary/TradingSummary/GetStockSummary?length=2000&start=0&date=' ||
    to_char(p_date,'YYYYMMDD');

  select h.status,h.content::jsonb
    into http_status,payload
  from extensions.http_get(url) h;

  if http_status <> 200 then
    raise exception 'IDX stock summary raw HTTP % for %', http_status,p_date;
  end if;

  api_rows := coalesce(jsonb_array_length(coalesce(payload->'data','[]'::jsonb)),0);
  records_total := nullif(payload->>'recordsTotal','')::integer;
  if api_rows = 0 then
    return 0;
  end if;
  if records_total is null or api_rows <> records_total then
    raise exception 'IDX stock summary raw incomplete page for %: rows %, total %',
      p_date,api_rows,records_total;
  end if;
  if api_rows < 800 then
    raise exception 'IDX stock summary raw unexpectedly small for %: % rows', p_date,api_rows;
  end if;

  select min((x->>'Date')::date),max((x->>'Date')::date)
    into payload_min,payload_max
  from jsonb_array_elements(payload->'data') x;

  if payload_min is distinct from p_date or payload_max is distinct from p_date then
    raise exception 'IDX stock summary raw date mismatch: requested %, got % to %',
      p_date,payload_min,payload_max;
  end if;

  insert into public.flow_official_stock_summary
    (trade_date,ticker,stock_name,previous,open,high,low,close,change,
     volume,traded_value,frequency,foreign_buy,foreign_sell,listed_shares,tradable_shares,
     bid,offer,bid_volume,offer_volume,non_regular_volume,non_regular_value,
     non_regular_frequency,source,source_verified,source_url,provenance_state,ingested_at)
  select
    (x->>'Date')::date,
    upper(trim(x->>'StockCode')),
    nullif(trim(x->>'StockName'),''),
    nullif(x->>'Previous','')::numeric,
    nullif(x->>'OpenPrice','')::numeric,
    nullif(x->>'High','')::numeric,
    nullif(x->>'Low','')::numeric,
    nullif(x->>'Close','')::numeric,
    nullif(x->>'Change','')::numeric,
    coalesce(nullif(x->>'Volume','')::numeric,0),
    coalesce(nullif(x->>'Value','')::numeric,0),
    coalesce(nullif(x->>'Frequency','')::numeric,0),
    coalesce(nullif(x->>'ForeignBuy','')::numeric,0),
    coalesce(nullif(x->>'ForeignSell','')::numeric,0),
    nullif(x->>'ListedShares','')::numeric,
    nullif(x->>'TradebleShares','')::numeric,
    nullif(x->>'Bid','')::numeric,
    nullif(x->>'Offer','')::numeric,
    nullif(x->>'BidVolume','')::numeric,
    nullif(x->>'OfferVolume','')::numeric,
    nullif(x->>'NonRegularVolume','')::numeric,
    nullif(x->>'NonRegularValue','')::numeric,
    nullif(x->>'NonRegularFrequency','')::numeric,
    'IDX_OFFICIAL_STOCK_SUMMARY',
    true,
    url,
    'VERIFIED_OFFICIAL_IDX_STOCK_SUMMARY_RAW_PANEL',
    now()
  from jsonb_array_elements(payload->'data') x
  where nullif(trim(x->>'StockCode'),'') is not null
    and (x->>'Date')::date=p_date
    and coalesce(nullif(x->>'Volume','')::numeric,0) >= 0
    and coalesce(nullif(x->>'Value','')::numeric,0) >= 0
    and coalesce(nullif(x->>'Frequency','')::numeric,0) >= 0
    and coalesce(nullif(x->>'ForeignBuy','')::numeric,0) >= 0
    and coalesce(nullif(x->>'ForeignSell','')::numeric,0) >= 0
  on conflict (trade_date,ticker,source) do update set
    stock_name=excluded.stock_name,
    previous=excluded.previous,
    open=excluded.open,
    high=excluded.high,
    low=excluded.low,
    close=excluded.close,
    change=excluded.change,
    volume=excluded.volume,
    traded_value=excluded.traded_value,
    frequency=excluded.frequency,
    foreign_buy=excluded.foreign_buy,
    foreign_sell=excluded.foreign_sell,
    listed_shares=excluded.listed_shares,
    tradable_shares=excluded.tradable_shares,
    bid=excluded.bid,
    offer=excluded.offer,
    bid_volume=excluded.bid_volume,
    offer_volume=excluded.offer_volume,
    non_regular_volume=excluded.non_regular_volume,
    non_regular_value=excluded.non_regular_value,
    non_regular_frequency=excluded.non_regular_frequency,
    source_verified=excluded.source_verified,
    source_url=excluded.source_url,
    provenance_state=excluded.provenance_state,
    ingested_at=excluded.ingested_at;

  get diagnostics affected=row_count;
  return affected;
end;
$$;

revoke all on function public.flow_refresh_official_idx_stock_summary(date)
  from public, anon, authenticated;
grant execute on function public.flow_refresh_official_idx_stock_summary(date)
  to service_role;

-- Chunked backfill helper. Deliberately limited to 31 calendar days per call so
-- historical acquisition cannot accidentally hammer the public IDX endpoint.
create or replace function public.flow_backfill_official_idx_phase1(
  p_start_date date,
  p_end_date date
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, extensions
as $$
declare
  d date;
  n integer;
  stock_rows bigint := 0;
  broker_rows bigint := 0;
  index_rows bigint := 0;
  failures integer := 0;
  started timestamptz;
begin
  if p_start_date is null or p_end_date is null or p_start_date > p_end_date then
    raise exception 'invalid phase1 backfill window: % to %', p_start_date,p_end_date;
  end if;
  if (p_end_date-p_start_date) > 31 then
    raise exception 'phase1 backfill window exceeds 31 calendar days: % to %', p_start_date,p_end_date;
  end if;

  for d in
    select gs::date
    from generate_series(p_start_date,p_end_date,interval '1 day') gs
    where extract(isodow from gs) between 1 and 5
  loop
    started := clock_timestamp();
    begin
      n := public.flow_refresh_official_idx_stock_summary(d);
      stock_rows := stock_rows + n;
      insert into public.flow_ingestion_audit
        (provider,dataset,started_at,completed_at,status,rows_received,rows_accepted,
         rows_rejected,freshness_date,details)
      values
        ('IDX_OFFICIAL_BLOCK','STOCK_SUMMARY_RAW',started,clock_timestamp(),
         case when n=0 then 'NO_DATA' else 'OK' end,n,n,0,d,
         jsonb_build_object('source','block.idx.id','phase','PHASE1_HISTORICAL_FOUNDATION'));
    exception when others then
      failures := failures+1;
      insert into public.flow_ingestion_audit
        (provider,dataset,started_at,completed_at,status,rows_received,rows_accepted,
         rows_rejected,freshness_date,error_code,details)
      values
        ('IDX_OFFICIAL_BLOCK','STOCK_SUMMARY_RAW',started,clock_timestamp(),'FAILED',0,0,0,d,
         sqlstate,jsonb_build_object('error',sqlerrm,'source','block.idx.id','phase','PHASE1_HISTORICAL_FOUNDATION'));
    end;

    started := clock_timestamp();
    begin
      n := public.flow_refresh_official_idx_foreign(d);
      insert into public.flow_ingestion_audit
        (provider,dataset,started_at,completed_at,status,rows_received,rows_accepted,
         rows_rejected,freshness_date,details)
      values
        ('IDX_OFFICIAL_BLOCK','STOCK_SUMMARY_FOREIGN',started,clock_timestamp(),
         case when n=0 then 'NO_DATA' else 'OK' end,n,n,0,d,
         jsonb_build_object('source','block.idx.id','phase','PHASE1_HISTORICAL_FOUNDATION'));
    exception when others then
      failures := failures+1;
      insert into public.flow_ingestion_audit
        (provider,dataset,started_at,completed_at,status,rows_received,rows_accepted,
         rows_rejected,freshness_date,error_code,details)
      values
        ('IDX_OFFICIAL_BLOCK','STOCK_SUMMARY_FOREIGN',started,clock_timestamp(),'FAILED',0,0,0,d,
         sqlstate,jsonb_build_object('error',sqlerrm,'source','block.idx.id','phase','PHASE1_HISTORICAL_FOUNDATION'));
    end;

    started := clock_timestamp();
    begin
      n := public.flow_refresh_official_idx_broker_activity(d);
      broker_rows := broker_rows+n;
      insert into public.flow_ingestion_audit
        (provider,dataset,started_at,completed_at,status,rows_received,rows_accepted,
         rows_rejected,freshness_date,details)
      values
        ('IDX_OFFICIAL_BLOCK','BROKER_SUMMARY',started,clock_timestamp(),
         case when n=0 then 'NO_DATA' else 'OK' end,n,n,0,d,
         jsonb_build_object('source','block.idx.id','phase','PHASE1_HISTORICAL_FOUNDATION'));
    exception when others then
      failures := failures+1;
      insert into public.flow_ingestion_audit
        (provider,dataset,started_at,completed_at,status,rows_received,rows_accepted,
         rows_rejected,freshness_date,error_code,details)
      values
        ('IDX_OFFICIAL_BLOCK','BROKER_SUMMARY',started,clock_timestamp(),'FAILED',0,0,0,d,
         sqlstate,jsonb_build_object('error',sqlerrm,'source','block.idx.id','phase','PHASE1_HISTORICAL_FOUNDATION'));
    end;

    started := clock_timestamp();
    begin
      n := public.flow_refresh_official_idx_index(d);
      index_rows := index_rows+n;
      insert into public.flow_ingestion_audit
        (provider,dataset,started_at,completed_at,status,rows_received,rows_accepted,
         rows_rejected,freshness_date,details)
      values
        ('IDX_OFFICIAL_BLOCK','INDEX_SUMMARY',started,clock_timestamp(),
         case when n=0 then 'NO_DATA' else 'OK' end,n,n,0,d,
         jsonb_build_object('source','block.idx.id','phase','PHASE1_HISTORICAL_FOUNDATION'));
    exception when others then
      failures := failures+1;
      insert into public.flow_ingestion_audit
        (provider,dataset,started_at,completed_at,status,rows_received,rows_accepted,
         rows_rejected,freshness_date,error_code,details)
      values
        ('IDX_OFFICIAL_BLOCK','INDEX_SUMMARY',started,clock_timestamp(),'FAILED',0,0,0,d,
         sqlstate,jsonb_build_object('error',sqlerrm,'source','block.idx.id','phase','PHASE1_HISTORICAL_FOUNDATION'));
    end;
  end loop;

  -- Foreign rows are stored by the pre-existing authoritative foreign function.
  select count(*) into n from public.flow_vendor_foreign_flows
   where source='IDX_OFFICIAL_STOCK_SUMMARY'
     and trade_date between p_start_date and p_end_date;

  return jsonb_build_object(
    'start_date',p_start_date,
    'end_date',p_end_date,
    'stock_raw_rows_touched',stock_rows,
    'broker_rows_touched',broker_rows,
    'index_rows_touched',index_rows,
    'foreign_rows_present_in_window',n,
    'failures',failures
  );
end;
$$;

revoke all on function public.flow_backfill_official_idx_phase1(date,date)
  from public, anon, authenticated;
grant execute on function public.flow_backfill_official_idx_phase1(date,date)
  to service_role;

create or replace view public.flow_phase1_historical_coverage as
with stock_daily as (
  select trade_date,count(*)::bigint as entities
  from public.flow_official_stock_summary
  where source='IDX_OFFICIAL_STOCK_SUMMARY' and source_verified
  group by trade_date
), broker_daily as (
  select trade_date,count(*)::bigint as entities
  from public.flow_official_broker_activity
  where source='IDX_OFFICIAL_BROKER_SUMMARY' and source_verified
  group by trade_date
), index_daily as (
  select trade_date,count(*)::bigint as entities
  from public.flow_official_index_summary
  where source='IDX_OFFICIAL_INDEX_SUMMARY' and source_verified
  group by trade_date
), foreign_daily as (
  select trade_date,count(*)::bigint as entities
  from public.flow_vendor_foreign_flows
  where source='IDX_OFFICIAL_STOCK_SUMMARY' and source_verified
  group by trade_date
)
select 'STOCK_SUMMARY_RAW'::text dataset,count(*)::bigint sessions,min(trade_date) first_date,max(trade_date) last_date,
       min(entities)::bigint min_entities_per_session,max(entities)::bigint max_entities_per_session,
       round(avg(entities),2) avg_entities_per_session
from stock_daily
union all
select 'STOCK_SUMMARY_FOREIGN',count(*)::bigint,min(trade_date),max(trade_date),min(entities)::bigint,max(entities)::bigint,round(avg(entities),2)
from foreign_daily
union all
select 'BROKER_SUMMARY',count(*)::bigint,min(trade_date),max(trade_date),min(entities)::bigint,max(entities)::bigint,round(avg(entities),2)
from broker_daily
union all
select 'INDEX_SUMMARY',count(*)::bigint,min(trade_date),max(trade_date),min(entities)::bigint,max(entities)::bigint,round(avg(entities),2)
from index_daily;

revoke all on public.flow_phase1_historical_coverage from public, anon, authenticated;
grant select on public.flow_phase1_historical_coverage to service_role;

-- Daily raw stock panel refresh. Existing foreign/broker/index jobs remain intact.
do $$
declare r record;
begin
  for r in select jobid from cron.job where jobname='flow-official-idx-stock-raw-daily' loop
    perform cron.unschedule(r.jobid);
  end loop;
  perform cron.schedule(
    'flow-official-idx-stock-raw-daily',
    '48 10 * * 1-5',
    $cron$select public.flow_refresh_official_idx_stock_summary((now() at time zone 'Asia/Jakarta')::date);$cron$
  );
end $$;
