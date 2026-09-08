-- Explicit 27-check acceptance. Hash readback validates values, not only row counts.
create or replace function public.flow_audit_block_idx_financial_fact_manifest_v5(p_manifest_sha256 text)
returns jsonb language plpgsql security invoker set search_path = '' as $$
declare
  m public.flow_financial_fact_manifest_v5%rowtype;
  s record; p record; f record; e record;
  checks jsonb;
  v_checks jsonb;
  v_pass integer;
  v_hash_bad integer;
  v_unmanifested integer;
  v_revision integer;
  v_equal_revision integer;
  v_diagnostics jsonb;
begin
  select * into m from public.flow_financial_fact_manifest_v5 where manifest_sha256=p_manifest_sha256;
  if not found then
    return jsonb_build_object('status','FAIL','passed_checks',0,'required_checks',27,'reason','MANIFEST_NOT_FOUND');
  end if;
  select count(*) n,count(*) filter(where ingest_state='COMPLETE') complete,
         coalesce(sum(expected_filing_rows),0) filings,coalesce(sum(expected_fact_rows),0) facts
  into s from public.flow_financial_fact_shard_ingest_v5 where manifest_sha256=p_manifest_sha256;
  select count(*) n, count(distinct mf.filing_id) distinct_ids,
         count(*) filter(where pf.source_verified is not true) bad_source,
         count(*) filter(where pf.publication_time_verified is not true) bad_publication,
         count(*) filter(where pf.point_in_time_eligible is not true) bad_pit,
         count(*) filter(where pf.report_period_end is null or (pf.published_at at time zone 'Asia/Jakarta')::date < pf.report_period_end) bad_publication_period,
         count(*) filter(where pf.content_hash is distinct from mf.content_hash or pf.extraction_state is distinct from 'FACTS_PARSED'
           or lower(pf.file_name) is distinct from 'instance.zip' or pf.filing_id is null) bad_identity
  into p from public.flow_financial_fact_manifest_filing_v5 mf
  left join public.flow_financial_filing_evidence_v5 pf on pf.filing_id=mf.filing_id
  where mf.manifest_sha256=p_manifest_sha256;
  select count(*) n,count(distinct ex.filing_id) distinct_ids,
         count(*) filter(where ex.retryable is not false or ex.point_in_time_identity_preserved is not true
           or pf.ticker is distinct from ex.ticker or pf.file_url is distinct from ex.provenance_payload->>'file_url'
           or pf.published_at is distinct from (ex.provenance_payload->>'published_at')::timestamptz
           or ex.provenance_payload is distinct from x.value) bad_identity
  into e from public.flow_financial_fact_manifest_exclusion_v5 ex
  left join public.flow_financial_filing_evidence_v5 pf on pf.filing_id=ex.filing_id
  left join jsonb_array_elements(m.exclusions_raw::jsonb->'rows') x on x.value->>'filing_id'=ex.filing_id
  where ex.manifest_sha256=p_manifest_sha256;
  select count(*) n,count(distinct ef.fact_id) distinct_ids,count(distinct (ef.filing_id,ef.metric_key)) distinct_pairs,
    count(*) filter(where ef.source_verified is not true or ef.point_in_time_eligible is not true
      or ef.provenance_state is distinct from 'OFFICIAL_IDX_XBRL_INSTANCE_POINT_IN_TIME_VERIFIED_V5') bad_source,
    count(*) filter(where coalesce(ef.taxonomy_namespace,'') not in ('http://www.idx.co.id/xbrl/taxonomy/2020-01-01/cor','https://www.idx.co.id/xbrl/taxonomy/2020-01-01/cor')) bad_namespace_rows,
    count(*) filter(where ef.currency is null or ef.currency !~ '^[A-Z]{3}$' or ef.unit is distinct from 'iso4217:'||ef.currency) bad_unit_rows,
    count(*) filter(where c.metric_key is null or ef.metric_label is distinct from c.metric_label
      or coalesce(ef.taxonomy_concept,'') <> all(c.concepts) or ef.statement_type is distinct from c.statement_type
      or c.catalog_sha256 is distinct from m.metric_catalog_sha256) bad_catalog_rows,
    count(*) filter(where pf.report_period_end is null or pf.report_period_end is distinct from case pf.report_period
        when 'TW1' then make_date(pf.report_year,3,31) when 'TW2' then make_date(pf.report_year,6,30)
        when 'TW3' then make_date(pf.report_year,9,30) when 'AUDIT' then make_date(pf.report_year,12,31) else null end
      or (c.period_kind='instant' and (ef.instant_date is distinct from pf.report_period_end or ef.period_start is not null or ef.period_end is not null))
      or (c.period_kind='duration' and (ef.instant_date is not null or ef.period_start is distinct from make_date(pf.report_year,1,1) or ef.period_end is distinct from pf.report_period_end))) bad_period_rows,
    count(*) filter(where ef.metric_value is null or ef.metric_value::text in ('NaN','Infinity','-Infinity')
      or ef.fact_state is distinct from 'PARSED_VALIDATED_EXACT_TAXONOMY' or ef.ticker is distinct from pf.ticker) bad_value_rows
  into f from public.flow_financial_fact_evidence_v5 ef
  join public.flow_financial_fact_manifest_filing_v5 mf on mf.filing_id=ef.filing_id and mf.manifest_sha256=p_manifest_sha256
  left join public.flow_financial_filing_evidence_v5 pf on pf.filing_id=ef.filing_id
  left join public.flow_financial_metric_catalog_v5 c on c.metric_key=ef.metric_key;
  with actual as (
    select mf.shard_index,encode(extensions.digest(convert_to(string_agg(public.flow_financial_fact_row_digest_v5(to_jsonb(ef)-'ingested_at'), E'\n' order by ef.fact_id),'UTF8'),'sha256'),'hex') digest
    from public.flow_financial_fact_evidence_v5 ef join public.flow_financial_fact_manifest_filing_v5 mf on mf.filing_id=ef.filing_id
    where mf.manifest_sha256=p_manifest_sha256 group by mf.shard_index
  ) select count(*) into v_hash_bad
    from public.flow_financial_fact_shard_ingest_v5 sh left join actual a on a.shard_index=sh.shard_index
    where sh.manifest_sha256=p_manifest_sha256 and (a.digest is null or a.digest is distinct from sh.expected_relational_sha256 or a.digest is distinct from sh.actual_relational_sha256);
  select count(*) into v_unmanifested from public.flow_financial_fact_evidence_v5 ef
    where not exists(select 1 from public.flow_financial_fact_manifest_filing_v5 mf where mf.filing_id=ef.filing_id and mf.manifest_sha256=p_manifest_sha256);
  checks:=jsonb_build_array(
    jsonb_build_object('check',1,'name','manifest_exists','pass',coalesce((true),false)),
    jsonb_build_object('check',2,'name','manifest_sha_valid','pass',coalesce((encode(extensions.digest(convert_to(m.manifest_raw,'UTF8'),'sha256'),'hex')=m.manifest_sha256 and m.manifest_raw::jsonb=m.manifest_payload),false)),
    jsonb_build_object('check',3,'name','immutable_artifact_provenance_valid','pass',coalesce((m.manifest_url=('https://raw.githubusercontent.com/rizanrizan93/idx-flow-scanner/'||m.artifact_commit_sha||'/evidence_artifacts/financial_facts_v5/run-'||m.source_run_id||'/manifest.json') and m.artifact_commit_sha ~ '^[0-9a-f]{40}$'),false)),
    jsonb_build_object('check',4,'name','source_run_head_valid','pass',coalesce((m.source_run_id=34225525473 and m.source_head_sha='de0bcfffafe1feb04cd23b2ad560a50d050a42fd' and (m.manifest_payload->>'source_run_id')::bigint=m.source_run_id and m.manifest_payload->>'source_head_sha'=m.source_head_sha),false)),
    jsonb_build_object('check',5,'name','metric_catalog_sha_exact','pass',coalesce((m.metric_catalog_sha256='fdb22a134597d5161632aedef260fdaf9342f997aa55c4d11e670043a372b930' and (select count(*) from public.flow_financial_metric_catalog_v5 where catalog_sha256=m.metric_catalog_sha256)=19),false)),
    jsonb_build_object('check',6,'name','manifest_complete','pass',coalesce((m.ingest_state='COMPLETE'),false)),
    jsonb_build_object('check',7,'name','selected_equals_parsed_plus_excluded','pass',coalesce((m.selected_filing_rows=12285 and m.selected_filing_rows=m.parsed_filing_rows+m.permanent_excluded_filing_rows and m.selected_filing_rows=p.n+e.n),false)),
    jsonb_build_object('check',8,'name','parsed_filing_count_exact','pass',coalesce((p.n=12029 and p.n=m.parsed_filing_rows),false)),
    jsonb_build_object('check',9,'name','exclusion_count_exact','pass',coalesce((e.n=256 and e.n=m.permanent_excluded_filing_rows and jsonb_array_length(m.exclusions_raw::jsonb->'rows')=e.n),false)),
    jsonb_build_object('check',10,'name','fact_count_exact','pass',coalesce((f.n=203408 and f.n=m.fact_rows),false)),
    jsonb_build_object('check',11,'name','shard_count_exact','pass',coalesce((s.n=25 and s.n=m.shard_count and s.n=jsonb_array_length(m.manifest_payload->'shards')),false)),
    jsonb_build_object('check',12,'name','every_shard_complete','pass',coalesce((s.complete=s.n),false)),
    jsonb_build_object('check',13,'name','aggregate_shard_filing_count_matches_parsed','pass',coalesce((s.filings=p.n),false)),
    jsonb_build_object('check',14,'name','aggregate_shard_fact_count_matches_facts','pass',coalesce((s.facts=f.n),false)),
    jsonb_build_object('check',15,'name','no_duplicate_manifest_filing_ids','pass',coalesce((p.n=p.distinct_ids),false)),
    jsonb_build_object('check',16,'name','no_duplicate_exclusion_filing_ids','pass',coalesce((e.n=e.distinct_ids),false)),
    jsonb_build_object('check',17,'name','parsed_excluded_disjoint','pass',coalesce((not exists(select 1 from public.flow_financial_fact_manifest_filing_v5 mf join public.flow_financial_fact_manifest_exclusion_v5 ex using(manifest_sha256,filing_id) where mf.manifest_sha256=p_manifest_sha256)),false)),
    jsonb_build_object('check',18,'name','no_duplicate_fact_ids','pass',coalesce((f.n=f.distinct_ids),false)),
    jsonb_build_object('check',19,'name','no_duplicate_filing_metric_pairs','pass',coalesce((f.n=f.distinct_pairs),false)),
    jsonb_build_object('check',20,'name','parsed_parents_source_verified','pass',coalesce((p.bad_source=0),false)),
    jsonb_build_object('check',21,'name','publication_time_verified','pass',coalesce((p.bad_publication=0),false)),
    jsonb_build_object('check',22,'name','point_in_time_eligible','pass',coalesce((p.bad_pit=0),false)),
    jsonb_build_object('check',23,'name','publication_on_or_after_period_end','pass',coalesce((p.bad_publication_period=0),false)),
    jsonb_build_object('check',24,'name','facts_exact_official_idx_pit_provenance','pass',coalesce((f.bad_source=0),false)),
    jsonb_build_object('check',25,'name','no_revision_substitution_or_pit_identity_breach','pass',coalesce((p.bad_identity=0 and e.bad_identity=0 and v_hash_bad=0 and encode(extensions.digest(convert_to(m.exclusions_raw,'UTF8'),'sha256'),'hex')=m.manifest_payload->'exclusions'->>'sha256'),false)),
    jsonb_build_object('check',26,'name','fact_semantic_integrity','pass',coalesce((f.bad_namespace_rows=0 and f.bad_unit_rows=0 and f.bad_catalog_rows=0 and f.bad_period_rows=0 and f.bad_value_rows=0 and v_hash_bad=0 and not exists(select 1 from public.flow_financial_fact_evidence_v5 ef join public.flow_financial_fact_manifest_filing_v5 mf on mf.filing_id=ef.filing_id where mf.manifest_sha256=p_manifest_sha256 group by ef.filing_id having count(distinct ef.currency)<>1)),false)),
    jsonb_build_object('check',27,'name','no_unmanifested_or_unexplained_facts','pass',coalesce((v_unmanifested=0),false))
  );
  select jsonb_agg(value||jsonb_build_object('status',case when (value->>'pass')::boolean then 'PASS' else 'FAIL' end) order by (value->>'check')::integer),
    count(*) filter(where (value->>'pass')::boolean) into v_checks,v_pass from jsonb_array_elements(checks);
  select count(*) into v_revision from (
    select pf.ticker,ef.metric_key,pf.report_period_end from public.flow_financial_fact_evidence_v5 ef
    join public.flow_financial_filing_evidence_v5 pf on pf.filing_id=ef.filing_id
    group by 1,2,3 having count(distinct ef.filing_id)>1) x;
  select count(*) into v_equal_revision from (
    select pf.ticker,ef.metric_key,pf.report_period_end,ef.metric_value,ef.currency from public.flow_financial_fact_evidence_v5 ef
    join public.flow_financial_filing_evidence_v5 pf on pf.filing_id=ef.filing_id
    group by 1,2,3,4,5 having count(distinct ef.filing_id)>1) x;
  select jsonb_build_object(
    'metrics_per_filing_distribution',(select jsonb_object_agg(n,c) from (select n,count(*) c from (select filing_id,count(*) n from public.flow_financial_fact_evidence_v5 group by filing_id) a group by n) b),
    'currency_distribution',(select jsonb_object_agg(currency,n) from (select currency,count(*) n from public.flow_financial_fact_evidence_v5 group by currency) a),
    'ticker_coverage',(select count(distinct ticker) from public.flow_financial_fact_evidence_v5),
    'filings_with_under_five_metrics',(select count(*) from (select filing_id from public.flow_financial_fact_evidence_v5 group by filing_id having count(*)<5) a),
    'temporal_coverage',(select jsonb_build_object('published_min',min(pf.published_at),'published_max',max(pf.published_at),'report_min',min(pf.report_period_end),'report_max',max(pf.report_period_end)) from public.flow_financial_filing_evidence_v5 pf join public.flow_financial_fact_manifest_filing_v5 mf using(filing_id) where mf.manifest_sha256=p_manifest_sha256),
    'report_period_coverage',(select jsonb_object_agg(report_period,n) from (select pf.report_period,count(*) n from public.flow_financial_filing_evidence_v5 pf join public.flow_financial_fact_manifest_filing_v5 mf using(filing_id) where mf.manifest_sha256=p_manifest_sha256 group by report_period) a),
    'exclusion_failure_class_distribution',m.manifest_payload->'exclusion_class_counts',
    'taxonomy_distribution',(select jsonb_object_agg(taxonomy_namespace,n) from (select taxonomy_namespace,count(*) n from public.flow_financial_fact_evidence_v5 group by taxonomy_namespace) a),
    'largest_issuer_fact_counts',(select jsonb_agg(to_jsonb(a)) from (select ticker,count(*) n from public.flow_financial_fact_evidence_v5 group by ticker order by n desc,ticker limit 10) a)
  ) into v_diagnostics;
  return jsonb_build_object('status',case when v_pass=27 then 'OK' else 'FAIL' end,'gate6_status',case when v_pass=27 then 'PASS' else 'FAIL' end,
    'passed_checks',v_pass,'required_checks',27,'checks',v_checks,'manifest_sha256',p_manifest_sha256,
    'selected_filing_rows',m.selected_filing_rows,'parsed_filing_rows',p.n,'permanent_excluded_filing_rows',e.n,'fact_rows',f.n,
    'complete_shards',s.complete,'bad_relational_hash_shards',v_hash_bad,'duplicate_filing_metric_rows',f.n-f.distinct_pairs,
    'publication_before_period_end_rows',p.bad_publication_period,
    'revision_period_metric_groups',v_revision,'equal_value_revision_groups',v_equal_revision,'revision_groups_are_informational',true,
    'diagnostics',v_diagnostics,'production_scoring_changed',false);
end;
$$;
revoke all on function public.flow_audit_block_idx_financial_fact_manifest_v5(text) from public, anon, authenticated;
grant execute on function public.flow_audit_block_idx_financial_fact_manifest_v5(text) to service_role;

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

revoke all on public.flow_evidence_expansion_quality_summary_v5 from public, anon, authenticated;
grant select on public.flow_evidence_expansion_quality_summary_v5 to service_role;

comment on function public.flow_audit_block_idx_financial_fact_manifest_v5(text) is
'Audits canonical financial facts for manifest completeness, source/PIT leakage, exact namespace/catalog, unit/currency, period, parent content hash and duplicate key corruption. Cross-revision duplicates are reported separately because legitimate issuer revisions are distinct PIT evidence.';
