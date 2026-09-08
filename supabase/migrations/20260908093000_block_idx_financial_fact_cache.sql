-- Evidence v5 financial facts: exact IDX-core taxonomy cache ingestion.
-- Official IDX instance.zip only; no production scoring changes.

alter table public.flow_financial_fact_evidence_v5
  add column if not exists taxonomy_namespace text;

create unique index if not exists flow_financial_fact_v5_filing_metric_uidx
  on public.flow_financial_fact_evidence_v5(filing_id,metric_key);

create or replace function public.flow_refresh_block_idx_financial_fact_cache_v5()
returns jsonb
language plpgsql
security invoker
set search_path=pg_catalog,public,extensions
as $$
declare
  v_cache_url constant text := 'https://raw.githubusercontent.com/rizanrizan93/idx-flow-scanner/main/data/cache/evidence_v5/block_idx_financial_facts.json';
  v_expected_catalog_hash constant text := 'fdb22a134597d5161632aedef260fdaf9342f997aa55c4d11e670043a372b930';
  v_status integer;
  v_content text;
  v_payload jsonb;
  v_row jsonb;
  v_metric_config jsonb;
  v_filing_id text;
  v_ticker text;
  v_metric_key text;
  v_concept text;
  v_namespace text;
  v_statement text;
  v_period_kind text;
  v_currency text;
  v_period_start date;
  v_period_end date;
  v_instant_date date;
  v_parent_ticker text;
  v_parent_year integer;
  v_parent_period_end date;
  v_parent_verified boolean;
  v_parent_pub_verified boolean;
  v_parent_pit boolean;
  v_upserts integer := 0;
  v_rejected integer := 0;
  v_hash_key text;
  v_hash_value text;
  v_hash_updates integer := 0;
begin
  select status, content into v_status, v_content
  from extensions.http_get(v_cache_url);

  if v_status <> 200 or v_content is null then
    return jsonb_build_object(
      'status','FINANCIAL_FACT_CACHE_UNAVAILABLE',
      'http_status',v_status,
      'production_scoring_changed',false
    );
  end if;

  begin
    v_payload := v_content::jsonb;
  exception when others then
    return jsonb_build_object(
      'status','FINANCIAL_FACT_CACHE_INVALID_JSON',
      'production_scoring_changed',false
    );
  end;

  if v_payload->>'schema_version' <> 'BLOCK_IDX_FINANCIAL_FACT_CACHE_V5_2'
     or v_payload->>'source_authority' <> 'INDONESIA_STOCK_EXCHANGE'
     or v_payload->>'parser_contract' <> 'EXACT_IDX_CORE_TAXONOMY_SINGLE_CURRENCY_CURRENT_UNDIMENSIONED_YTD_OR_INSTANT_V5_2'
     or v_payload->>'metric_catalog_sha256' <> v_expected_catalog_hash
     or coalesce((v_payload->>'production_scoring_changed')::boolean,true) is not false
     or jsonb_typeof(v_payload->'metric_catalog') <> 'object'
     or jsonb_typeof(v_payload->'rows') <> 'array'
     or jsonb_typeof(v_payload->'filing_hashes') <> 'object'
     or coalesce((v_payload->>'failed_filing_rows')::integer,-1) <> 0
     or coalesce((v_payload->>'selected_filing_rows')::integer,-1) <> coalesce((v_payload->>'parsed_filing_rows')::integer,-2) then
    return jsonb_build_object(
      'status','FINANCIAL_FACT_CACHE_CONTRACT_MISMATCH',
      'production_scoring_changed',false
    );
  end if;

  if exists (
    select 1
    from (
      select value->>'filing_id' as filing_id, value->>'metric_key' as metric_key, count(*) as n
      from jsonb_array_elements(v_payload->'rows')
      group by value->>'filing_id', value->>'metric_key'
      having count(*) > 1
    ) d
  ) then
    return jsonb_build_object(
      'status','FINANCIAL_FACT_CACHE_DUPLICATE_KEYS',
      'production_scoring_changed',false
    );
  end if;

  for v_row in select value from jsonb_array_elements(v_payload->'rows')
  loop
    begin
      v_filing_id := btrim(coalesce(v_row->>'filing_id',''));
      v_ticker := upper(btrim(coalesce(v_row->>'ticker','')));
      v_metric_key := btrim(coalesce(v_row->>'metric_key',''));
      v_concept := btrim(coalesce(v_row->>'taxonomy_concept',''));
      v_namespace := btrim(coalesce(v_row->>'taxonomy_namespace',''));
      v_statement := btrim(coalesce(v_row->>'statement_type',''));
      v_currency := upper(btrim(coalesce(v_row->>'currency','')));
      v_period_start := case when nullif(v_row->>'period_start','') is null then null else (v_row->>'period_start')::date end;
      v_period_end := case when nullif(v_row->>'period_end','') is null then null else (v_row->>'period_end')::date end;
      v_instant_date := case when nullif(v_row->>'instant_date','') is null then null else (v_row->>'instant_date')::date end;
      v_metric_config := v_payload->'metric_catalog'->v_metric_key;
      v_period_kind := coalesce(v_metric_config->>'period_kind','');

      select ticker,report_year,report_period_end,source_verified,publication_time_verified,point_in_time_eligible
        into v_parent_ticker,v_parent_year,v_parent_period_end,v_parent_verified,v_parent_pub_verified,v_parent_pit
      from public.flow_financial_filing_evidence_v5
      where filing_id=v_filing_id;

      if not found
         or v_parent_verified is not true
         or v_parent_pub_verified is not true
         or v_parent_pit is not true
         or v_ticker <> v_parent_ticker
         or v_metric_config is null
         or jsonb_typeof(v_metric_config->'concepts') <> 'array'
         or v_concept not in (select jsonb_array_elements_text(v_metric_config->'concepts'))
         or v_statement <> coalesce(v_metric_config->>'statement_type','')
         or v_period_kind not in ('instant','duration')
         or v_namespace not in (
           'http://www.idx.co.id/xbrl/taxonomy/2020-01-01/cor',
           'https://www.idx.co.id/xbrl/taxonomy/2020-01-01/cor'
         )
         or coalesce(v_row->>'fact_state','') <> 'PARSED_VALIDATED_EXACT_TAXONOMY'
         or coalesce((v_row->>'source_verified')::boolean,false) is not true
         or coalesce((v_row->>'point_in_time_eligible')::boolean,false) is not true
         or coalesce(v_row->>'provenance_state','') <> 'OFFICIAL_IDX_XBRL_INSTANCE_POINT_IN_TIME_VERIFIED_V5'
         or nullif(v_row->>'metric_value','') is null
         or v_currency !~ '^[A-Z]{3}$'
         or coalesce(v_row->>'unit','') <> 'iso4217:' || v_currency
         or coalesce(v_payload->'filing_hashes'->>v_filing_id,'') !~ '^[0-9a-f]{64}$'
         or (
           v_period_kind='instant'
           and (v_instant_date is distinct from v_parent_period_end or v_period_start is not null or v_period_end is not null)
         )
         or (
           v_period_kind='duration'
           and (
             v_instant_date is not null
             or v_period_start is distinct from make_date(v_parent_year,1,1)
             or v_period_end is distinct from v_parent_period_end
           )
         ) then
        v_rejected := v_rejected + 1;
        continue;
      end if;

      insert into public.flow_financial_fact_evidence_v5(
        fact_id,filing_id,ticker,metric_key,metric_label,taxonomy_concept,taxonomy_namespace,statement_type,
        metric_value,unit,currency,period_start,period_end,instant_date,fact_state,
        source_verified,point_in_time_eligible,provenance_state
      ) values (
        v_row->>'fact_id',v_filing_id,v_ticker,v_metric_key,nullif(v_row->>'metric_label',''),
        v_concept,v_namespace,v_statement,(v_row->>'metric_value')::numeric,v_row->>'unit',v_currency,
        v_period_start,v_period_end,v_instant_date,'PARSED_VALIDATED_EXACT_TAXONOMY',
        true,true,'OFFICIAL_IDX_XBRL_INSTANCE_POINT_IN_TIME_VERIFIED_V5'
      )
      on conflict(filing_id,metric_key) do update set
        fact_id=excluded.fact_id,
        ticker=excluded.ticker,
        metric_label=excluded.metric_label,
        taxonomy_concept=excluded.taxonomy_concept,
        taxonomy_namespace=excluded.taxonomy_namespace,
        statement_type=excluded.statement_type,
        metric_value=excluded.metric_value,
        unit=excluded.unit,
        currency=excluded.currency,
        period_start=excluded.period_start,
        period_end=excluded.period_end,
        instant_date=excluded.instant_date,
        fact_state=excluded.fact_state,
        source_verified=true,
        point_in_time_eligible=true,
        provenance_state=excluded.provenance_state,
        ingested_at=now();
      v_upserts := v_upserts + 1;
    exception when others then
      v_rejected := v_rejected + 1;
    end;
  end loop;

  if v_rejected > 0 then
    raise exception 'FINANCIAL_FACT_CACHE_ROW_REJECTED:%', v_rejected;
  end if;

  for v_hash_key,v_hash_value in select key,value from jsonb_each_text(v_payload->'filing_hashes')
  loop
    if v_hash_value ~ '^[0-9a-f]{64}$' then
      update public.flow_financial_filing_evidence_v5
      set content_hash=v_hash_value,
          extraction_state='FACTS_PARSED'
      where filing_id=v_hash_key
        and source_verified
        and publication_time_verified
        and point_in_time_eligible;
      if found then
        v_hash_updates := v_hash_updates + 1;
      end if;
    end if;
  end loop;

  return jsonb_build_object(
    'status','OK',
    'financial_fact_upserts',v_upserts,
    'rejected_rows',v_rejected,
    'filing_hash_updates',v_hash_updates,
    'metric_catalog_sha256',v_expected_catalog_hash,
    'production_scoring_changed',false
  );
end;
$$;

revoke all on function public.flow_refresh_block_idx_financial_fact_cache_v5() from public,anon,authenticated;
grant execute on function public.flow_refresh_block_idx_financial_fact_cache_v5() to service_role;

create or replace view public.flow_evidence_expansion_quality_summary_v5
with (security_invoker=true) as
select
  (select count(*) from public.flow_evidence_source_registry_v5 where source_verified) as verified_source_rows,
  (select count(*) from public.flow_financial_filing_evidence_v5) as financial_filing_rows,
  (select count(*) from public.flow_financial_filing_evidence_v5 where source_verified and publication_time_verified and point_in_time_eligible) as financial_pit_eligible_rows,
  (select count(*) from public.flow_financial_fact_evidence_v5) as financial_fact_rows,
  (select count(*) from public.flow_disclosure_evidence_v5) as disclosure_rows,
  (select count(*) from public.flow_disclosure_evidence_v5 where source_verified and publication_time_verified and point_in_time_eligible) as disclosure_pit_eligible_rows,
  (select count(*) from public.flow_major_holder_ownership_evidence_v5) as major_holder_rows,
  (select count(*) from public.flow_major_holder_ownership_evidence_v5 where source_verified and point_in_time_eligible) as major_holder_pit_eligible_rows,
  false as production_scoring_changed,
  case
    when exists(
      select 1 from public.flow_financial_fact_evidence_v5
      where source_verified and point_in_time_eligible and fact_state='PARSED_VALIDATED_EXACT_TAXONOMY'
    ) then 'EVIDENCE_V5_FINANCIAL_FACTS_READY'::text
    else 'EVIDENCE_EXPANSION_FOUNDATION_READY'::text
  end as evidence_expansion_state;

revoke all on public.flow_evidence_expansion_quality_summary_v5 from public,anon,authenticated;
grant select on public.flow_evidence_expansion_quality_summary_v5 to service_role;

comment on function public.flow_refresh_block_idx_financial_fact_cache_v5() is
'Ingest exact IDX-core taxonomy monetary facts parsed from official instance.zip filings. The catalog hash, namespace, parent PIT/source gates, unit/period contract, and duplicate keys are fail-closed; production scoring is unchanged.';
