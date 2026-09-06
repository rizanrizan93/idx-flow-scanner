create extension if not exists http with schema extensions;

create or replace function public.flow_sync_ksei_ownership_history_2026()
returns jsonb
language plpgsql
security invoker
set search_path = pg_catalog, public, extensions
as $$
declare
  v_url constant text := 'https://raw.githubusercontent.com/rizanrizan93/idx-flow-scanner/refs/heads/main/data/cache/ksei_ownership_history_2026.json';
  v_status integer;
  v_content text;
  v_payload jsonb;
  v_source_rows integer;
  v_source_tickers integer;
  v_source_dates integer;
  v_written integer := 0;
  v_db_rows integer;
  v_db_tickers integer;
  v_db_dates integer;
begin
  select h.status, h.content
    into v_status, v_content
  from extensions.http_get(v_url) h;

  if v_status <> 200 then
    raise exception 'Canonical KSEI cache HTTP %', v_status;
  end if;

  begin
    v_payload := v_content::jsonb;
  exception when others then
    raise exception 'Canonical KSEI cache is not valid JSON';
  end;

  if jsonb_typeof(v_payload) <> 'array' then
    raise exception 'Canonical KSEI cache root must be an array';
  end if;

  v_source_rows := jsonb_array_length(v_payload);
  if v_source_rows <> 22244 then
    raise exception 'Canonical KSEI row-count mismatch: expected 22244, got %', v_source_rows;
  end if;

  with normalized as (
    select
      upper(trim(x->>'ticker')) as ticker,
      lower(trim(x->>'category')) as category,
      lower(trim(x->>'holder_identity_hash')) as holder_identity_hash,
      nullif(trim(x->>'holder_name'),'') as holder_name,
      nullif(x->>'shares_held','')::numeric as shares_held,
      nullif(x->>'ownership_percentage','')::numeric as ownership_percentage,
      nullif(trim(x->>'holder_classification'),'') as holder_classification,
      nullif(trim(x->>'holder_type'),'') as holder_type,
      nullif(trim(x->>'local_foreign_state'),'') as local_foreign_state,
      (x->>'report_date')::date as report_date,
      nullif(trim(x->>'report_date_kind'),'') as report_date_kind,
      nullif(x->>'publication_date','')::date as publication_date,
      nullif(trim(x->>'source_url'),'') as source_url,
      lower(nullif(trim(x->>'source_file_hash'),'')) as source_file_hash,
      coalesce((x->>'source_verified')::boolean, false) as source_verified,
      trim(x->>'provenance_state') as provenance_state
    from jsonb_array_elements(v_payload) x
  ), verified as (
    select n.*
    from normalized n
    join public.flow_issuers i on i.ticker = n.ticker and i.active
    where n.ticker ~ '^[A-Z0-9]{2,8}$'
      and n.category = 'ksei-komposisi'
      and n.holder_identity_hash ~ '^[0-9a-f]{64}$'
      and n.report_date between date '2026-01-01' and date '2026-08-31'
      and n.source_verified
      and n.provenance_state = 'VERIFIED_KSEI_REGISTRATION_COMPOSITION'
      and n.source_url like 'https://web.ksei.co.id/%'
      and n.source_file_hash ~ '^[0-9a-f]{64}$'
      and (n.shares_held is null or n.shares_held >= 0)
      and (n.ownership_percentage is null or n.ownership_percentage between 0 and 100)
  )
  select count(*)::integer, count(distinct ticker)::integer, count(distinct report_date)::integer
    into v_source_rows, v_source_tickers, v_source_dates
  from verified;

  if v_source_rows <> 22244 or v_source_tickers <> 700 or v_source_dates <> 8 then
    raise exception 'Canonical KSEI validation failed: rows %, tickers %, dates %',
      v_source_rows, v_source_tickers, v_source_dates;
  end if;

  with normalized as (
    select
      upper(trim(x->>'ticker')) as ticker,
      lower(trim(x->>'category')) as category,
      lower(trim(x->>'holder_identity_hash')) as holder_identity_hash,
      nullif(trim(x->>'holder_name'),'') as holder_name,
      nullif(x->>'shares_held','')::numeric as shares_held,
      nullif(x->>'ownership_percentage','')::numeric as ownership_percentage,
      nullif(trim(x->>'holder_classification'),'') as holder_classification,
      nullif(trim(x->>'holder_type'),'') as holder_type,
      nullif(trim(x->>'local_foreign_state'),'') as local_foreign_state,
      (x->>'report_date')::date as report_date,
      nullif(trim(x->>'report_date_kind'),'') as report_date_kind,
      nullif(x->>'publication_date','')::date as publication_date,
      nullif(trim(x->>'source_url'),'') as source_url,
      lower(nullif(trim(x->>'source_file_hash'),'')) as source_file_hash,
      coalesce((x->>'source_verified')::boolean, false) as source_verified,
      trim(x->>'provenance_state') as provenance_state
    from jsonb_array_elements(v_payload) x
  ), verified as (
    select n.*
    from normalized n
    join public.flow_issuers i on i.ticker = n.ticker and i.active
    where n.ticker ~ '^[A-Z0-9]{2,8}$'
      and n.category = 'ksei-komposisi'
      and n.holder_identity_hash ~ '^[0-9a-f]{64}$'
      and n.report_date between date '2026-01-01' and date '2026-08-31'
      and n.source_verified
      and n.provenance_state = 'VERIFIED_KSEI_REGISTRATION_COMPOSITION'
      and n.source_url like 'https://web.ksei.co.id/%'
      and n.source_file_hash ~ '^[0-9a-f]{64}$'
      and (n.shares_held is null or n.shares_held >= 0)
      and (n.ownership_percentage is null or n.ownership_percentage between 0 and 100)
  ), upserted as (
    insert into public.flow_ownership_evidence (
      ticker, category, holder_identity_hash, holder_name, shares_held,
      ownership_percentage, holder_classification, holder_type,
      local_foreign_state, report_date, report_date_kind, publication_date,
      source_url, source_file_hash, source_verified, provenance_state, ingested_at
    )
    select
      ticker, category, holder_identity_hash, holder_name, shares_held,
      ownership_percentage, holder_classification, holder_type,
      local_foreign_state, report_date, report_date_kind, publication_date,
      source_url, source_file_hash, true, provenance_state, now()
    from verified
    on conflict (ticker, report_date, category, holder_identity_hash) do update set
      holder_name = excluded.holder_name,
      shares_held = excluded.shares_held,
      ownership_percentage = excluded.ownership_percentage,
      holder_classification = excluded.holder_classification,
      holder_type = excluded.holder_type,
      local_foreign_state = excluded.local_foreign_state,
      report_date_kind = excluded.report_date_kind,
      publication_date = excluded.publication_date,
      source_url = excluded.source_url,
      source_file_hash = excluded.source_file_hash,
      source_verified = excluded.source_verified,
      provenance_state = excluded.provenance_state,
      ingested_at = excluded.ingested_at
    returning 1
  )
  select count(*)::integer into v_written from upserted;

  select count(*)::integer, count(distinct ticker)::integer, count(distinct report_date)::integer
    into v_db_rows, v_db_tickers, v_db_dates
  from public.flow_ownership_evidence
  where provenance_state = 'VERIFIED_KSEI_REGISTRATION_COMPOSITION'
    and report_date between date '2026-01-01' and date '2026-08-31';

  if v_db_rows <> 22244 or v_db_tickers <> 700 or v_db_dates <> 8 then
    raise exception 'Canonical KSEI database parity failed: rows %, tickers %, dates %',
      v_db_rows, v_db_tickers, v_db_dates;
  end if;

  return jsonb_build_object(
    'status','SUCCESS',
    'written',v_written,
    'rows',v_db_rows,
    'tickers',v_db_tickers,
    'report_dates',v_db_dates,
    'provenance_state','VERIFIED_KSEI_REGISTRATION_COMPOSITION'
  );
end;
$$;

revoke all on function public.flow_sync_ksei_ownership_history_2026()
  from public, anon, authenticated;
grant execute on function public.flow_sync_ksei_ownership_history_2026()
  to service_role;
