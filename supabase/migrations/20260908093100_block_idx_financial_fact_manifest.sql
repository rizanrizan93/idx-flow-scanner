-- Register a content-addressed full-corpus manifest before any canonical fact rows may be written.

create or replace function public.flow_register_block_idx_financial_fact_manifest_v5(
  p_manifest_url text,
  p_expected_sha256 text
)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_expected_catalog_hash constant text := 'fdb22a134597d5161632aedef260fdaf9342f997aa55c4d11e670043a372b930';
  v_status integer;
  v_content text;
  v_actual_sha text;
  v_payload jsonb;
  v_meta_url text;
  v_meta_content text;
  v_meta jsonb;
  v_commit_sha text;
  v_run_id bigint;
  v_source_head_sha text;
  v_shard jsonb;
  v_shard_count integer;
  v_total_filings bigint;
  v_total_facts bigint;
  v_catalog jsonb;
  v_existing public.flow_financial_fact_manifest_v5%rowtype;
begin
  if p_expected_sha256 is null or p_expected_sha256 !~ '^[0-9a-f]{64}$' then
    raise exception 'FINANCIAL_FACT_MANIFEST_BAD_EXPECTED_SHA';
  end if;

  if p_manifest_url !~ '^https://raw\.githubusercontent\.com/rizanrizan93/idx-flow-scanner/[0-9a-f]{40}/evidence_artifacts/financial_facts_v5/run-[0-9]+/manifest\.json$' then
    raise exception 'FINANCIAL_FACT_MANIFEST_URL_NOT_IMMUTABLE_ARTIFACT';
  end if;

  v_commit_sha := substring(
    p_manifest_url from '^https://raw\.githubusercontent\.com/rizanrizan93/idx-flow-scanner/([0-9a-f]{40})/'
  );
  v_run_id := substring(p_manifest_url from '/run-([0-9]+)/manifest\.json$')::bigint;
  v_meta_url := regexp_replace(p_manifest_url, '/manifest\.json$', '/artifact_meta.json');

  select status, content into v_status, v_content
  from extensions.http_get(p_manifest_url::varchar);

  if v_status <> 200 or v_content is null then
    raise exception 'FINANCIAL_FACT_MANIFEST_UNAVAILABLE:%', coalesce(v_status, 0);
  end if;

  v_actual_sha := encode(extensions.digest(convert_to(v_content, 'UTF8'), 'sha256'), 'hex');
  if v_actual_sha <> p_expected_sha256 then
    raise exception 'FINANCIAL_FACT_MANIFEST_SHA_MISMATCH';
  end if;

  begin
    v_payload := v_content::jsonb;
  exception when others then
    raise exception 'FINANCIAL_FACT_MANIFEST_INVALID_JSON';
  end;

  select status, content into v_status, v_meta_content
  from extensions.http_get(v_meta_url::varchar);

  if v_status <> 200 or v_meta_content is null then
    raise exception 'FINANCIAL_FACT_ARTIFACT_META_UNAVAILABLE:%', coalesce(v_status, 0);
  end if;

  begin
    v_meta := v_meta_content::jsonb;
  exception when others then
    raise exception 'FINANCIAL_FACT_ARTIFACT_META_INVALID_JSON';
  end;

  v_source_head_sha := coalesce(v_meta->>'source_head_sha','');
  if v_meta->>'schema_version' <> 'BLOCK_IDX_FINANCIAL_FACT_ARTIFACT_META_V5_2'
     or coalesce((v_meta->>'source_run_id')::bigint,-1) <> v_run_id
     or v_source_head_sha !~ '^[0-9a-f]{40}$'
     or v_meta->>'manifest_sha256' <> v_actual_sha
     or coalesce((v_meta->>'production_scoring_changed')::boolean,true) is not false then
    raise exception 'FINANCIAL_FACT_ARTIFACT_META_CONTRACT_MISMATCH';
  end if;

  select jsonb_object_agg(
           c.metric_key,
           jsonb_build_object(
             'label', c.metric_label,
             'statement_type', c.statement_type,
             'period_kind', c.period_kind,
             'concepts', to_jsonb(c.concepts)
           ) order by c.metric_key
         )
    into v_catalog
  from public.flow_financial_metric_catalog_v5 c
  where c.catalog_sha256 = v_expected_catalog_hash;

  if (select count(*) from public.flow_financial_metric_catalog_v5 where catalog_sha256 = v_expected_catalog_hash) <> 19
     or v_payload->>'schema_version' <> 'BLOCK_IDX_FINANCIAL_FACT_MANIFEST_V5_2'
     or v_payload->>'source_schema_version' <> 'BLOCK_IDX_FINANCIAL_FACT_CACHE_V5_2'
     or v_payload->>'source_authority' <> 'INDONESIA_STOCK_EXCHANGE'
     or v_payload->>'parser_contract' <> 'EXACT_IDX_CORE_TAXONOMY_SINGLE_CURRENCY_CURRENT_UNDIMENSIONED_YTD_OR_INSTANT_V5_2'
     or v_payload->>'metric_catalog_sha256' <> v_expected_catalog_hash
     or v_payload->'metric_catalog' is distinct from v_catalog
     or coalesce((v_payload->>'production_scoring_changed')::boolean,true) is not false
     or coalesce((v_payload->>'failed_filing_rows')::integer,-1) <> 0
     or coalesce((v_payload->>'selected_filing_rows')::integer,-1) <> coalesce((v_payload->>'parsed_filing_rows')::integer,-2)
     or coalesce((v_payload->>'parsed_filing_rows')::integer,-1) <= 0
     or coalesce((v_payload->>'fact_rows')::integer,-1) < 0
     or coalesce((v_payload->>'shard_count')::integer,-1) <= 0
     or jsonb_typeof(v_payload->'shards') <> 'array'
     or jsonb_array_length(v_payload->'shards') <> (v_payload->>'shard_count')::integer then
    raise exception 'FINANCIAL_FACT_MANIFEST_CONTRACT_MISMATCH';
  end if;

  select count(*),
         coalesce(sum((x.value->>'filing_rows')::bigint),0),
         coalesce(sum((x.value->>'fact_rows')::bigint),0)
    into v_shard_count, v_total_filings, v_total_facts
  from jsonb_array_elements(v_payload->'shards') with ordinality x(value, ord)
  where (x.value->>'shard_index')::bigint = x.ord
    and x.value->>'file_name' ~ '^shard-[0-9]{4}\.json$'
    and substring(x.value->>'file_name' from 'shard-([0-9]{4})\.json')::integer = (x.value->>'shard_index')::integer
    and x.value->>'sha256' ~ '^[0-9a-f]{64}$'
    and (x.value->>'bytes')::bigint > 0
    and (x.value->>'filing_rows')::integer > 0
    and (x.value->>'fact_rows')::integer >= 0;

  if v_shard_count <> (v_payload->>'shard_count')::integer
     or v_total_filings <> (v_payload->>'parsed_filing_rows')::bigint
     or v_total_facts <> (v_payload->>'fact_rows')::bigint then
    raise exception 'FINANCIAL_FACT_MANIFEST_SHARD_TOTAL_MISMATCH';
  end if;

  insert into public.flow_financial_fact_manifest_v5(
    manifest_sha256, manifest_url, artifact_commit_sha, source_run_id, source_head_sha,
    metric_catalog_sha256, selected_filing_rows, parsed_filing_rows, fact_rows,
    shard_count, exact_locator_resolution_rows, manifest_payload, ingest_state
  ) values (
    v_actual_sha, p_manifest_url, v_commit_sha, v_run_id, v_source_head_sha,
    v_expected_catalog_hash,
    (v_payload->>'selected_filing_rows')::integer,
    (v_payload->>'parsed_filing_rows')::integer,
    (v_payload->>'fact_rows')::integer,
    (v_payload->>'shard_count')::integer,
    coalesce((v_payload->>'exact_locator_resolution_rows')::integer,0),
    v_payload, 'REGISTERED'
  )
  on conflict (manifest_sha256) do nothing;

  if not found then
    select * into v_existing
    from public.flow_financial_fact_manifest_v5
    where manifest_sha256 = v_actual_sha;
    if v_existing.manifest_url is distinct from p_manifest_url
       or v_existing.artifact_commit_sha is distinct from v_commit_sha
       or v_existing.source_run_id is distinct from v_run_id
       or v_existing.source_head_sha is distinct from v_source_head_sha
       or v_existing.manifest_payload is distinct from v_payload then
      raise exception 'FINANCIAL_FACT_MANIFEST_PROVENANCE_CONFLICT';
    end if;
  end if;

  for v_shard in select value from jsonb_array_elements(v_payload->'shards')
  loop
    insert into public.flow_financial_fact_shard_ingest_v5(
      manifest_sha256, shard_index, file_name, shard_url,
      expected_sha256, expected_bytes, expected_filing_rows, expected_fact_rows
    ) values (
      v_actual_sha,
      (v_shard->>'shard_index')::integer,
      v_shard->>'file_name',
      regexp_replace(p_manifest_url, '/manifest\.json$', '/' || (v_shard->>'file_name')),
      v_shard->>'sha256',
      (v_shard->>'bytes')::bigint,
      (v_shard->>'filing_rows')::integer,
      (v_shard->>'fact_rows')::integer
    )
    on conflict (manifest_sha256, shard_index) do nothing;

    if not found and exists (
      select 1
      from public.flow_financial_fact_shard_ingest_v5 s
      where s.manifest_sha256 = v_actual_sha
        and s.shard_index = (v_shard->>'shard_index')::integer
        and (
          s.file_name is distinct from v_shard->>'file_name'
          or s.shard_url is distinct from regexp_replace(p_manifest_url, '/manifest\.json$', '/' || (v_shard->>'file_name'))
          or s.expected_sha256 is distinct from v_shard->>'sha256'
          or s.expected_bytes is distinct from (v_shard->>'bytes')::bigint
          or s.expected_filing_rows is distinct from (v_shard->>'filing_rows')::integer
          or s.expected_fact_rows is distinct from (v_shard->>'fact_rows')::integer
        )
    ) then
      raise exception 'FINANCIAL_FACT_SHARD_REGISTRY_CONFLICT:%', v_shard->>'shard_index';
    end if;
  end loop;

  return jsonb_build_object(
    'status','REGISTERED',
    'manifest_sha256',v_actual_sha,
    'artifact_commit_sha',v_commit_sha,
    'source_run_id',v_run_id,
    'source_head_sha',v_source_head_sha,
    'parsed_filing_rows',(v_payload->>'parsed_filing_rows')::integer,
    'fact_rows',(v_payload->>'fact_rows')::integer,
    'shard_count',(v_payload->>'shard_count')::integer,
    'production_scoring_changed',false
  );
end;
$$;

revoke all on function public.flow_register_block_idx_financial_fact_manifest_v5(text,text)
  from public, anon, authenticated;
grant execute on function public.flow_register_block_idx_financial_fact_manifest_v5(text,text)
  to service_role;

comment on function public.flow_register_block_idx_financial_fact_manifest_v5(text,text) is
'Registers only a content-addressed immutable GitHub artifact manifest from a successful full-corpus IDX XBRL proof. Catalog, counts, hashes, parser contract, source run/head provenance, and production-scoring isolation fail closed.';
