-- Evidence Expansion v5: ingest revision-complete Block IDX historical financial filing cache.
-- Cache rows are produced only from official per-company announcement history with verified
-- publication timestamps. The financial-report endpoint is corroboration, not the PIT clock.
-- No production scoring, Phase4D shadow, or Phase4E weight logic is changed.

create or replace function public.flow_refresh_block_idx_historical_financial_cache_v5()
returns jsonb
language plpgsql
security invoker
set search_path=pg_catalog,public,extensions
as $$
declare
  v_cache_url constant text := 'https://raw.githubusercontent.com/rizanrizan93/idx-flow-scanner/main/data/cache/evidence_v5/block_idx_historical_financial_filings.json';
  v_status integer;
  v_content text;
  v_payload jsonb;
  v_row jsonb;
  v_pub timestamptz;
  v_file_modified timestamptz;
  v_period_end date;
  v_report_year integer;
  v_upserts integer := 0;
  v_rejected integer := 0;
begin
  select status, content into v_status, v_content
  from extensions.http_get(v_cache_url);

  if v_status <> 200 or v_content is null then
    return jsonb_build_object(
      'status','HISTORICAL_FINANCIAL_CACHE_UNAVAILABLE',
      'http_status',v_status,
      'production_scoring_changed',false
    );
  end if;

  begin
    v_payload := v_content::jsonb;
  exception when others then
    return jsonb_build_object(
      'status','HISTORICAL_FINANCIAL_CACHE_INVALID_JSON',
      'production_scoring_changed',false
    );
  end;

  if v_payload->>'schema_version' <> 'BLOCK_IDX_HISTORICAL_FINANCIAL_FILING_CACHE_V5_2'
     or v_payload->>'source_authority' <> 'INDONESIA_STOCK_EXCHANGE'
     or v_payload->>'matching_contract' <> 'PROFILE_ANNOUNCEMENT_PIT_ATTACHMENT_IDENTITY_WITH_LATEST_REPORT_CORROBORATION'
     or v_payload->>'revision_semantics' <> 'EVERY_FINANCIAL_ANNOUNCEMENT_REVISION_RETAINED_WHEN_PERIOD_IS_VERIFIABLE'
     or jsonb_typeof(v_payload->'rows') <> 'array' then
    return jsonb_build_object(
      'status','HISTORICAL_FINANCIAL_CACHE_CONTRACT_MISMATCH',
      'production_scoring_changed',false
    );
  end if;

  for v_row in select value from jsonb_array_elements(v_payload->'rows')
  loop
    begin
      v_pub := (v_row->>'published_at')::timestamptz;
      v_period_end := (v_row->>'report_period_end')::date;
      v_report_year := (v_row->>'report_year')::integer;
      v_file_modified := case
        when nullif(v_row->>'file_modified_at','') is null then null
        else (v_row->>'file_modified_at')::timestamptz
      end;

      if coalesce(v_row->>'filing_id','') = ''
         or coalesce(v_row->>'ticker','') = ''
         or upper(btrim(v_row->>'ticker')) !~ '^[A-Z0-9]{4,12}$'
         or v_report_year < 1990
         or v_report_year > extract(year from now())::integer + 1
         or extract(year from v_period_end)::integer <> v_report_year
         or upper(coalesce(v_row->>'report_period','')) not in ('TW1','TW2','TW3','AUDIT')
         or lower(coalesce(v_row->>'file_type','')) not in ('.xlsx','.xls','.zip','.xml','.xhtml')
         or v_row->>'source_key' <> 'IDX_XBRL_FINANCIAL_REPORT'
         or v_row->>'report_type' <> 'BLOCK_IDX_PROFILE_ANNOUNCEMENT_ATTACHMENT'
         or v_row->>'provenance_state' <> 'OFFICIAL_BLOCK_IDX_PROFILE_ANNOUNCEMENT_POINT_IN_TIME'
         or not public.flow_idx_official_url_v5(v_row->>'file_url')
         or coalesce((v_row->>'publication_time_verified')::boolean,false) is not true
         or coalesce((v_row->>'source_verified')::boolean,false) is not true
         or coalesce((v_row->>'point_in_time_eligible')::boolean,false) is not true
         or v_pub > now() + interval '10 minutes'
         or v_pub::date < v_period_end
         or (v_file_modified is not null and v_file_modified > now() + interval '10 minutes') then
        v_rejected := v_rejected + 1;
        continue;
      end if;

      insert into public.flow_financial_filing_evidence_v5(
        filing_id,ticker,report_year,report_period,report_period_end,published_at,
        file_modified_at,file_url,file_name,file_type,report_type,source_key,content_hash,
        publication_time_verified,source_verified,point_in_time_eligible,extraction_state,
        provenance_state
      ) values (
        v_row->>'filing_id',upper(btrim(v_row->>'ticker')),v_report_year,
        upper(v_row->>'report_period'),v_period_end,v_pub,
        v_file_modified,v_row->>'file_url',v_row->>'file_name',lower(v_row->>'file_type'),
        'BLOCK_IDX_PROFILE_ANNOUNCEMENT_ATTACHMENT','IDX_XBRL_FINANCIAL_REPORT',
        nullif(v_row->>'content_hash',''),true,true,true,
        coalesce(nullif(v_row->>'extraction_state',''),'FILE_INDEXED_PIT_VERIFIED'),
        'OFFICIAL_BLOCK_IDX_PROFILE_ANNOUNCEMENT_POINT_IN_TIME'
      )
      on conflict(ticker,report_year,report_period,file_url) do update set
        filing_id=excluded.filing_id,
        report_period_end=excluded.report_period_end,
        published_at=excluded.published_at,
        file_modified_at=excluded.file_modified_at,
        file_name=excluded.file_name,
        file_type=excluded.file_type,
        report_type=excluded.report_type,
        source_key=excluded.source_key,
        content_hash=coalesce(excluded.content_hash,public.flow_financial_filing_evidence_v5.content_hash),
        publication_time_verified=true,
        source_verified=true,
        point_in_time_eligible=true,
        extraction_state=case
          when public.flow_financial_filing_evidence_v5.extraction_state in ('PARSED','FACTS_PARSED')
            then public.flow_financial_filing_evidence_v5.extraction_state
          else excluded.extraction_state
        end,
        provenance_state=excluded.provenance_state;
      v_upserts := v_upserts + 1;
    exception when others then
      v_rejected := v_rejected + 1;
    end;
  end loop;

  return jsonb_build_object(
    'status','OK',
    'financial_filing_upserts',v_upserts,
    'rejected_rows',v_rejected,
    'production_scoring_changed',false
  );
end;
$$;

revoke all on function public.flow_refresh_block_idx_historical_financial_cache_v5() from public,anon,authenticated;
grant execute on function public.flow_refresh_block_idx_historical_financial_cache_v5() to service_role;

comment on function public.flow_refresh_block_idx_historical_financial_cache_v5() is
'Ingest fixed revision-complete Block IDX financial filing cache. PIT publication time comes from official profile announcements; rows without verified period/timestamp/file identity are absent or rejected. No scoring changes.';
