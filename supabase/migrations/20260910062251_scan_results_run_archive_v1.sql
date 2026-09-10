-- Storage remediation: archive superseded scan-result runs while preserving every
-- row losslessly and keeping every run that contributes a latest ticker/as_of_date
-- observation in the hot operational table. No scoring/ranking/promotion change.

DO $do$
DECLARE
  v_kind "char";
  v_rows bigint;
  v_incoming_fk bigint;
  v_trigger_count bigint;
BEGIN
  SELECT c.relkind INTO v_kind
  FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
  WHERE n.nspname='public' AND c.relname='flow_scan_results';
  IF v_kind IS DISTINCT FROM 'r'::"char" THEN
    RAISE EXCEPTION 'scan-results archive denied: expected physical table, got %',v_kind;
  END IF;
  IF to_regclass('public.flow_scan_results_archive_v1') IS NOT NULL
     OR to_regclass('public.flow_scan_results_hot_v1') IS NOT NULL
     OR to_regclass('public.flow_scan_results_legacy_v1') IS NOT NULL THEN
    RAISE EXCEPTION 'scan-results archive denied: target or legacy object already exists';
  END IF;
  SELECT count(*)::bigint INTO v_rows FROM public.flow_scan_results;
  IF v_rows<1000 THEN
    RAISE EXCEPTION 'scan-results archive denied: unexpectedly small source % rows',v_rows;
  END IF;
  SELECT count(*)::bigint INTO v_incoming_fk
  FROM pg_constraint WHERE contype='f' AND confrelid='public.flow_scan_results'::regclass;
  IF v_incoming_fk<>0 THEN
    RAISE EXCEPTION 'scan-results archive denied: % incoming FK references exist',v_incoming_fk;
  END IF;
  SELECT count(*)::bigint INTO v_trigger_count
  FROM pg_trigger
  WHERE tgrelid='public.flow_scan_results'::regclass AND NOT tgisinternal
    AND tgname='flow_scan_results_capture_adaptive_broker_obs';
  IF v_trigger_count<>1 OR EXISTS(
    SELECT 1 FROM pg_trigger
    WHERE tgrelid='public.flow_scan_results'::regclass AND NOT tgisinternal
      AND tgname<>'flow_scan_results_capture_adaptive_broker_obs'
  ) THEN
    RAISE EXCEPTION 'scan-results archive denied: trigger contract drift';
  END IF;
END
$do$;

CREATE TEMPORARY TABLE flow_scan_results_compaction_stats_v1 ON COMMIT DROP AS
WITH row_hashes AS (
  SELECT encode(extensions.digest(convert_to(concat_ws('|',
    run_id::text,ticker,as_of_date::text,final_score::text,phase,action,evidence_tier,
    evidence_coverage_pct::text,real_money_state,coalesce(distribution_risk::text,''),
    coalesce(estimated_smart_money_cost::text,''),coalesce(premium_to_cost_pct::text,''),
    coalesce(entry_low::text,''),coalesce(entry_high::text,''),coalesce(invalidation::text,''),
    coalesce(tp1::text,''),coalesce(tp2::text,''),components::text,diagnostics::text,
    coalesce(guardrail_reason,''),created_at::text
  ),'UTF8'),'sha256'),'hex') row_sha
  FROM public.flow_scan_results
)
SELECT
  (SELECT count(*)::bigint FROM public.flow_scan_results) AS before_rows,
  (SELECT count(DISTINCT run_id)::bigint FROM public.flow_scan_results) AS before_runs,
  pg_total_relation_size('public.flow_scan_results'::regclass)::bigint AS before_bytes,
  encode(extensions.digest(convert_to(coalesce(string_agg(row_sha,'' ORDER BY row_sha),''),'UTF8'),'sha256'),'hex') AS logical_sha256
FROM row_hashes;

CREATE TEMPORARY TABLE flow_scan_results_latest_rows_v1 ON COMMIT DROP AS
SELECT DISTINCT ON (ticker,as_of_date)
  run_id,ticker,as_of_date,created_at
FROM public.flow_scan_results
ORDER BY ticker,as_of_date,created_at DESC,run_id DESC;

CREATE TEMPORARY TABLE flow_scan_results_keep_runs_v1 ON COMMIT DROP AS
WITH latest_contributors AS (
  SELECT DISTINCT run_id FROM flow_scan_results_latest_rows_v1
), latest_terminal AS (
  SELECT r.id AS run_id
  FROM public.flow_scan_runs r
  WHERE r.status IN('COMPLETED','COMPLETED_PARTIAL','FAILED','CANCELLED')
    AND EXISTS(SELECT 1 FROM public.flow_scan_results s WHERE s.run_id=r.id)
  ORDER BY coalesce(r.completed_at,r.started_at) DESC,r.id DESC
  LIMIT 3
), nonterminal AS (
  SELECT DISTINCT r.id AS run_id
  FROM public.flow_scan_runs r
  WHERE r.status NOT IN('COMPLETED','COMPLETED_PARTIAL','FAILED','CANCELLED')
    AND EXISTS(SELECT 1 FROM public.flow_scan_results s WHERE s.run_id=r.id)
)
SELECT run_id FROM latest_contributors
UNION SELECT run_id FROM latest_terminal
UNION SELECT run_id FROM nonterminal;

DO $do$
DECLARE v_keep bigint; v_archive bigint;
BEGIN
  SELECT count(*) INTO v_keep FROM flow_scan_results_keep_runs_v1;
  SELECT count(*) INTO v_archive
  FROM public.flow_scan_results s
  WHERE NOT EXISTS(SELECT 1 FROM flow_scan_results_keep_runs_v1 k WHERE k.run_id=s.run_id);
  IF v_keep<1 OR v_archive<1 THEN
    RAISE EXCEPTION 'scan-results archive denied: keep %, archive %',v_keep,v_archive;
  END IF;
END
$do$;

CREATE TABLE public.flow_scan_results_archive_v1(
  run_id uuid PRIMARY KEY,
  archive_contract text NOT NULL DEFAULT 'SCAN_RESULTS_SUPERSEDED_RUN_ARCHIVE_V1'
    CHECK(archive_contract='SCAN_RESULTS_SUPERSEDED_RUN_ARCHIVE_V1'),
  row_count integer NOT NULL CHECK(row_count>0),
  min_as_of_date date NOT NULL,
  max_as_of_date date NOT NULL,
  payload jsonb NOT NULL,
  payload_sha256 text NOT NULL CHECK(length(payload_sha256)=64),
  logical_sha256 text NOT NULL CHECK(length(logical_sha256)=64),
  archived_at timestamptz NOT NULL DEFAULT statement_timestamp(),
  production_influence_enabled boolean NOT NULL DEFAULT false CHECK(production_influence_enabled=false)
);

WITH prepared AS (
  SELECT s.*,
    encode(extensions.digest(convert_to(concat_ws('|',
      s.run_id::text,s.ticker,s.as_of_date::text,s.final_score::text,s.phase,s.action,s.evidence_tier,
      s.evidence_coverage_pct::text,s.real_money_state,coalesce(s.distribution_risk::text,''),
      coalesce(s.estimated_smart_money_cost::text,''),coalesce(s.premium_to_cost_pct::text,''),
      coalesce(s.entry_low::text,''),coalesce(s.entry_high::text,''),coalesce(s.invalidation::text,''),
      coalesce(s.tp1::text,''),coalesce(s.tp2::text,''),s.components::text,s.diagnostics::text,
      coalesce(s.guardrail_reason,''),s.created_at::text
    ),'UTF8'),'sha256'),'hex') AS row_sha
  FROM public.flow_scan_results s
  WHERE NOT EXISTS(SELECT 1 FROM flow_scan_results_keep_runs_v1 k WHERE k.run_id=s.run_id)
), grouped AS (
  SELECT run_id,count(*)::integer row_count,min(as_of_date) min_as_of_date,max(as_of_date) max_as_of_date,
         jsonb_agg(to_jsonb(prepared)-'row_sha' ORDER BY ticker) payload,
         encode(extensions.digest(convert_to(coalesce(string_agg(row_sha,'' ORDER BY row_sha),''),'UTF8'),'sha256'),'hex') logical_sha256
  FROM prepared GROUP BY run_id
)
INSERT INTO public.flow_scan_results_archive_v1(
  run_id,row_count,min_as_of_date,max_as_of_date,payload,payload_sha256,logical_sha256
)
SELECT run_id,row_count,min_as_of_date,max_as_of_date,payload,
       encode(extensions.digest(convert_to(payload::text,'UTF8'),'sha256'),'hex'),logical_sha256
FROM grouped;

DO $do$
DECLARE v_source_rows bigint; v_archive_rows bigint; v_bad bigint;
BEGIN
  SELECT count(*) INTO v_source_rows
  FROM public.flow_scan_results s
  WHERE NOT EXISTS(SELECT 1 FROM flow_scan_results_keep_runs_v1 k WHERE k.run_id=s.run_id);
  SELECT coalesce(sum(row_count),0),count(*) FILTER(
    WHERE jsonb_array_length(payload)<>row_count
       OR payload_sha256<>encode(extensions.digest(convert_to(payload::text,'UTF8'),'sha256'),'hex')
  ) INTO v_archive_rows,v_bad
  FROM public.flow_scan_results_archive_v1;
  IF v_source_rows<>v_archive_rows OR v_bad<>0 THEN
    RAISE EXCEPTION 'scan-results archive verification failed: source %, archive %, bad %',
      v_source_rows,v_archive_rows,v_bad;
  END IF;
END
$do$;

CREATE TABLE public.flow_scan_results_hot_v1(
  run_id uuid NOT NULL,
  ticker text NOT NULL,
  as_of_date date NOT NULL,
  final_score numeric NOT NULL,
  phase text NOT NULL,
  action text NOT NULL,
  evidence_tier text NOT NULL,
  evidence_coverage_pct numeric NOT NULL,
  real_money_state text NOT NULL,
  distribution_risk numeric,
  estimated_smart_money_cost numeric,
  premium_to_cost_pct numeric,
  entry_low numeric,
  entry_high numeric,
  invalidation numeric,
  tp1 numeric,
  tp2 numeric,
  components jsonb NOT NULL DEFAULT '{}'::jsonb,
  diagnostics jsonb NOT NULL DEFAULT '{}'::jsonb,
  guardrail_reason text,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT flow_scan_results_hot_v1_pkey PRIMARY KEY(run_id,ticker),
  CONSTRAINT flow_scan_results_hot_v1_final_score_check CHECK(final_score>=0 AND final_score<=100),
  CONSTRAINT flow_scan_results_hot_v1_evidence_coverage_pct_check CHECK(evidence_coverage_pct>=0 AND evidence_coverage_pct<=100),
  CONSTRAINT flow_scan_results_hot_v1_run_id_fkey FOREIGN KEY(run_id)
    REFERENCES public.flow_scan_runs(id) ON DELETE CASCADE
);
CREATE INDEX flow_scan_results_hot_v1_score_idx
  ON public.flow_scan_results_hot_v1(run_id,final_score DESC);
CREATE INDEX flow_scan_results_hot_v1_ticker_idx
  ON public.flow_scan_results_hot_v1(ticker,as_of_date DESC);

INSERT INTO public.flow_scan_results_hot_v1
SELECT s.* FROM public.flow_scan_results s
WHERE EXISTS(SELECT 1 FROM flow_scan_results_keep_runs_v1 k WHERE k.run_id=s.run_id)
ORDER BY s.run_id,s.ticker;

ANALYZE public.flow_scan_results_hot_v1;
ANALYZE public.flow_scan_results_archive_v1;

DO $do$
DECLARE v_missing_latest bigint; v_before bigint; v_hot bigint; v_archived bigint;
        v_before_bytes bigint; v_new_bytes bigint;
BEGIN
  SELECT count(*) INTO v_missing_latest
  FROM flow_scan_results_latest_rows_v1 l
  LEFT JOIN public.flow_scan_results_hot_v1 h
    ON h.run_id=l.run_id AND h.ticker=l.ticker AND h.as_of_date=l.as_of_date AND h.created_at=l.created_at
  WHERE h.run_id IS NULL;
  IF v_missing_latest<>0 THEN
    RAISE EXCEPTION 'scan-results archive denied: % latest ticker/date rows would be lost from hot table',v_missing_latest;
  END IF;
  SELECT before_rows,before_bytes INTO v_before,v_before_bytes
  FROM flow_scan_results_compaction_stats_v1;
  SELECT count(*) INTO v_hot FROM public.flow_scan_results_hot_v1;
  SELECT coalesce(sum(row_count),0) INTO v_archived FROM public.flow_scan_results_archive_v1;
  IF v_before<>v_hot+v_archived THEN
    RAISE EXCEPTION 'scan-results row conservation failed: before %, hot %, archived %',v_before,v_hot,v_archived;
  END IF;
  v_new_bytes:=pg_total_relation_size('public.flow_scan_results_hot_v1'::regclass)
             +pg_total_relation_size('public.flow_scan_results_archive_v1'::regclass);
  IF v_before_bytes-v_new_bytes < 10*1024*1024 THEN
    RAISE EXCEPTION 'scan-results archive insufficient storage gain: before %, new %',v_before_bytes,v_new_bytes;
  END IF;
END
$do$;

ALTER TABLE public.flow_scan_results RENAME TO flow_scan_results_legacy_v1;
ALTER TABLE public.flow_scan_results_hot_v1 RENAME TO flow_scan_results;
DROP TABLE public.flow_scan_results_legacy_v1 RESTRICT;

ALTER TABLE public.flow_scan_results RENAME CONSTRAINT flow_scan_results_hot_v1_pkey TO flow_scan_results_pkey;
ALTER TABLE public.flow_scan_results RENAME CONSTRAINT flow_scan_results_hot_v1_final_score_check TO flow_scan_results_final_score_check;
ALTER TABLE public.flow_scan_results RENAME CONSTRAINT flow_scan_results_hot_v1_evidence_coverage_pct_check TO flow_scan_results_evidence_coverage_pct_check;
ALTER TABLE public.flow_scan_results RENAME CONSTRAINT flow_scan_results_hot_v1_run_id_fkey TO flow_scan_results_run_id_fkey;
ALTER INDEX public.flow_scan_results_hot_v1_score_idx RENAME TO flow_scan_results_score_idx;
ALTER INDEX public.flow_scan_results_hot_v1_ticker_idx RENAME TO flow_scan_results_ticker_idx;

ALTER TABLE public.flow_scan_results ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.flow_scan_results_archive_v1 ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.flow_scan_results,public.flow_scan_results_archive_v1 FROM public,anon,authenticated;
GRANT SELECT,INSERT,UPDATE,DELETE ON TABLE public.flow_scan_results TO service_role;
GRANT SELECT ON TABLE public.flow_scan_results_archive_v1 TO service_role;

CREATE TRIGGER flow_scan_results_capture_adaptive_broker_obs
AFTER INSERT OR UPDATE OF diagnostics,final_score ON public.flow_scan_results
FOR EACH ROW EXECUTE FUNCTION public.flow_capture_broker_adaptive_score_observation();

CREATE FUNCTION public.flow_read_scan_results_run_v1(p_run_id uuid)
RETURNS TABLE(
  run_id uuid,ticker text,as_of_date date,final_score numeric,phase text,action text,
  evidence_tier text,evidence_coverage_pct numeric,real_money_state text,distribution_risk numeric,
  estimated_smart_money_cost numeric,premium_to_cost_pct numeric,entry_low numeric,entry_high numeric,
  invalidation numeric,tp1 numeric,tp2 numeric,components jsonb,diagnostics jsonb,guardrail_reason text,
  created_at timestamptz
)
LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path TO ''
AS $fn$
BEGIN
  IF EXISTS(SELECT 1 FROM public.flow_scan_results s WHERE s.run_id=p_run_id) THEN
    RETURN QUERY
    SELECT s.run_id,s.ticker,s.as_of_date,s.final_score,s.phase,s.action,s.evidence_tier,
      s.evidence_coverage_pct,s.real_money_state,s.distribution_risk,s.estimated_smart_money_cost,
      s.premium_to_cost_pct,s.entry_low,s.entry_high,s.invalidation,s.tp1,s.tp2,s.components,
      s.diagnostics,s.guardrail_reason,s.created_at
    FROM public.flow_scan_results s WHERE s.run_id=p_run_id ORDER BY s.ticker;
    RETURN;
  END IF;
  RETURN QUERY
  SELECT x.run_id,x.ticker,x.as_of_date,x.final_score,x.phase,x.action,x.evidence_tier,
    x.evidence_coverage_pct,x.real_money_state,x.distribution_risk,x.estimated_smart_money_cost,
    x.premium_to_cost_pct,x.entry_low,x.entry_high,x.invalidation,x.tp1,x.tp2,x.components,
    x.diagnostics,x.guardrail_reason,x.created_at
  FROM public.flow_scan_results_archive_v1 a
  CROSS JOIN LATERAL jsonb_to_recordset(a.payload) AS x(
    run_id uuid,ticker text,as_of_date date,final_score numeric,phase text,action text,
    evidence_tier text,evidence_coverage_pct numeric,real_money_state text,distribution_risk numeric,
    estimated_smart_money_cost numeric,premium_to_cost_pct numeric,entry_low numeric,entry_high numeric,
    invalidation numeric,tp1 numeric,tp2 numeric,components jsonb,diagnostics jsonb,guardrail_reason text,
    created_at timestamptz
  )
  WHERE a.run_id=p_run_id ORDER BY x.ticker;
END
$fn$;
REVOKE ALL ON FUNCTION public.flow_read_scan_results_run_v1(uuid) FROM public,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.flow_read_scan_results_run_v1(uuid) TO service_role;

-- Verify every archived run can be reconstructed to the same canonical row-hash set.
DO $do$
DECLARE v_bad bigint;
BEGIN
  WITH expanded AS (
    SELECT x.*
    FROM public.flow_scan_results_archive_v1 a
    CROSS JOIN LATERAL jsonb_to_recordset(a.payload) AS x(
      run_id uuid,ticker text,as_of_date date,final_score numeric,phase text,action text,
      evidence_tier text,evidence_coverage_pct numeric,real_money_state text,distribution_risk numeric,
      estimated_smart_money_cost numeric,premium_to_cost_pct numeric,entry_low numeric,entry_high numeric,
      invalidation numeric,tp1 numeric,tp2 numeric,components jsonb,diagnostics jsonb,guardrail_reason text,
      created_at timestamptz
    )
  ), row_hashes AS (
    SELECT e.run_id,
      encode(extensions.digest(convert_to(concat_ws('|',
        e.run_id::text,e.ticker,e.as_of_date::text,e.final_score::text,e.phase,e.action,e.evidence_tier,
        e.evidence_coverage_pct::text,e.real_money_state,coalesce(e.distribution_risk::text,''),
        coalesce(e.estimated_smart_money_cost::text,''),coalesce(e.premium_to_cost_pct::text,''),
        coalesce(e.entry_low::text,''),coalesce(e.entry_high::text,''),coalesce(e.invalidation::text,''),
        coalesce(e.tp1::text,''),coalesce(e.tp2::text,''),e.components::text,e.diagnostics::text,
        coalesce(e.guardrail_reason,''),e.created_at::text
      ),'UTF8'),'sha256'),'hex') row_sha
    FROM expanded e
  ), hashes AS (
    SELECT run_id,count(*)::integer row_count,
      encode(extensions.digest(convert_to(coalesce(string_agg(row_sha,'' ORDER BY row_sha),''),'UTF8'),'sha256'),'hex') logical_sha256
    FROM row_hashes GROUP BY run_id
  )
  SELECT count(*) INTO v_bad
  FROM public.flow_scan_results_archive_v1 a
  LEFT JOIN hashes h ON h.run_id=a.run_id
  WHERE h.run_id IS NULL OR h.row_count<>a.row_count OR h.logical_sha256<>a.logical_sha256;
  IF v_bad<>0 THEN
    RAISE EXCEPTION 'scan-results archive reconstruction verification failed for % runs',v_bad;
  END IF;
END
$do$;

CREATE TABLE public.flow_scan_results_compaction_manifest_v1(
  compaction_contract text PRIMARY KEY,
  before_rows bigint NOT NULL,
  hot_rows bigint NOT NULL,
  archived_rows bigint NOT NULL,
  before_runs bigint NOT NULL,
  hot_runs bigint NOT NULL,
  archived_runs bigint NOT NULL,
  before_bytes bigint NOT NULL,
  hot_bytes bigint NOT NULL,
  archive_bytes bigint NOT NULL,
  logical_sha256_before text NOT NULL CHECK(length(logical_sha256_before)=64),
  latest_rows_preserved boolean NOT NULL CHECK(latest_rows_preserved),
  details jsonb NOT NULL,
  compacted_at timestamptz NOT NULL DEFAULT statement_timestamp(),
  production_influence_enabled boolean NOT NULL DEFAULT false CHECK(production_influence_enabled=false)
);
ALTER TABLE public.flow_scan_results_compaction_manifest_v1 ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.flow_scan_results_compaction_manifest_v1 FROM public,anon,authenticated;
GRANT SELECT ON TABLE public.flow_scan_results_compaction_manifest_v1 TO service_role;

INSERT INTO public.flow_scan_results_compaction_manifest_v1(
  compaction_contract,before_rows,hot_rows,archived_rows,before_runs,hot_runs,archived_runs,
  before_bytes,hot_bytes,archive_bytes,logical_sha256_before,latest_rows_preserved,details
)
SELECT 'SCAN_RESULTS_SUPERSEDED_RUN_ARCHIVE_V1',s.before_rows,
  (SELECT count(*) FROM public.flow_scan_results),
  (SELECT coalesce(sum(row_count),0) FROM public.flow_scan_results_archive_v1),
  s.before_runs,(SELECT count(DISTINCT run_id) FROM public.flow_scan_results),
  (SELECT count(*) FROM public.flow_scan_results_archive_v1),s.before_bytes,
  pg_total_relation_size('public.flow_scan_results'::regclass),
  pg_total_relation_size('public.flow_scan_results_archive_v1'::regclass),s.logical_sha256,true,
  jsonb_build_object(
    'retention_policy','KEEP_ALL_RUNS_CONTRIBUTING_LATEST_TICKER_ASOF_PLUS_LATEST_3_TERMINAL_PLUS_NONTERMINAL',
    'archive_granularity','WHOLE_RUN',
    'archive_retrieval_function','flow_read_scan_results_run_v1',
    'historical_rows_deleted',false,
    'archived_rows_losslessly_reconstructable',true,
    'hot_table_remains_physical_and_upsert_compatible',true,
    'adaptive_broker_trigger_preserved',true,
    'no_scoring_ranking_or_promotion_change',true
  )
FROM flow_scan_results_compaction_stats_v1 s;

SELECT public.flow_refresh_storage_registry_v1();
UPDATE public.flow_storage_object_registry_v1
SET storage_class='HOT_OPERATIONAL',
    retention_requirement='KEEP_LATEST_TICKER_ASOF_CONTRIBUTOR_RUNS; ARCHIVE_SUPERSEDED_RUNS_LOSSLESSLY',
    removal_authorized=false
WHERE object_name='flow_scan_results';
UPDATE public.flow_storage_object_registry_v1
SET storage_class='COLD_RESEARCH',
    operational_dependency='NO_DIRECT_PRODUCTION_DEPENDENCY_PROVEN',
    research_dependency='HISTORICAL_SCAN_REPRODUCIBILITY',
    reproducibility_state='LOSSLESS_JSONB_RUN_ARCHIVE',
    retention_requirement='RETAIN_PERMANENTLY; READ_WITH flow_read_scan_results_run_v1',
    canonical_state='CANONICAL_ARCHIVE_EVIDENCE',
    derivation_state='ARCHIVED_FROM_CANONICAL_SCAN_RESULTS',
    removal_authorized=false
WHERE object_name='flow_scan_results_archive_v1';