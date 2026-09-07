from pathlib import Path


MIGRATION = Path(
    "supabase/migrations/20260907040000_phase3a_broker_ticker_affinity_shadow.sql"
)


def _sql() -> str:
    return MIGRATION.read_text(encoding="utf-8")


def test_phase3a_is_residual_event_conditioned_not_raw_cartesian_correlation():
    sql = _sql()
    assert "flow_broker_behavior_features_v2" in sql
    assert "flow_stock_residual_activity_v2" in sql
    assert "residual_activity_z>=1.5" in sql
    assert "stock_residual_activity_z>=1.0" in sql
    assert "corr(" not in sql.lower()
    assert "coevents" in sql
    assert "expected_coevent_count" in sql
    assert "affinity_lift" in sql
    assert "affinity_z" in sql


def test_phase3a_lags_are_trading_session_lags_zero_one_two_five():
    sql = _sql()
    assert "lag_sessions in (0,1,2,5)" in sql
    assert "array[0,1,2,5]" in sql
    assert "(s.seq-lag_n)" in sql
    assert "s.seq>lag_n" in sql


def test_phase3a_is_fail_closed_on_mature_and_full_coverage():
    sql = _sql()
    assert "feature_quality_state='MATURE'" in sql
    assert "having count(*)=eligible_n" in sql
    assert "having count(*)>=12" in sql
    assert "having count(*)>=10" in sql
    assert "having count(*)>=5" in sql
    assert "lift_all>=1.5" in sql
    assert "z_all>=2.5" in sql
    assert "excess_hit>=10" in sql


def test_phase3a_preserves_non_directional_broker_semantics():
    sql = _sql()
    assert "CO_ACTIVITY_AFFINITY_NOT_BUY_SELL" in sql
    assert "must never" in sql
    assert "per-ticker buy/sell direction" in sql
    assert "association_semantics" in sql


def test_phase3a_stability_uses_prior_and_recent_halves():
    sql = _sql()
    assert "first_half_lift" in sql
    assert "second_half_lift" in sql
    assert "first_half_z" in sql
    assert "second_half_z" in sql
    assert "STABLE" in sql
    assert "RECENT_STRENGTHENING" in sql
    assert "DECAYING" in sql
    assert "MIXED" in sql


def test_phase3a_is_shadow_and_does_not_mutate_production_scoring():
    sql = _sql()
    assert "SHADOW" in sql
    assert "no_production_scoring_change" in sql
    assert "final_score" not in sql.replace("-- This is a SHADOW research layer. It does NOT change final_score, production scoring,", "")
    assert "BROKER_BEHAVIOR_OVERLAY_WEIGHT" not in sql
    assert "production_authorized" not in sql
    assert "execution_ready" not in sql.replace("-- execution authorization, execution-ready semantics, or the existing broker overlay.", "")


def test_phase3a_tables_are_private_flow_namespace():
    sql = _sql()
    assert "flow_broker_ticker_affinity_v3" in sql
    assert "flow_broker_ticker_affinity_snapshot_v3" in sql
    assert "enable row level security" in sql
    assert "from public, anon, authenticated" in sql
    assert "to service_role" in sql


def test_phase3a_quality_gate_requires_current_four_lag_snapshot():
    sql = _sql()
    assert "flow_phase3a_quality_summary" in sql
    assert "PHASE3A_READY" in sql
    assert "PHASE3A_NOT_READY" in sql
    assert "s.as_of_date=p.last_residual_date" in sql
    assert "s.lag_count=4" in sql
    assert "s.min_eligible_brokers>=80" in sql
    assert "s.min_eligible_tickers>=500" in sql
    assert "m.bad_semantics_rows=0" in sql


def test_phase3a_daily_refresh_runs_after_phase2_residual():
    sql = _sql()
    assert "flow-broker-ticker-affinity-v3-shadow-daily" in sql
    assert "16 11 * * 1-5" in sql
    assert "flow_refresh_broker_ticker_affinity_v3" in sql
    assert ",200);" in sql
