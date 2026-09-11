from pathlib import Path


MIGRATION = Path("supabase/migrations/20260911072500_prospective_interaction_recompute_v5_1.sql")


def test_interaction_recompute_uses_unnest_equality_join_not_any_array_join():
    sql = MIGRATION.read_text(encoding="utf-8")
    assert "cross join lateral unnest(c.component_ids)" in sql
    assert "d.driver_id=cr.driver_id" in sql
    assert "d.driver_id=any(c.component_ids)" not in sql.lower()
    assert "UNNEST_EQUALITY_JOIN_V5_1" in sql


def test_current_and_historical_sessions_share_optimized_finalizer():
    sql = MIGRATION.read_text(encoding="utf-8")
    assert "flow_capture_attribution_prospective_signals_v3" not in sql
    assert "flow_capture_attribution_prospective_signals_v2(p_signal_date)" in sql
    assert "flow_finalize_attribution_prospective_signal_v5" in sql
    assert "CURRENT_EOD" in sql
    assert "PIT_CATCHUP" in sql
    assert "'production_influence_enabled',false" in sql
