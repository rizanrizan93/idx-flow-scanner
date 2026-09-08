-- Post-ingest audit. Revision-level duplicates are reported separately from key corruption.

create or replace function public.flow_audit_block_idx_financial_fact_manifest_v5(
  p_manifest_sha256 text
)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_manifest public.flow_financial_fact_manifest_v5%rowtype;
  v_complete_shards integer;
  v_filing_rows integer;
  v_fact_rows integer;
  v_bad_manifest_filing integer;
  v_duplicate_filing_metric integer;
  v_bad_source integer;
  v_bad_namespace integer;
  v_bad_unit integer;
  v_bad_period integer;
  v_bad_catalog integer;
  v_publication_before_period_end integer;
  v_unmanifested_fact_rows integer;
  v_revision_period_metric_groups integer;
  v_equal_value_revision_groups integer;
  v_status text;
begin
  if p_manifest_sha256 is null or p_manifest_sha256 !~ '^[0-9a-f]{64}$' then
    raise exception 'FINANCIAL_FACT_AUDIT_BAD_MANIFEST_SHA';
  end if;

  select * into v_manifest
  from public.flow_financial_fact_manifest_v5
  where manifest_sha256 = p_manifest_sha256;
  if not found then
    raise exception 'FINANCIAL_FACT_MANIFEST_NOT_REGISTERED';
  end if;

  select count(*) into v_complete_shards
  from public.flow_financial_fact_shard_ingest_v5
  where manifest_sha256 = p_manifest_sha256 and ingest_state = 'COMPLETE';

  select count(*) into v_filing_rows
  from public.flow_financial_fact_manifest_filing_v5
  where manifest_sha256 = p_manifest_sha256;

  select count(*) into v_bad_manifest_filing
  from public.flow_financial_fact_manifest_filing_v5 m
  left join public.flow_financial_filing_evidence_v5 p on p.filing_id = m.filing_id
  where m.manifest_sha256 = p_manifest_sha256
    and (
      p.filing_id is null
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
      or p.content_hash is distinct from m.content_hash
      or p.extraction_state <> 'FACTS_PARSED'
      or m.content_hash !~ '^[0-9a-f]{64}$'
    );

  select count(*) into v_fact_rows
  from public.flow_financial_fact_evidence_v5 e
  join public.flow_financial_fact_manifest_filing_v5 m
    on m.filing_id = e.filing_id and m.manifest_sha256 = p_manifest_sha256;

  select count(*) into v_duplicate_filing_metric
  from (
    select e.filing_id, e.metric_key
    from public.flow_financial_fact_evidence_v5 e
    join public.flow_financial_fact_manifest_filing_v5 m
      on m.filing_id = e.filing_id and m.manifest_sha256 = p_manifest_sha256
    group by e.filing_id, e.metric_key
    having count(*) > 1
  ) d;

  select
    count(*) filter (
      where p.filing_id is null
         or p.source_verified is not true
         or p.publication_time_verified is not true
         or p.point_in_time_eligible is not true
         or e.source_verified is not true
         or e.point_in_time_eligible is not true
         or e.provenance_state <> 'OFFICIAL_IDX_XBRL_INSTANCE_POINT_IN_TIME_VERIFIED_V5'
    ),
    count(*) filter (
      where e.taxonomy_namespace not in (
        'http://www.idx.co.id/xbrl/taxonomy/2020-01-01/cor',
        'https://www.idx.co.id/xbrl/taxonomy/2020-01-01/cor'
      )
    ),
    count(*) filter (
      where e.currency !~ '^[A-Z]{3}$' or e.unit is distinct from ('iso4217:' || e.currency)
    ),
    count(*) filter (
      where c.metric_key is null
         or (
           c.period_kind='instant'
           and (e.instant_date is distinct from p.report_period_end or e.period_start is not null or e.period_end is not null)
         )
         or (
           c.period_kind='duration'
           and (e.instant_date is not null or e.period_start is distinct from make_date(p.report_year,1,1) or e.period_end is distinct from p.report_period_end)
         )
    ),
    count(*) filter (
      where c.metric_key is null
         or e.metric_label is distinct from c.metric_label
         or coalesce(e.taxonomy_concept,'') <> all(c.concepts)
         or e.statement_type is distinct from c.statement_type
         or c.catalog_sha256 <> v_manifest.metric_catalog_sha256
    ),
    count(*) filter (where p.published_at::date < p.report_period_end)
  into
    v_bad_source, v_bad_namespace, v_bad_unit, v_bad_period, v_bad_catalog,
    v_publication_before_period_end
  from public.flow_financial_fact_evidence_v5 e
  join public.flow_financial_fact_manifest_filing_v5 m
    on m.filing_id = e.filing_id and m.manifest_sha256 = p_manifest_sha256
  left join public.flow_financial_filing_evidence_v5 p on p.filing_id = e.filing_id
  left join public.flow_financial_metric_catalog_v5 c on c.metric_key = e.metric_key;

  select count(*) into v_unmanifested_fact_rows
  from public.flow_financial_fact_evidence_v5 e
  where not exists (
    select 1 from public.flow_financial_fact_manifest_filing_v5 m where m.filing_id = e.filing_id
  );

  select count(*) into v_revision_period_metric_groups
  from (
    select p.ticker, e.metric_key, p.report_period_end
    from public.flow_financial_fact_evidence_v5 e
    join public.flow_financial_fact_manifest_filing_v5 m
      on m.filing_id = e.filing_id and m.manifest_sha256 = p_manifest_sha256
    join public.flow_financial_filing_evidence_v5 p on p.filing_id = e.filing_id
    group by p.ticker, e.metric_key, p.report_period_end
    having count(distinct e.filing_id) > 1
  ) d;

  select count(*) into v_equal_value_revision_groups
  from (
    select p.ticker, e.metric_key, p.report_period_end, e.metric_value, e.currency
    from public.flow_financial_fact_evidence_v5 e
    join public.flow_financial_fact_manifest_filing_v5 m
      on m.filing_id = e.filing_id and m.manifest_sha256 = p_manifest_sha256
    join public.flow_financial_filing_evidence_v5 p on p.filing_id = e.filing_id
    group by p.ticker, e.metric_key, p.report_period_end, e.metric_value, e.currency
    having count(distinct e.filing_id) > 1
  ) d;

  if v_manifest.ingest_state = 'COMPLETE'
     and v_complete_shards = v_manifest.shard_count
     and v_filing_rows = v_manifest.parsed_filing_rows
     and v_fact_rows = v_manifest.fact_rows
     and v_bad_manifest_filing = 0
     and v_duplicate_filing_metric = 0
     and v_bad_source = 0
     and v_bad_namespace = 0
     and v_bad_unit = 0
     and v_bad_period = 0
     and v_bad_catalog = 0
     and v_publication_before_period_end = 0
     and v_unmanifested_fact_rows = 0 then
    v_status := 'OK';
  else
    v_status := 'FAIL';
  end if;

  return jsonb_build_object(
    'status',v_status,
    'manifest_sha256',p_manifest_sha256,
    'manifest_state',v_manifest.ingest_state,
    'complete_shards',v_complete_shards,
    'expected_shards',v_manifest.shard_count,
    'filing_rows',v_filing_rows,
    'expected_filing_rows',v_manifest.parsed_filing_rows,
    'fact_rows',v_fact_rows,
    'expected_fact_rows',v_manifest.fact_rows,
    'bad_manifest_filing_rows',v_bad_manifest_filing,
    'duplicate_filing_metric_rows',v_duplicate_filing_metric,
    'bad_source_or_pit_rows',v_bad_source,
    'bad_namespace_rows',v_bad_namespace,
    'bad_unit_rows',v_bad_unit,
    'bad_period_rows',v_bad_period,
    'bad_catalog_rows',v_bad_catalog,
    'publication_before_period_end_rows',v_publication_before_period_end,
    'unmanifested_fact_rows',v_unmanifested_fact_rows,
    'revision_period_metric_groups',v_revision_period_metric_groups,
    'equal_value_revision_groups',v_equal_value_revision_groups,
    'revision_groups_are_informational',true,
    'production_scoring_changed',false
  );
end;
$$;

revoke all on function public.flow_audit_block_idx_financial_fact_manifest_v5(text)
  from public, anon, authenticated;
grant execute on function public.flow_audit_block_idx_financial_fact_manifest_v5(text)
  to service_role;

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
