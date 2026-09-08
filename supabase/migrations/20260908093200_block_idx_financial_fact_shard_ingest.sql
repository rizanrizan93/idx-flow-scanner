-- Ingest one verified shard at a time. Every write is inside one PostgreSQL statement/transaction.

create or replace function public.flow_ingest_block_idx_financial_fact_shard_v5(
  p_manifest_sha256 text,
  p_shard_index integer
)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_expected_catalog_hash constant text := 'fdb22a134597d5161632aedef260fdaf9342f997aa55c4d11e670043a372b930';
  v_manifest public.flow_financial_fact_manifest_v5%rowtype;
  v_ledger public.flow_financial_fact_shard_ingest_v5%rowtype;
  v_status integer;
  v_content text;
  v_actual_sha text;
  v_payload jsonb;
  v_bad integer;
  v_inserted integer := 0;
  v_filing_count integer := 0;
  v_fact_count integer := 0;
  v_expected_relational text;
  v_actual_relational text;
begin
  if p_manifest_sha256 is null or p_manifest_sha256 !~ '^[0-9a-f]{64}$'
     or p_shard_index is null or p_shard_index <= 0 then
    raise exception 'FINANCIAL_FACT_SHARD_BAD_ARGUMENT';
  end if;

  select * into v_manifest
  from public.flow_financial_fact_manifest_v5
  where manifest_sha256 = p_manifest_sha256
  for update;
  if not found then
    raise exception 'FINANCIAL_FACT_MANIFEST_NOT_REGISTERED';
  end if;

  select * into v_ledger
  from public.flow_financial_fact_shard_ingest_v5
  where manifest_sha256 = p_manifest_sha256
    and shard_index = p_shard_index
  for update;
  if not found then
    raise exception 'FINANCIAL_FACT_SHARD_NOT_REGISTERED';
  end if;

  if v_manifest.metric_catalog_sha256 <> v_expected_catalog_hash then
    raise exception 'FINANCIAL_FACT_MANIFEST_CATALOG_DRIFT';
  end if;

  select status, content into v_status, v_content
  from extensions.http_get(v_ledger.shard_url::varchar);
  if v_status <> 200 or v_content is null then
    raise exception 'FINANCIAL_FACT_SHARD_UNAVAILABLE:%', coalesce(v_status,0);
  end if;

  if octet_length(convert_to(v_content,'UTF8')) <> v_ledger.expected_bytes then
    raise exception 'FINANCIAL_FACT_SHARD_BYTE_COUNT_MISMATCH';
  end if;

  v_actual_sha := encode(extensions.digest(convert_to(v_content,'UTF8'),'sha256'),'hex');
  if v_actual_sha <> v_ledger.expected_sha256 then
    raise exception 'FINANCIAL_FACT_SHARD_SHA_MISMATCH';
  end if;

  begin
    v_payload := v_content::jsonb;
  exception when others then
    raise exception 'FINANCIAL_FACT_SHARD_INVALID_JSON';
  end;

  if v_payload->>'schema_version' is distinct from 'BLOCK_IDX_FINANCIAL_FACT_SHARD_V5_2'
     or v_payload->>'source_schema_version' is distinct from 'BLOCK_IDX_FINANCIAL_FACT_CACHE_V5_2'
     or v_payload->>'source_authority' is distinct from 'INDONESIA_STOCK_EXCHANGE'
     or v_payload->>'parser_contract' is distinct from 'EXACT_IDX_CORE_TAXONOMY_SINGLE_CURRENCY_CURRENT_UNDIMENSIONED_YTD_OR_INSTANT_V5_2'
     or v_payload->>'metric_catalog_sha256' is distinct from v_expected_catalog_hash
     or coalesce((v_payload->>'production_scoring_changed')::boolean,true) is not false
     or coalesce((v_payload->>'shard_index')::integer,-1) <> p_shard_index
     or coalesce((v_payload->>'filing_rows')::integer,-1) <> v_ledger.expected_filing_rows
     or coalesce((v_payload->>'fact_rows')::integer,-1) <> v_ledger.expected_fact_rows
     or jsonb_typeof(v_payload->'filing_ids') is distinct from 'array'
     or jsonb_typeof(v_payload->'filing_hashes') is distinct from 'object'
     or jsonb_typeof(v_payload->'filing_telemetry') is distinct from 'array'
     or jsonb_typeof(v_payload->'rows') is distinct from 'array'
     or jsonb_array_length(v_payload->'filing_ids') <> v_ledger.expected_filing_rows
     or jsonb_array_length(v_payload->'filing_telemetry') <> v_ledger.expected_filing_rows
     or jsonb_array_length(v_payload->'rows') <> v_ledger.expected_fact_rows then
    raise exception 'FINANCIAL_FACT_SHARD_CONTRACT_MISMATCH';
  end if;

  select count(distinct value), count(*)
    into v_filing_count, v_bad
  from jsonb_array_elements_text(v_payload->'filing_ids');
  if v_filing_count <> v_ledger.expected_filing_rows or v_bad <> v_ledger.expected_filing_rows then
    raise exception 'FINANCIAL_FACT_SHARD_DUPLICATE_FILING_ID';
  end if;

  select count(*) into v_bad
  from jsonb_object_keys(v_payload->'filing_hashes') k
  where k not in (select value from jsonb_array_elements_text(v_payload->'filing_ids'))
     or coalesce(v_payload->'filing_hashes'->>k,'') !~ '^[0-9a-f]{64}$';
  if v_bad <> 0
     or (select count(*) from jsonb_object_keys(v_payload->'filing_hashes')) <> v_ledger.expected_filing_rows then
    raise exception 'FINANCIAL_FACT_SHARD_FILING_HASH_CONTRACT_MISMATCH';
  end if;

  select count(*) into v_bad
  from (
    select value->>'filing_id' filing_id, count(*) n
    from jsonb_array_elements(v_payload->'filing_telemetry')
    group by value->>'filing_id'
    having count(*) <> 1 or coalesce(value->>'filing_id','') = ''
  ) d;
  if v_bad <> 0
     or exists (
       select 1
       from jsonb_array_elements(v_payload->'filing_telemetry') t
       where coalesce(t.value->>'filing_id','') not in (
         select value from jsonb_array_elements_text(v_payload->'filing_ids')
       )
          or coalesce(t.value->>'content_hash','') is distinct from
             coalesce(v_payload->'filing_hashes'->>(t.value->>'filing_id'),'')
          or coalesce(t.value->>'metric_catalog_sha256','') <> v_expected_catalog_hash
          or coalesce((t.value->>'production_scoring_changed')::boolean,true) is not false
          or coalesce((t.value->>'point_in_time_identity_preserved')::boolean,false) is not true
          or coalesce((t.value->>'fact_rows')::integer,-1) <> (
             select count(*)
             from jsonb_array_elements(v_payload->'rows') r
             where r.value->>'filing_id' = t.value->>'filing_id'
          )
     ) then
    raise exception 'FINANCIAL_FACT_SHARD_TELEMETRY_CONTRACT_MISMATCH';
  end if;

  select count(*) into v_bad
  from (
    select value->>'fact_id' fact_id, count(*) n
    from jsonb_array_elements(v_payload->'rows')
    group by value->>'fact_id'
    having count(*) <> 1 or coalesce(value->>'fact_id','') = ''
  ) d;
  if v_bad <> 0 then
    raise exception 'FINANCIAL_FACT_SHARD_DUPLICATE_FACT_ID';
  end if;

  select count(*) into v_bad
  from (
    select value->>'filing_id' filing_id, value->>'metric_key' metric_key, count(*) n
    from jsonb_array_elements(v_payload->'rows')
    group by value->>'filing_id', value->>'metric_key'
    having count(*) <> 1
       or coalesce(value->>'filing_id','') = ''
       or coalesce(value->>'metric_key','') = ''
  ) d;
  if v_bad <> 0 then
    raise exception 'FINANCIAL_FACT_SHARD_DUPLICATE_FILING_METRIC';
  end if;

  with fact_rows as (
    select *
    from jsonb_to_recordset(v_payload->'rows') as r(
      fact_id text, filing_id text, ticker text, metric_key text, metric_label text,
      taxonomy_concept text, taxonomy_namespace text, statement_type text,
      metric_value numeric, unit text, currency text, period_start date,
      period_end date, instant_date date, fact_state text, source_verified boolean,
      point_in_time_eligible boolean, provenance_state text
    )
  )
  select count(*) into v_bad
  from fact_rows r
  left join public.flow_financial_filing_evidence_v5 p on p.filing_id = r.filing_id
  left join public.flow_financial_metric_catalog_v5 c on c.metric_key = r.metric_key
  where p.filing_id is null
     or p.source_verified is not true
     or p.publication_time_verified is not true
     or p.point_in_time_eligible is not true
     or lower(p.file_name) <> 'instance.zip'
     or p.report_period_end is null
     or p.report_period_end <> case p.report_period
          when 'TW1' then make_date(p.report_year,3,31)
          when 'TW2' then make_date(p.report_year,6,30)
          when 'TW3' then make_date(p.report_year,9,30)
          when 'AUDIT' then make_date(p.report_year,12,31)
          else null end
     or p.published_at::date < p.report_period_end
     or (p.content_hash is not null and p.content_hash is distinct from v_payload->'filing_hashes'->>r.filing_id)
     or upper(btrim(coalesce(r.ticker,''))) <> p.ticker
     or c.metric_key is null
     or c.catalog_sha256 <> v_expected_catalog_hash
     or r.metric_label is distinct from c.metric_label
     or coalesce(r.taxonomy_concept,'') <> all(c.concepts)
     or coalesce(r.taxonomy_namespace,'') not in (
       'http://www.idx.co.id/xbrl/taxonomy/2020-01-01/cor',
       'https://www.idx.co.id/xbrl/taxonomy/2020-01-01/cor'
     )
     or r.statement_type is distinct from c.statement_type
     or r.fact_state is distinct from 'PARSED_VALIDATED_EXACT_TAXONOMY'
     or r.source_verified is not true
     or r.point_in_time_eligible is not true
     or r.provenance_state is distinct from 'OFFICIAL_IDX_XBRL_INSTANCE_POINT_IN_TIME_VERIFIED_V5'
     or r.metric_value is null
     or r.metric_value::text in ('NaN','Infinity','-Infinity')
     or coalesce(r.currency,'') !~ '^[A-Z]{3}$'
     or r.unit is distinct from ('iso4217:' || r.currency)
     or r.filing_id not in (select value from jsonb_array_elements_text(v_payload->'filing_ids'))
     or (
       c.period_kind = 'instant'
       and (r.instant_date is distinct from p.report_period_end or r.period_start is not null or r.period_end is not null)
     )
     or (
       c.period_kind = 'duration'
       and (r.instant_date is not null or r.period_start is distinct from make_date(p.report_year,1,1) or r.period_end is distinct from p.report_period_end)
     );
  if v_bad <> 0 then
    raise exception 'FINANCIAL_FACT_SHARD_ROW_GATE_REJECTED:%', v_bad;
  end if;

  with fact_rows as (
    select *
    from jsonb_to_recordset(v_payload->'rows') as r(
      fact_id text, filing_id text, ticker text, metric_key text, metric_label text,
      taxonomy_concept text, taxonomy_namespace text, statement_type text,
      metric_value numeric, unit text, currency text, period_start date,
      period_end date, instant_date date, fact_state text, source_verified boolean,
      point_in_time_eligible boolean, provenance_state text
    )
  )
  select count(*) into v_bad
  from fact_rows r
  join public.flow_financial_fact_evidence_v5 e
    on e.filing_id = r.filing_id and e.metric_key = r.metric_key
  where e.fact_id is distinct from r.fact_id
     or e.ticker is distinct from upper(btrim(r.ticker))
     or e.metric_label is distinct from r.metric_label
     or e.taxonomy_concept is distinct from r.taxonomy_concept
     or e.taxonomy_namespace is distinct from r.taxonomy_namespace
     or e.statement_type is distinct from r.statement_type
     or e.metric_value is distinct from r.metric_value
     or e.unit is distinct from r.unit
     or e.currency is distinct from r.currency
     or e.period_start is distinct from r.period_start
     or e.period_end is distinct from r.period_end
     or e.instant_date is distinct from r.instant_date
     or e.fact_state is distinct from r.fact_state
     or e.source_verified is distinct from r.source_verified
     or e.point_in_time_eligible is distinct from r.point_in_time_eligible
     or e.provenance_state is distinct from r.provenance_state;
  if v_bad <> 0 then
    raise exception 'FINANCIAL_FACT_SHARD_EXISTING_FACT_CONFLICT:%', v_bad;
  end if;

  with fact_rows as (
    select fact_id, filing_id, metric_key
    from jsonb_to_recordset(v_payload->'rows') as r(fact_id text, filing_id text, metric_key text)
  )
  select count(*) into v_bad
  from fact_rows r
  join public.flow_financial_fact_evidence_v5 e on e.fact_id = r.fact_id
  where e.filing_id is distinct from r.filing_id or e.metric_key is distinct from r.metric_key;
  if v_bad <> 0 then
    raise exception 'FINANCIAL_FACT_SHARD_FACT_ID_COLLISION:%', v_bad;
  end if;

  if exists (
    select 1 from jsonb_array_elements_text(v_payload->'filing_ids') x
    join public.flow_financial_fact_manifest_exclusion_v5 e on e.filing_id=x.value
    where e.manifest_sha256=p_manifest_sha256
  ) then raise exception 'FINANCIAL_FACT_PARSED_EXCLUSION_OVERLAP'; end if;

  select encode(extensions.digest(convert_to(string_agg(public.flow_financial_fact_row_digest_v5(x.value), E'\n' order by x.value->>'fact_id'),'UTF8'),'sha256'),'hex')
  into v_expected_relational from jsonb_array_elements(v_payload->'rows') x;

  if v_ledger.ingest_state = 'COMPLETE' then
    select encode(extensions.digest(convert_to(string_agg(public.flow_financial_fact_row_digest_v5(to_jsonb(e)-'ingested_at'), E'\n' order by e.fact_id),'UTF8'),'sha256'),'hex'),count(*)
    into v_actual_relational,v_fact_count
    from public.flow_financial_fact_evidence_v5 e join public.flow_financial_fact_manifest_filing_v5 m on m.filing_id=e.filing_id
    where m.manifest_sha256=p_manifest_sha256 and m.shard_index=p_shard_index;
    if v_actual_relational is distinct from v_expected_relational or v_fact_count <> v_ledger.expected_fact_rows
       or (select count(*) from public.flow_financial_fact_manifest_filing_v5 where manifest_sha256=p_manifest_sha256 and shard_index=p_shard_index) <> v_ledger.expected_filing_rows then
      raise exception 'FINANCIAL_FACT_COMPLETED_SHARD_READBACK_CONFLICT';
    end if;
    return jsonb_build_object('status','ALREADY_COMPLETE','manifest_sha256',p_manifest_sha256,'shard_index',p_shard_index,
      'inserted_fact_rows',0,'fact_rows',v_fact_count,'expected_relational_sha256',v_expected_relational,
      'actual_relational_sha256',v_actual_relational,'production_scoring_changed',false);
  end if;

  insert into public.flow_financial_fact_manifest_filing_v5(
    manifest_sha256, shard_index, filing_id, content_hash
  )
  select p_manifest_sha256, p_shard_index, f.value,
         v_payload->'filing_hashes'->>f.value
  from jsonb_array_elements_text(v_payload->'filing_ids') f(value)
  on conflict (manifest_sha256, filing_id) do nothing;

  select count(*) into v_bad
  from public.flow_financial_fact_manifest_filing_v5 m
  where m.manifest_sha256 = p_manifest_sha256
    and m.filing_id in (select value from jsonb_array_elements_text(v_payload->'filing_ids'))
    and (m.shard_index <> p_shard_index or m.content_hash is distinct from v_payload->'filing_hashes'->>m.filing_id);
  if v_bad <> 0 then
    raise exception 'FINANCIAL_FACT_SHARD_MANIFEST_FILING_CONFLICT:%', v_bad;
  end if;

  with fact_rows as (
    select *
    from jsonb_to_recordset(v_payload->'rows') as r(
      fact_id text, filing_id text, ticker text, metric_key text, metric_label text,
      taxonomy_concept text, taxonomy_namespace text, statement_type text,
      metric_value numeric, unit text, currency text, period_start date,
      period_end date, instant_date date, fact_state text, source_verified boolean,
      point_in_time_eligible boolean, provenance_state text
    )
  ), ins as (
    insert into public.flow_financial_fact_evidence_v5(
      fact_id, filing_id, ticker, metric_key, metric_label, taxonomy_concept,
      taxonomy_namespace, statement_type, metric_value, unit, currency,
      period_start, period_end, instant_date, fact_state,
      source_verified, point_in_time_eligible, provenance_state
    )
    select r.fact_id, r.filing_id, upper(btrim(r.ticker)), r.metric_key, r.metric_label,
      r.taxonomy_concept, r.taxonomy_namespace, r.statement_type, r.metric_value,
      r.unit, r.currency, r.period_start, r.period_end, r.instant_date,
      'PARSED_VALIDATED_EXACT_TAXONOMY', true, true,
      'OFFICIAL_IDX_XBRL_INSTANCE_POINT_IN_TIME_VERIFIED_V5'
    from fact_rows r
    on conflict (filing_id, metric_key) do nothing
    returning 1
  )
  select count(*) into v_inserted from ins;

  update public.flow_financial_filing_evidence_v5 p
  set content_hash = m.content_hash,
      extraction_state = 'FACTS_PARSED'
  from public.flow_financial_fact_manifest_filing_v5 m
  where m.manifest_sha256 = p_manifest_sha256
    and m.shard_index = p_shard_index
    and p.filing_id = m.filing_id
    and p.source_verified
    and p.publication_time_verified
    and p.point_in_time_eligible;

  select count(*) into v_filing_count
  from public.flow_financial_fact_manifest_filing_v5
  where manifest_sha256 = p_manifest_sha256 and shard_index = p_shard_index;

  select count(*) into v_fact_count
  from public.flow_financial_fact_evidence_v5 e
  join public.flow_financial_fact_manifest_filing_v5 m
    on m.filing_id = e.filing_id
   and m.manifest_sha256 = p_manifest_sha256
   and m.shard_index = p_shard_index;

  if v_filing_count <> v_ledger.expected_filing_rows
     or v_fact_count <> v_ledger.expected_fact_rows then
    raise exception 'FINANCIAL_FACT_SHARD_POSTWRITE_COUNT_MISMATCH:filings=% facts=%', v_filing_count, v_fact_count;
  end if;

  select encode(extensions.digest(convert_to(string_agg(public.flow_financial_fact_row_digest_v5(to_jsonb(e)-'ingested_at'), E'\n' order by e.fact_id),'UTF8'),'sha256'),'hex')
  into v_actual_relational from public.flow_financial_fact_evidence_v5 e
  join public.flow_financial_fact_manifest_filing_v5 m on m.filing_id=e.filing_id
  where m.manifest_sha256=p_manifest_sha256 and m.shard_index=p_shard_index;
  if v_actual_relational is distinct from v_expected_relational then
    raise exception 'FINANCIAL_FACT_SHARD_POSTWRITE_HASH_MISMATCH';
  end if;

  update public.flow_financial_fact_shard_ingest_v5
  set ingest_state = 'COMPLETE',
      expected_relational_sha256 = v_expected_relational,
      actual_relational_sha256 = v_actual_relational,
      inserted_fact_rows = v_inserted,
      verified_at = now(),
      ingested_at = now()
  where manifest_sha256 = p_manifest_sha256 and shard_index = p_shard_index;

  if not exists (
    select 1 from public.flow_financial_fact_shard_ingest_v5
    where manifest_sha256 = p_manifest_sha256 and ingest_state <> 'COMPLETE'
  ) then
    update public.flow_financial_fact_manifest_v5
    set ingest_state = 'COMPLETE',
      expected_relational_sha256 = v_expected_relational,
      actual_relational_sha256 = v_actual_relational, completed_at = now()
    where manifest_sha256 = p_manifest_sha256;
  end if;

  return jsonb_build_object(
    'status','COMPLETE',
    'manifest_sha256',p_manifest_sha256,
    'shard_index',p_shard_index,
    'filing_rows',v_filing_count,
    'fact_rows',v_fact_count,
    'inserted_fact_rows',v_inserted,
    'expected_relational_sha256',v_expected_relational,
    'actual_relational_sha256',v_actual_relational,
    'production_scoring_changed',false
  );
end;
$$;

revoke all on function public.flow_ingest_block_idx_financial_fact_shard_v5(text,integer)
  from public, anon, authenticated;
grant execute on function public.flow_ingest_block_idx_financial_fact_shard_v5(text,integer)
  to service_role;

comment on function public.flow_ingest_block_idx_financial_fact_shard_v5(text,integer) is
'Downloads one immutable manifest-declared shard, verifies byte/SHA identity and telemetry, exact taxonomy/catalog, unit/currency, parent PIT/period/source/hash and provenance contracts, then performs idempotent canonical ingestion. Production scoring is unchanged.';
