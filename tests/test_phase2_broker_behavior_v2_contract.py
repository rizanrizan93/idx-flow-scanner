from pathlib import Path


MIGRATION = Path(
    "supabase/migrations/20260907023000_phase2_broker_behavior_v2_shadow.sql"
)


def _sql() -> str:
    return MIGRATION.read_text(encoding="utf-8")


def test_phase2_v2_is_shadow_and_official_only():
    sql = _sql()
    assert "flow_broker_behavior_features_v2" in sql
    assert "flow_broker_market_regime_v2" in sql
    assert "IDX_OFFICIAL_BROKER_SUMMARY" in sql
    assert "SHADOW_DERIVED_FROM_VERIFIED_OFFICIAL_IDX_BROKER_SUMMARY" in sql
    assert "training_quality_state='PASS'" in sql
    assert "no_production_scoring_change" in sql


def test_phase2_v2_has_required_per_broker_features():
    sql = _sql()
    for field in (
        "activity_share_pct",
        "value_z60",
        "volume_z60",
        "frequency_z60",
        "activity_share_z60",
        "rank_momentum_5",
        "avg_ticket_value",
        "avg_ticket_z60",
        "avg_size_shares",
        "avg_size_z60",
        "high_activity_days_5",
        "high_activity_streak",
        "persistence_5_pct",
        "stability_score",
        "activity_shock_z",
        "activity_shock_score",
        "residual_activity_z",
    ):
        assert field in sql


def test_phase2_robust_baseline_is_past_only_and_clipped():
    sql = _sql()
    assert "flow_robust_z_from_history" in sql
    assert "p0.trade_date<p_date" in sql
    assert "limit 60" in sql.lower()
    assert "-8::numeric" in sql
    assert "8::numeric" in sql
    assert "1.4826::numeric" in sql
    assert "baseline_sessions>=20" in sql
    assert "baseline_sessions>=60" in sql


def test_phase2_market_regime_contains_factual_breadth_concentration_and_entropy():
    sql = _sql()
    for field in (
        "top10_value_share_pct",
        "value_hhi_10k",
        "value_entropy_pct",
        "concentration_z60",
        "entropy_z60",
        "activity_breadth_pct",
        "shock_broker_count",
        "rank_riser_count",
        "market_activity_intensity_z",
    ):
        assert field in sql
    for label in (
        "BROAD_ACTIVITY_EXPANSION",
        "CONCENTRATED_ACTIVITY",
        "BROKER_EXPANSION",
        "LOW_PARTICIPATION",
        "ACTIVITY_SHOCK",
    ):
        assert label in sql


def test_phase2_backfill_and_gate_are_bounded():
    sql = _sql()
    assert "flow_backfill_broker_behavior_v2" in sql
    assert "backfill window exceeds 31 calendar days" in sql
    assert "flow_phase2ab_quality_summary" in sql
    assert "f.feature_sessions>=250" in sql
    assert "r.ready_regime_sessions>=240" in sql
    assert "r.mature_regime_sessions>=190" in sql
    assert "a.failed_audit_rows=0" in sql
    assert "PHASE2AB_READY" in sql


def test_phase2_daily_schedule_runs_after_official_index_refresh():
    sql = _sql()
    assert "flow-broker-behavior-v2-shadow-daily" in sql
    assert "10 11 * * 1-5" in sql


def test_phase2_does_not_touch_production_scoring_or_execution():
    sql = _sql()
    assert "final_score" not in sql
    assert "BROKER_BEHAVIOR_OVERLAY_WEIGHT" not in sql
    assert "production_authorized" not in sql
    assert "execution_ready" not in sql
