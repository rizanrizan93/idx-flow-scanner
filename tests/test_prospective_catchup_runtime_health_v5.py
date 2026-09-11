from pathlib import Path


MIGRATION = Path("supabase/migrations/20260911065000_prospective_catchup_runtime_health_v5.sql")


def _sql() -> str:
    return MIGRATION.read_text(encoding="utf-8")


def test_catchup_is_bounded_and_same_session_lineage_gated():
    sql = _sql()
    assert "flow_prospective_lineage_status_v5" in sql
    assert "CATCHUP_WINDOW_EXCEEDED" in sql
    assert "LATE_FINANCIAL_BACKFILL_WOULD_LEAK" in sql
    assert "same_session_lineage_verified" in sql
    assert "e.ingested_at>=v_cutoff" in sql
    assert "v_stock<>900" in sql
    assert "v_residual<>900" in sql
    assert "v_sector<>900" in sql
    assert "OUTCOME_ALREADY_EXISTS_CAPTURE_IMMUTABLE" in sql


def test_current_session_keeps_v3_contract_and_historical_uses_v2_plus_finalize():
    sql = _sql()
    assert "return public.flow_capture_attribution_prospective_signals_v3(p_signal_date);" in sql
    assert "v_result:=public.flow_capture_attribution_prospective_signals_v2(p_signal_date);" in sql
    assert "flow_finalize_attribution_prospective_signal_v5" in sql
    assert "'production_influence_enabled',false" in sql


def test_auto_scheduler_selects_missing_sessions_instead_of_hardcoding_today():
    sql = _sql()
    assert "flow_select_prospective_session_v5" in sql
    assert "flow_run_prospective_auto_v5" in sql
    assert "order by m.snapshot_date" in sql
    assert "flow_run_prospective_auto_v5(''SIGNAL'')" in sql
    assert "flow_run_prospective_auto_v5(''STRUCTURED'')" in sql
    assert "flow_run_prospective_auto_v5(''THESIS'')" in sql
    assert "flow_run_prospective_auto_v5(''SHADOW'')" in sql
    assert "flow_run_prospective_auto_v5(''OUTCOMES'')" in sql


def test_cron_pit_capture_job_is_not_removed_by_catchup_migration():
    sql = _sql()
    assert "flow-attribution-pit-capture-retry-v4" not in sql.split("where jobname in(", 1)[1].split(") loop", 1)[0]
