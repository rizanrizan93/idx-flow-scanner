alter table public.flow_official_broker_activity enable row level security;
alter table public.flow_official_index_summary enable row level security;
alter table public.flow_official_risk_events enable row level security;
alter table public.flow_official_shareholder_profiles enable row level security;

revoke all on table public.flow_official_broker_activity from public,anon,authenticated;
revoke all on table public.flow_official_index_summary from public,anon,authenticated;
revoke all on table public.flow_official_risk_events from public,anon,authenticated;
revoke all on table public.flow_official_shareholder_profiles from public,anon,authenticated;

grant select,insert,update,delete on table public.flow_official_broker_activity to service_role;
grant select,insert,update,delete on table public.flow_official_index_summary to service_role;
grant select,insert,update,delete on table public.flow_official_risk_events to service_role;
grant select,insert,update,delete on table public.flow_official_shareholder_profiles to service_role;

create or replace function public.flow_refresh_official_idx_shareholder_profiles(
  p_offset integer default 0,
  p_limit integer default 100,
  p_observed_on date default ((now() at time zone 'Asia/Jakarta')::date)
)
returns integer
language plpgsql
security definer
set search_path = pg_catalog, public, extensions
as $$
declare
  r record;
  url text;
  payload jsonb;
  http_status integer;
  affected integer := 0;
  n integer := 0;
begin
  if p_offset < 0 or p_limit < 1 or p_limit > 200 then
    raise exception 'invalid shareholder refresh window offset %, limit %', p_offset,p_limit;
  end if;
  if p_observed_on is null then
    raise exception 'observed_on is required';
  end if;

  for r in
    select upper(trim(ticker)) as ticker
    from public.flow_issuers
    where active
      and nullif(trim(ticker),'') is not null
    order by ticker
    offset p_offset limit p_limit
  loop
    url := 'https://block.idx.id/primary/ListedCompany/GetCompanyProfilesDetail?KodeEmiten=' || r.ticker;
    begin
      select h.status,h.content::jsonb into http_status,payload
      from extensions.http_get(url) h;
    exception when others then
      continue;
    end;

    if http_status <> 200 then
      continue;
    end if;
    if upper(trim(coalesce(payload#>>'{Search,KodeEmiten}',''))) <> r.ticker then
      continue;
    end if;

    insert into public.flow_official_shareholder_profiles
      (ticker,observed_on,holder_identity_hash,holder_name,shares_held,ownership_percentage,
       holder_category,is_controller,source,source_url,source_verified,provenance_state,ingested_at)
    with raw_holders as (
      select
        md5(lower(trim(x->>'Nama')) || '|' || lower(trim(coalesce(x->>'Kategori',''))) || '|' ||
            lower(trim(coalesce(x->>'Pengendali','false')))) as holder_identity_hash,
        trim(x->>'Nama') as holder_name,
        nullif(x->>'Jumlah','')::numeric as shares_held,
        nullif(x->>'Persentase','')::numeric as ownership_percentage,
        nullif(trim(x->>'Kategori'),'') as holder_category,
        lower(trim(coalesce(x->>'Pengendali','false'))) in ('true','1','yes') as is_controller
      from jsonb_array_elements(coalesce(payload->'PemegangSaham','[]'::jsonb)) x
      where nullif(trim(x->>'Nama'),'') is not null
        and (nullif(x->>'Jumlah','') is null or nullif(x->>'Jumlah','')::numeric >= 0)
        and (nullif(x->>'Persentase','') is null or nullif(x->>'Persentase','')::numeric between 0 and 100)
    ), holders as (
      select distinct on (holder_identity_hash)
        holder_identity_hash,holder_name,shares_held,ownership_percentage,holder_category,is_controller
      from raw_holders
      order by holder_identity_hash,shares_held desc nulls last,ownership_percentage desc nulls last
    )
    select
      r.ticker,p_observed_on,h.holder_identity_hash,h.holder_name,h.shares_held,
      h.ownership_percentage,h.holder_category,h.is_controller,
      'IDX_OFFICIAL_COMPANY_PROFILE_SHAREHOLDER',url,true,
      'VERIFIED_OFFICIAL_IDX_COMPANY_PROFILE_OBSERVED_SNAPSHOT',now()
    from holders h
    on conflict (ticker,observed_on,holder_identity_hash) do update set
      holder_name=excluded.holder_name,
      shares_held=excluded.shares_held,
      ownership_percentage=excluded.ownership_percentage,
      holder_category=excluded.holder_category,
      is_controller=excluded.is_controller,
      source_url=excluded.source_url,
      source_verified=excluded.source_verified,
      provenance_state=excluded.provenance_state,
      ingested_at=excluded.ingested_at;

    get diagnostics n = row_count;
    affected := affected + n;
  end loop;
  return affected;
end;
$$;

revoke all on function public.flow_refresh_official_idx_shareholder_profiles(integer,integer,date)
  from public,anon,authenticated;
grant execute on function public.flow_refresh_official_idx_shareholder_profiles(integer,integer,date)
  to service_role;

do $$
declare r record;
begin
  for r in
    select jobid from cron.job where jobname='flow-official-idx-shareholder-daily-chunk'
  loop
    perform cron.unschedule(r.jobid);
  end loop;

  perform cron.schedule(
    'flow-official-idx-shareholder-daily-chunk',
    '15 11 * * *',
    $cron$select public.flow_refresh_official_idx_shareholder_profiles(
      ((((extract(doy from (now() at time zone 'Asia/Jakarta'))::int)-1) % 10) * 100),
      100,
      (now() at time zone 'Asia/Jakarta')::date
    );$cron$
  );
end $$;
