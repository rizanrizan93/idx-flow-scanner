create extension if not exists http with schema extensions;
create extension if not exists pg_cron;

create or replace function public.flow_sync_canonical_universe_700()
returns integer
language plpgsql
security invoker
set search_path = pg_catalog, public, extensions
as $$
declare
  v_url constant text := 'https://raw.githubusercontent.com/rizanrizan93/idx-flow-scanner/refs/heads/main/data/universe/idx_700_all.json';
  v_status integer;
  v_content text;
  v_payload jsonb;
  v_count integer;
  v_upserted integer := 0;
begin
  select h.status, h.content
    into v_status, v_content
  from extensions.http_get(v_url) h;

  if v_status <> 200 then
    raise exception 'Canonical IDX 700 universe HTTP %', v_status;
  end if;

  begin
    v_payload := v_content::jsonb;
  exception when others then
    raise exception 'Canonical IDX 700 universe is not valid JSON';
  end;

  if jsonb_typeof(v_payload) <> 'array' then
    raise exception 'Canonical IDX 700 universe root must be an array';
  end if;

  v_count := jsonb_array_length(v_payload);
  if v_count <> 700 then
    raise exception 'Canonical IDX universe count mismatch: expected 700, got %', v_count;
  end if;

  with normalized as (
    select
      upper(trim(x->>'ticker')) as ticker,
      nullif(trim(x->>'sector'),'') as sector,
      coalesce((x->>'active')::boolean, true) as active
    from jsonb_array_elements(v_payload) x
    where nullif(trim(x->>'ticker'),'') is not null
  ), validated as (
    select *
    from normalized
    where ticker ~ '^[A-Z0-9]{2,8}$'
  ), deduped as (
    select distinct on (ticker) ticker, sector, active
    from validated
    order by ticker
  ), upserted as (
    insert into public.flow_issuers (ticker, sector, active, updated_at)
    select ticker, sector, active, now()
    from deduped
    on conflict (ticker) do update set
      sector = excluded.sector,
      active = excluded.active,
      updated_at = excluded.updated_at
    returning 1
  )
  select count(*)::integer into v_upserted from upserted;

  if (select count(*) from public.flow_issuers where active) < 700 then
    raise exception 'flow_issuers active universe incomplete after sync';
  end if;

  return v_upserted;
end;
$$;

revoke all on function public.flow_sync_canonical_universe_700()
  from public, anon, authenticated;
grant execute on function public.flow_sync_canonical_universe_700()
  to service_role;

do $$
declare r record;
begin
  for r in
    select jobid from cron.job where jobname='flow-canonical-universe-700-daily'
  loop
    perform cron.unschedule(r.jobid);
  end loop;

  perform cron.schedule(
    'flow-canonical-universe-700-daily',
    '35 10 * * *',
    $cron$select public.flow_sync_canonical_universe_700();$cron$
  );
end $$;

select public.flow_sync_canonical_universe_700();
