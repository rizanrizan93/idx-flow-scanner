from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MIGRATION = ROOT / "supabase/migrations/20260910055433_scan_results_run_archive_v1.sql"


def _sql() -> str:
    return MIGRATION.read_text(encoding="utf-8")


def test_archive_is_fail_closed_before_source_rewrite() -> None:
    sql = _sql()
    for marker in (
        "expected physical table",
        "incoming FK references exist",
        "trigger contract drift",
        "target or legacy object already exists",
        "insufficient storage gain",
    ):
        assert marker in sql


def test_hot_retention_preserves_every_latest_ticker_asof_contributor() -> None:
    sql = _sql()
    assert "SELECT DISTINCT ON (ticker,as_of_date)" in sql
    assert "ORDER BY ticker,as_of_date,created_at DESC,run_id DESC" in sql
    assert "latest_contributors" in sql
    assert "latest_terminal" in sql
    assert "LIMIT 3" in sql
    assert "nonterminal" in sql
    assert "latest ticker/date rows would be lost from hot table" in sql


def test_archive_is_whole_run_lossless_and_hash_verified() -> None:
    sql = _sql()
    assert "SCAN_RESULTS_SUPERSEDED_RUN_ARCHIVE_V1" in sql
    assert "jsonb_agg(to_jsonb(prepared)-'row_sha' ORDER BY ticker) payload" in sql
    assert "payload_sha256" in sql
    assert "logical_sha256" in sql
    assert "jsonb_array_length(payload)<>row_count" in sql
    assert "archive reconstruction verification failed" in sql


def test_hot_table_preserves_physical_upsert_contract_and_trigger() -> None:
    sql = _sql()
    assert "CREATE TABLE public.flow_scan_results_hot_v1(" in sql
    assert "PRIMARY KEY(run_id,ticker)" in sql
    assert "REFERENCES public.flow_scan_runs(id) ON DELETE CASCADE" in sql
    assert "ALTER TABLE public.flow_scan_results_hot_v1 RENAME TO flow_scan_results" in sql
    assert "CREATE TRIGGER flow_scan_results_capture_adaptive_broker_obs" in sql
    assert "flow_capture_broker_adaptive_score_observation()" in sql
    assert "DROP TABLE public.flow_scan_results_legacy_v1 RESTRICT" in sql
    assert "CASCADE" not in sql.split("DROP TABLE public.flow_scan_results_legacy_v1", 1)[1][:80]


def test_archived_runs_remain_queryable_without_rehydration_side_effects() -> None:
    sql = _sql()
    assert "CREATE FUNCTION public.flow_read_scan_results_run_v1(p_run_id uuid)" in sql
    assert "SECURITY INVOKER" in sql
    assert "jsonb_to_recordset(a.payload)" in sql
    assert "REVOKE ALL ON FUNCTION public.flow_read_scan_results_run_v1(uuid) FROM public,anon,authenticated" in sql
    assert "GRANT EXECUTE ON FUNCTION public.flow_read_scan_results_run_v1(uuid) TO service_role" in sql


def test_security_retention_and_production_influence_remain_fail_closed() -> None:
    sql = _sql()
    assert "ENABLE ROW LEVEL SECURITY" in sql
    assert "FROM public,anon,authenticated" in sql
    assert "production_influence_enabled boolean NOT NULL DEFAULT false" in sql
    assert "CHECK(production_influence_enabled=false)" in sql
    assert "removal_authorized=false" in sql
    assert "no_scoring_ranking_or_promotion_change" in sql
