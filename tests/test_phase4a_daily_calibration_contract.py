from pathlib import Path


MIGRATION = Path(
    "supabase/migrations/20260907063000_phase4a_daily_evidence_calibration.sql"
)


def _sql() -> str:
    return MIGRATION.read_text(encoding="utf-8")


def test_daily_snapshot_runs_between_phase3c_and_calibration():
    sql = _sql()
    assert "flow-broker-adaptive-daily-evidence-snapshot" in sql
    assert "'21 11 * * 1-5'" in sql
    assert "flow_snapshot_broker_adaptive_daily_evidence" in sql


def test_daily_snapshot_requires_same_day_ready_phase3b_and_phase3c():
    sql = _sql()
    assert "PHASE3B_READY" in sql
    assert "PHASE3C_READY" in sql
    assert "b_date is distinct from p_as_of_date" in sql
    assert "c_date is distinct from p_as_of_date" in sql


def test_daily_formula_matches_runtime_abc_weights_and_activation_contract():
    sql = _sql()
    assert "0.25::numeric*case when phase3a_eligible" in sql
    assert "+ 0.50::numeric*case when phase3b_eligible" in sql
    assert "+ 0.25::numeric*case when phase3c_eligible" in sql
    assert "when 'BROAD_ACTIVE' then 1::numeric" in sql
    assert "when 'PARTIAL' then 0.50::numeric" in sql
    assert "else 0::numeric" in sql
    assert "advanced_broker_score>=65 then 'STRONG'" in sql
    assert "advanced_broker_score<=55 then 'CONTROL'" in sql


def test_calibration_uses_automatic_daily_observations_and_excludes_same_day():
    sql = _sql()
    assert "from public.flow_broker_adaptive_daily_observations" in sql
    assert "as_of_date < p_as_of_date" in sql
    assert "sample_source','AUTOMATIC_DAILY_3ABC_EVIDENCE'" in sql


def test_daily_outcomes_are_official_verified_and_trading_session_based():
    sql = _sql()
    assert "join public.flow_official_stock_summary s" in sql
    assert "and s.source_verified" in sql
    assert "row_number() over(" in sql
    assert "rn=6" in sql
    assert "rn=11" in sql
    assert "rn=21" in sql
