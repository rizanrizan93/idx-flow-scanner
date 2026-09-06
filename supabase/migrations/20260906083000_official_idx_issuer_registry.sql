create extension if not exists http with schema extensions;
create extension if not exists pg_cron;

create or replace function public.flow_refresh_official_idx_issuers()
returns integer
language plpgsql
security definer
set search_path = pg_catalog, public, extensions
as $$
declare
  url text := 'https://block.idx.id/primary/ListedCompany/GetCompanyProfiles?start=0&length=2000';
  payload jsonb;
  http_status integer;
  api_rows integer;
  expected_rows integer;
  affected integer := 0;
begin
  select h.status,h.content::jsonb into http_status,payload
  from extensions.http_get(url) h;

  if http_status <> 200 then
    raise exception 'IDX company profiles HTTP %',http_status;
  end if;
  if jsonb_typeof(payload->'data') is distinct from 'array' then
    raise exception 'IDX company profiles data must be an array';
  end if;

  api_rows := jsonb_array_length(payload->'data');
  expected_rows := coalesce((payload->>'recordsTotal')::integer,0);
  if api_rows < 900 or expected_rows < 900 or api_rows <> expected_rows then
    raise exception 'IDX company profiles incomplete: data %, recordsTotal %',api_rows,expected_rows;
  end if;

  update public.flow_issuers
  set active=false,updated_at=now()
  where active;

  insert into public.flow_issuers(ticker,issuer_name,sector,subsector,active,updated_at)
  select
    upper(trim(x->>'KodeEmiten')),
    nullif(trim(x->>'NamaEmiten'),''),
    nullif(trim(x->>'Sektor'),''),
    nullif(trim(x->>'SubSektor'),''),
    true,
    now()
  from jsonb_array_elements(payload->'data') x
  where coalesce((x->>'EfekEmiten_Saham')::boolean,false)
    and nullif(trim(x->>'KodeEmiten'),'') is not null
    and upper(trim(x->>'KodeEmiten')) ~ '^[A-Z0-9]{1,10}$'
  on conflict (ticker) do update set
    issuer_name=excluded.issuer_name,
    sector=excluded.sector,
    subsector=excluded.subsector,
    active=true,
    updated_at=excluded.updated_at;

  get diagnostics affected=row_count;
  if affected < 900 then
    raise exception 'IDX equity issuer refresh unexpectedly small: %',affected;
  end if;
  return affected;
end;
$$;

revoke all on function public.flow_refresh_official_idx_issuers()
  from public,anon,authenticated;
grant execute on function public.flow_refresh_official_idx_issuers()
  to service_role;

do $$
declare r record;
begin
  for r in select jobid from cron.job where jobname='flow-official-idx-issuers-daily' loop
    perform cron.unschedule(r.jobid);
  end loop;
  perform cron.schedule(
    'flow-official-idx-issuers-daily',
    '30 10 * * *',
    $cron$select public.flow_refresh_official_idx_issuers();$cron$
  );
end $$;
