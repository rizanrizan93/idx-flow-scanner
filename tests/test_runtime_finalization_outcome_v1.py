from pathlib import Path


MIGRATION = Path("supabase/migrations/20260911075500_runtime_finalization_outcome_v1.sql")
MANAGED = Path("src/idx_flow_scanner/managed.py")


def test_outcome_refresh_deduplicates_run_invariant_work():
    sql = MIGRATION.read_text(encoding="utf-8").lower()
    assert "select distinct ticker,as_of_date from candidates" in sql
    assert "partition by d.ticker,d.as_of_date" in sql
    assert "from candidates c\n    join resolved r" in sql
    assert "is distinct from" in sql
    assert "partition by d.run_id" not in sql


def test_server_stale_reaper_recovers_persisted_partial_scan_truth():
    sql = MIGRATION.read_text(encoding="utf-8")
    assert "PERSISTED_RESULTS_PROVE_SCAN_COMPLETION" in sql
    assert "coalesce(r.attempted_count,0)>=r.universe_count" in sql
    assert "v_result_rows>=v_required_rows" in sql
    assert "COMPLETED_PARTIAL" in sql
    assert "SERVER_CRON_STALE_HEARTBEAT" in sql
    assert "stale_failure_reconciled" in sql


def test_client_stale_reaper_prefers_canonical_rpc_and_has_result_aware_fallback():
    source = MANAGED.read_text(encoding="utf-8")
    assert '"flow_reap_stale_scan_runs"' in source
    assert "_persisted_result_count" in source
    assert "attempted_count >= universe_count" in source
    assert "result_count >= required" in source
    assert "PERSISTED_RESULTS_PROVE_SCAN_COMPLETION" in source
    assert "CLIENT_STALE_HEARTBEAT" in source
