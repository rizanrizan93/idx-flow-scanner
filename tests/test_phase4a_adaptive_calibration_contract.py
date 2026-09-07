from pathlib import Path


MIGRATION = Path(
    "supabase/migrations/20260907062000_phase4a_adaptive_production_broker_scoring.sql"
)


def _sql() -> str:
    return MIGRATION.read_text(encoding="utf-8")


def test_adaptive_budget_and_initial_weight_are_bounded():
    sql = _sql()
    assert "'ADVANCED_BROKER_ABC_V1',0.08,0.02,0.00,0.06,0.005,'BOOTSTRAP'" in sql
    assert "advanced_weight between min_advanced_weight and max_advanced_weight" in sql
    assert "applied_v1_weight + applied_advanced_weight <= family_budget + 0.000001" in sql


def test_calibration_is_strictly_forward_and_has_cooldown():
    sql = _sql()
    assert "as_of_date < p_as_of_date" in sql
    assert "as_of_date >= p_as_of_date - 180" in sql
    assert "p_as_of_date-st.last_weight_change_date>=7" in sql
    assert "strong_n5 < st.min_strong_5d or control_n5 < st.min_control_5d" in sql


def test_outcomes_use_verified_official_stock_summary_only():
    sql = _sql()
    assert "join public.flow_official_stock_summary s" in sql
    assert "and s.source_verified" in sql
    assert "return_5d" in sql and "return_10d" in sql and "return_20d" in sql
    assert "mfe_20d" in sql and "mae_20d" in sql


def test_runtime_observation_trigger_is_immutable_at_signal_time():
    sql = _sql()
    assert "flow_scan_results_capture_adaptive_broker_obs" in sql
    assert "evidence_date <> new.as_of_date" in sql
    assert "advanced_broker_score" in sql
    assert "base_score_pre_broker_family" in sql


def test_daily_calibration_runs_after_phase3c():
    sql = _sql()
    assert "flow-broker-adaptive-calibration-daily" in sql
    assert "'22 11 * * 1-5'" in sql
    assert "flow_recalibrate_broker_adaptive_scoring" in sql
