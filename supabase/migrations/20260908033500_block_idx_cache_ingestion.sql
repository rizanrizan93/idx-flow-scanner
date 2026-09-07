-- Evidence Expansion v5: ingest scanner-produced Block IDX cache from this public repository.
-- The downloader runs in GitHub Actions because Block IDX SSR is reachable there.
-- Canonical Supabase reads only fixed raw-GitHub URLs; no arbitrary URL input is accepted.
-- No production scoring, Phase4D shadow, or Phase4E weight logic is changed.

create or replace function public.flow_idx_official_url_v5(p_url text)
returns boolean
language sql
immutable
security invoker
set search_path=pg_catalog
as $$
  select coalesce(
    p_url ~ '^https://(www\.)?idx\.co\.id/'
    or p_url ~ '^https://block\.idx\.id/',
    false
  );
$$;

create or replace function public.flow_refresh_block_idx_cache_v5()
returns jsonb
language plpgsql
security invoker
set search_path=pg_catalog,public,extensions
as $$
declare
  v_announcement_url constant text := 'https://raw.githubusercontent.com/rizanrizan93/idx-flow-scanner/main/data/cache/evidence_v5/block_idx_current_announcements.json';
  v_filing_url constant text := 'https://raw.githubusercontent.com/rizanrizan93/idx-flow-scanner/main/data/cache/evidence_v5/block_idx_current_financial_filings.json';
  v_status integer;
  v_content text;
  v_payload jsonb;
  v_row jsonb;
  v_pub timestamptz;
  v_disclosure_upserts integer := 0;
  v_filing_upserts integer := 0;
  v_rejected integer := 0;
begin
  select status, content into v_status, v_content
  from extensions.http_get(v_announcement_url);

  if v_status <> 200 or v_content is null then
    return jsonb_build_object(
      'status','ANNOUNCEMENT_CACHE_UNAVAILABLE',
      'http_status',v_status,
      'production_scoring_changed',false
    );
  end if;

  begin
    v_payload := v_content::jsonb;
  exception when others then
    return jsonb_build_object('status','ANNOUNCEMENT_CACHE_INVALID_JSON','production_scoring_changed',false);
  end;

  if v_payload->>'schema_version' <> 'BLOCK_IDX_DISCLOSURE_CACHE_V5_1'
     or v_payload->>'source_page' <> 'https://block.idx.id/id/berita/pengumuman'
     or jsonb_typeof(v_payload->'rows') <> 'array' then
    return jsonb_build_object('status','ANNOUNCEMENT_CACHE_CONTRACT_MISMATCH','production_scoring_changed',false);
  end if;

  for v_row in select value from jsonb_array_elements(v_payload->'rows')
  loop
    begin
      v_pub := (v_row->>'published_at')::timestamptz;
      if coalesce(v_row->>'announcement_id','') = ''
         or coalesce(v_row->>'title','') = ''
         or v_row->>'source_key' <> 'IDX_DISCLOSURE_ANNOUNCEMENT'
         or not public.flow_idx_official_url_v5(v_row->>'official_detail_url')
         or coalesce((v_row->>'publication_time_verified')::boolean,false) is not true
         or coalesce((v_row->>'source_verified')::boolean,false) is not true
         or coalesce((v_row->>'point_in_time_eligible')::boolean,false) is not true
         or v_pub > now() + interval '10 minutes' then
        v_rejected := v_rejected + 1;
        continue;
      end if;

      insert into public.flow_disclosure_evidence_v5(
        announcement_id,ticker,published_at,announcement_no,title,disclosure_type,
        official_detail_url,attachment_urls,source_key,content_hash,
        publication_time_verified,source_verified,point_in_time_eligible,
        narrative_extraction_state,provenance_state
      ) values (
        v_row->>'announcement_id',nullif(btrim(v_row->>'ticker'),''),v_pub,
        nullif(v_row->>'announcement_no',''),v_row->>'title',v_row->>'disclosure_type',
        v_row->>'official_detail_url',coalesce(v_row->'attachment_urls','[]'::jsonb),
        'IDX_DISCLOSURE_ANNOUNCEMENT',nullif(v_row->>'content_hash',''),
        true,true,true,
        coalesce(nullif(v_row->>'narrative_extraction_state',''),'METADATA_WITH_OFFICIAL_ATTACHMENTS'),
        'OFFICIAL_BLOCK_IDX_SSR_POINT_IN_TIME'
      )
      on conflict(announcement_id) do update set
        ticker=excluded.ticker,
        published_at=excluded.published_at,
        title=excluded.title,
        disclosure_type=excluded.disclosure_type,
        official_detail_url=excluded.official_detail_url,
        attachment_urls=excluded.attachment_urls,
        content_hash=excluded.content_hash,
        publication_time_verified=true,
        source_verified=true,
        point_in_time_eligible=true,
        narrative_extraction_state=excluded.narrative_extraction_state,
        provenance_state=excluded.provenance_state;
      v_disclosure_upserts := v_disclosure_upserts + 1;
    exception when others then
      v_rejected := v_rejected + 1;
    end;
  end loop;

  select status, content into v_status, v_content
  from extensions.http_get(v_filing_url);

  if v_status = 200 and v_content is not null then
    begin
      v_payload := v_content::jsonb;
      if v_payload->>'schema_version' = 'BLOCK_IDX_FINANCIAL_FILING_CACHE_V5_1'
         and v_payload->>'source_page' = 'https://block.idx.id/id/berita/pengumuman'
         and jsonb_typeof(v_payload->'rows') = 'array' then
        for v_row in select value from jsonb_array_elements(v_payload->'rows')
        loop
          begin
            v_pub := (v_row->>'published_at')::timestamptz;
            if coalesce(v_row->>'filing_id','') = ''
               or coalesce(v_row->>'ticker','') = ''
               or v_row->>'source_key' <> 'IDX_XBRL_FINANCIAL_REPORT'
               or not public.flow_idx_official_url_v5(v_row->>'file_url')
               or coalesce((v_row->>'publication_time_verified')::boolean,false) is not true
               or coalesce((v_row->>'source_verified')::boolean,false) is not true
               or coalesce((v_row->>'point_in_time_eligible')::boolean,false) is not true
               or v_pub > now() + interval '10 minutes'
               or v_pub::date < (v_row->>'report_period_end')::date then
              v_rejected := v_rejected + 1;
              continue;
            end if;

            insert into public.flow_financial_filing_evidence_v5(
              filing_id,ticker,report_year,report_period,report_period_end,published_at,
              file_modified_at,file_url,file_name,file_type,report_type,source_key,content_hash,
              publication_time_verified,source_verified,point_in_time_eligible,extraction_state,
              provenance_state
            ) values (
              v_row->>'filing_id',upper(btrim(v_row->>'ticker')),(v_row->>'report_year')::integer,
              v_row->>'report_period',(v_row->>'report_period_end')::date,v_pub,
              nullif(v_row->>'file_modified_at','')::timestamptz,v_row->>'file_url',v_row->>'file_name',
              v_row->>'file_type',v_row->>'report_type','IDX_XBRL_FINANCIAL_REPORT',
              nullif(v_row->>'content_hash',''),true,true,true,
              coalesce(nullif(v_row->>'extraction_state',''),'FILE_INDEXED_NOT_PARSED'),
              'OFFICIAL_BLOCK_IDX_FINANCIAL_FILING_POINT_IN_TIME'
            )
            on conflict(filing_id) do update set
              published_at=excluded.published_at,
              file_url=excluded.file_url,
              file_name=excluded.file_name,
              file_type=excluded.file_type,
              report_type=excluded.report_type,
              publication_time_verified=true,
              source_verified=true,
              point_in_time_eligible=true,
              extraction_state=excluded.extraction_state,
              provenance_state=excluded.provenance_state;
            v_filing_upserts := v_filing_upserts + 1;
          exception when others then
            v_rejected := v_rejected + 1;
          end;
        end loop;
      end if;
    exception when others then
      null;
    end;
  end if;

  return jsonb_build_object(
    'status','OK',
    'disclosure_upserts',v_disclosure_upserts,
    'financial_filing_upserts',v_filing_upserts,
    'rejected_rows',v_rejected,
    'production_scoring_changed',false
  );
end;
$$;

revoke all on function public.flow_idx_official_url_v5(text) from public,anon,authenticated;
revoke all on function public.flow_refresh_block_idx_cache_v5() from public,anon,authenticated;
grant execute on function public.flow_idx_official_url_v5(text) to service_role;
grant execute on function public.flow_refresh_block_idx_cache_v5() to service_role;

select cron.schedule(
  'flow-block-idx-cache-ingest-late',
  '45 16 * * 1-5',
  $$select public.flow_refresh_block_idx_cache_v5();$$
)
where not exists(select 1 from cron.job where jobname='flow-block-idx-cache-ingest-late');

select cron.schedule(
  'flow-block-idx-cache-ingest-morning',
  '45 23 * * 0-4',
  $$select public.flow_refresh_block_idx_cache_v5();$$
)
where not exists(select 1 from cron.job where jobname='flow-block-idx-cache-ingest-morning');

comment on function public.flow_refresh_block_idx_cache_v5() is
'Ingest fixed raw-GitHub Block IDX evidence cache generated by the scanner. Validates official IDX URLs and point-in-time timestamps. No arbitrary URL input and no scoring changes.';
