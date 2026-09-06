create table if not exists public.flow_official_risk_events (
  ticker text not null,
  event_date date not null,
  event_type text not null,
  source_ref text not null,
  title text,
  announcement_no text,
  raw_info_type text,
  status_code text,
  source text not null default 'IDX_OFFICIAL_RISK_EVENT',
  source_url text,
  source_verified boolean not null default true,
  provenance_state text not null default 'VERIFIED_OFFICIAL_IDX_MARKET_RISK_EVENT',
  ingested_at timestamptz not null default now(),
  primary key (ticker,event_date,event_type,source_ref)
);

create index if not exists flow_official_risk_events_ticker_date_idx
  on public.flow_official_risk_events (ticker,event_date desc);

revoke all on public.flow_official_risk_events from public, anon, authenticated;
grant all on public.flow_official_risk_events to service_role;

create or replace function public.flow_refresh_official_idx_risk(
  p_from date default ((now() at time zone 'Asia/Jakarta')::date - 30),
  p_to date default ((now() at time zone 'Asia/Jakarta')::date)
)
returns integer
language plpgsql
security definer
set search_path = pg_catalog, public, extensions
as $$
declare
  u_url text;
  s_url text;
  u_payload jsonb;
  s_payload jsonb;
  u_status integer;
  s_status integer;
  affected integer := 0;
  n integer := 0;
begin
  if p_from is null or p_to is null or p_from > p_to then
    raise exception 'invalid risk refresh date range: % to %', p_from, p_to;
  end if;

  u_url := 'https://block.idx.id/primary/NewsAnnouncement/GetUma?dateFrom=' ||
    to_char(p_from,'YYYYMMDD') || '&dateTo=' || to_char(p_to,'YYYYMMDD') ||
    '&indexfrom=0&pagesize=5000';
  s_url := 'https://block.idx.id/primary/NewsAnnouncement/GetSuspension?dateFrom=' ||
    to_char(p_from,'YYYYMMDD') || '&dateTo=' || to_char(p_to,'YYYYMMDD') ||
    '&indexfrom=0&pagesize=5000';

  select h.status, h.content::jsonb into u_status,u_payload from extensions.http_get(u_url) h;
  select h.status, h.content::jsonb into s_status,s_payload from extensions.http_get(s_url) h;

  if u_status <> 200 then raise exception 'IDX UMA HTTP %', u_status; end if;
  if s_status <> 200 then raise exception 'IDX suspension HTTP %', s_status; end if;

  insert into public.flow_official_risk_events
    (ticker,event_date,event_type,source_ref,title,announcement_no,raw_info_type,status_code,
     source,source_url,source_verified,provenance_state,ingested_at)
  select
    upper(trim(x->>'CompanyID')),
    (x->>'UMADate')::date,
    'UMA',
    coalesce(nullif(trim(x->>'UMAID'),''), nullif(trim(x->>'AnnouncementNo'),''),
             upper(trim(x->>'CompanyID')) || ':' || (x->>'UMADate')::date::text),
    nullif(x->>'Judul',''),
    nullif(x->>'AnnouncementNo',''),
    null,
    nullif(x->>'Status',''),
    'IDX_OFFICIAL_RISK_EVENT',
    case when coalesce(x->>'Attachment','') like '/%'
      then 'https://block.idx.id' || (x->>'Attachment')
      else nullif(x->>'Attachment','') end,
    true,
    'VERIFIED_OFFICIAL_IDX_MARKET_RISK_EVENT',
    now()
  from jsonb_array_elements(coalesce(u_payload->'Results','[]'::jsonb)) x
  join public.flow_issuers i on upper(trim(i.ticker))=upper(trim(x->>'CompanyID'))
  where nullif(trim(x->>'CompanyID'),'') is not null
    and nullif(x->>'UMADate','') is not null
    and (x->>'UMADate')::date between p_from and p_to
  on conflict (ticker,event_date,event_type,source_ref) do update set
    title=excluded.title,
    announcement_no=excluded.announcement_no,
    status_code=excluded.status_code,
    source_url=excluded.source_url,
    source_verified=excluded.source_verified,
    provenance_state=excluded.provenance_state,
    ingested_at=excluded.ingested_at;

  get diagnostics n = row_count;
  affected := affected + n;

  insert into public.flow_official_risk_events
    (ticker,event_date,event_type,source_ref,title,announcement_no,raw_info_type,status_code,
     source,source_url,source_verified,provenance_state,ingested_at)
  select
    upper(trim(x->>'Kode')),
    (x->>'Date')::date,
    case
      when upper(coalesce(x->>'Info_Type',''))='UPT'
        or lower(coalesce(x->>'Judul','')) like '%unsuspend%'
        or lower(coalesce(x->>'Judul','')) like '%pembukaan%penghentian sementara%'
      then 'UNSUSPEND'
      else 'SUSPEND'
    end,
    coalesce(nullif(trim(x->>'Data_Download'),''),
             upper(trim(x->>'Kode')) || ':' || (x->>'Date')::date::text || ':' ||
             coalesce(x->>'Info_Type','')),
    nullif(x->>'Judul',''),
    null,
    nullif(x->>'Info_Type',''),
    null,
    'IDX_OFFICIAL_RISK_EVENT',
    case when coalesce(x->>'Data_Download','') like '/%'
      then 'https://block.idx.id' || (x->>'Data_Download')
      else nullif(x->>'Data_Download','') end,
    true,
    'VERIFIED_OFFICIAL_IDX_MARKET_RISK_EVENT',
    now()
  from jsonb_array_elements(coalesce(s_payload->'Results','[]'::jsonb)) x
  join public.flow_issuers i on upper(trim(i.ticker))=upper(trim(x->>'Kode'))
  where nullif(trim(x->>'Kode'),'') is not null
    and nullif(x->>'Date','') is not null
    and (x->>'Date')::date between p_from and p_to
  on conflict (ticker,event_date,event_type,source_ref) do update set
    title=excluded.title,
    raw_info_type=excluded.raw_info_type,
    source_url=excluded.source_url,
    source_verified=excluded.source_verified,
    provenance_state=excluded.provenance_state,
    ingested_at=excluded.ingested_at;

  get diagnostics n = row_count;
  affected := affected + n;
  return affected;
end;
$$;

revoke all on function public.flow_refresh_official_idx_risk(date,date)
  from public, anon, authenticated;
grant execute on function public.flow_refresh_official_idx_risk(date,date)
  to service_role;

create or replace function public.flow_refresh_official_idx_issued_history(
  p_from date default ((now() at time zone 'Asia/Jakarta')::date - 120),
  p_to date default ((now() at time zone 'Asia/Jakarta')::date)
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
  affected integer := 0;
begin
  if p_from is null or p_to is null or p_from > p_to then
    raise exception 'invalid issued-history date range: % to %', p_from, p_to;
  end if;

  url := 'https://block.idx.id/primary/ListingActivity/GetIssuedHistory?caType=&dateFrom=' ||
    to_char(p_from,'YYYYMMDD') || '&dateTo=' || to_char(p_to,'YYYYMMDD') ||
    '&start=0&length=5000';

  select h.status,h.content::jsonb into http_status,payload from extensions.http_get(url) h;
  if http_status <> 200 then raise exception 'IDX issued history HTTP %', http_status; end if;

  insert into public.flow_capital_action_evidence
    (ticker,event_type,event_date,event_start_date,event_end_date,publication_date,
     pre_shares,post_shares,delta_shares,delta_percent,ratio_before,ratio_after,
     raw_action,source_feed,source,source_url,source_verified,validation_state,
     provenance_state,observed_on,ingested_at)
  select
    upper(trim(x->>'KodeEmiten')),
    case lower(trim(coalesce(x->>'JenisTindakan','')))
      when 'waran' then 'WARRANT_EXERCISE'
      when 'tanpa hmetd' then 'PRIVATE_PLACEMENT'
      when 'hmetd' then 'RIGHTS_ISSUE'
      when 'obligasi wajib konversi' then 'CONVERSION'
      when 'stock split' then 'STOCK_SPLIT'
      when 'saham bonus' then 'BONUS_SHARES'
      when 'dividen saham' then 'STOCK_DIVIDEND'
      when 'pengurangan modal' then 'CAPITAL_REDUCTION'
      when 'penggabungan usaha' then 'MERGER'
      when 'delisting' then 'DELISTING'
      when 'partial delisting' then 'PARTIAL_DELISTING'
      when 'ipo' then 'IPO'
      else upper(replace(trim(coalesce(x->>'JenisTindakan','UNKNOWN')),' ','_'))
    end,
    (x->>'TanggalPencatatan')::date,
    null,
    null,
    null,
    case
      when lower(trim(coalesce(x->>'JenisTindakan',''))) in
           ('waran','tanpa hmetd','hmetd','obligasi wajib konversi')
       and coalesce(nullif(x->>'JumlahSahamSetelahTindakan','')::numeric,0) >
           coalesce(nullif(x->>'JumlahSaham','')::numeric,0)
      then coalesce(nullif(x->>'JumlahSahamSetelahTindakan','')::numeric,0) -
           coalesce(nullif(x->>'JumlahSaham','')::numeric,0)
      else null
    end,
    nullif(x->>'JumlahSahamSetelahTindakan','')::numeric,
    nullif(x->>'JumlahSaham','')::numeric,
    case
      when lower(trim(coalesce(x->>'JenisTindakan',''))) in
           ('waran','tanpa hmetd','hmetd','obligasi wajib konversi')
       and coalesce(nullif(x->>'JumlahSaham','')::numeric,0) > 0
       and coalesce(nullif(x->>'JumlahSahamSetelahTindakan','')::numeric,0) >
           coalesce(nullif(x->>'JumlahSaham','')::numeric,0)
      then 100.0 * coalesce(nullif(x->>'JumlahSaham','')::numeric,0) /
           greatest(
             coalesce(nullif(x->>'JumlahSahamSetelahTindakan','')::numeric,0) -
             coalesce(nullif(x->>'JumlahSaham','')::numeric,0),
             1
           )
      else null
    end,
    null,
    null,
    nullif(x->>'JenisTindakan',''),
    'IDX_OFFICIAL_ISSUED_HISTORY',
    'IDX_BLOCK',
    url,
    true,
    'VERIFIED',
    'VERIFIED_IDX_CAPITAL_ACTION_EVIDENCE',
    (now() at time zone 'Asia/Jakarta')::date,
    now()
  from jsonb_array_elements(coalesce(payload->'data','[]'::jsonb)) x
  join public.flow_issuers i on upper(trim(i.ticker))=upper(trim(x->>'KodeEmiten'))
  where nullif(trim(x->>'KodeEmiten'),'') is not null
    and nullif(x->>'TanggalPencatatan','') is not null
    and (x->>'TanggalPencatatan')::date between p_from and p_to
  on conflict (ticker,event_type,event_date,source_feed) do update set
    pre_shares=excluded.pre_shares,
    post_shares=excluded.post_shares,
    delta_shares=excluded.delta_shares,
    delta_percent=excluded.delta_percent,
    raw_action=excluded.raw_action,
    source=excluded.source,
    source_url=excluded.source_url,
    source_verified=excluded.source_verified,
    validation_state=excluded.validation_state,
    provenance_state=excluded.provenance_state,
    observed_on=excluded.observed_on,
    ingested_at=excluded.ingested_at;

  get diagnostics affected = row_count;
  return affected;
end;
$$;

revoke all on function public.flow_refresh_official_idx_issued_history(date,date)
  from public, anon, authenticated;
grant execute on function public.flow_refresh_official_idx_issued_history(date,date)
  to service_role;

do $$
declare r record;
begin
  for r in
    select jobid from cron.job where jobname='flow-official-idx-risk-daily'
  loop
    perform cron.unschedule(r.jobid);
  end loop;
  perform cron.schedule(
    'flow-official-idx-risk-daily',
    '55 10 * * 1-5',
    $cron$select public.flow_refresh_official_idx_risk(((now() at time zone 'Asia/Jakarta')::date - 30), (now() at time zone 'Asia/Jakarta')::date);$cron$
  );

  for r in
    select jobid from cron.job where jobname='flow-official-idx-issued-history-daily'
  loop
    perform cron.unschedule(r.jobid);
  end loop;
  perform cron.schedule(
    'flow-official-idx-issued-history-daily',
    '0 11 * * 1-5',
    $cron$select public.flow_refresh_official_idx_issued_history(((now() at time zone 'Asia/Jakarta')::date - 120), (now() at time zone 'Asia/Jakarta')::date);$cron$
  );
end $$;
