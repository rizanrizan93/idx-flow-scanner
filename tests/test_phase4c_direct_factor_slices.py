from pathlib import Path


MIGRATION = Path("supabase/migrations/20260907101500_phase4c_direct_factor_slices.sql")
SQL = MIGRATION.read_text(encoding="utf-8")


def test_direct_factor_slice_never_materializes_market_panel():
    assert "flow_refresh_factor_slice_v4" in SQL
    assert "DIRECT_AGGREGATE_NO_PANEL_MATERIALIZATION" in SQL
    assert "create temp table" not in SQL.lower()
    assert "create table" not in SQL.lower()


def test_direct_slice_uses_clean_outcomes_and_market_memory_contract():
    assert "flow_market_learning_labels_clean_v4c" in SQL
    assert "MARKET_MEMORY_V4_1" in SQL
    assert "clean_forward_return_" in SQL
    assert "clean_mfe_" in SQL
    assert "clean_mae_" in SQL
    assert "clean_alpha_vs_ihsg_" in SQL
    assert "clean_alpha_vs_sector_" in SQL


def test_direct_slice_has_deciles_quintiles_and_nonlinear_detection():
    assert "ntile(10)" in SQL
    assert "ntile(5)" in SQL
    assert "factor_min" in SQL
    assert "factor_max" in SQL
    assert "MONOTONIC_UP" in SQL
    assert "MONOTONIC_DOWN" in SQL
    assert "INVERTED_U" in SQL
    assert "U_SHAPE" in SQL
    assert "TOP_BIN_CHASE_REVERSAL" in SQL


def test_direct_slice_preserves_stability_and_missing_evidence_semantics():
    for window in ("ALL", "EARLY", "MIDDLE", "RECENT"):
        assert window in SQL
    assert "GENUINE_EVIDENCE_ABSENT_OR_IMMATURE_NOT_FABRICATED" in SQL
    assert "INSUFFICIENT_SAMPLE" in SQL


def test_direct_slice_is_discovery_only():
    assert "production" not in SQL.lower() or "production scoring" not in SQL.lower()
    assert "flow_refresh_factor_slice_v4" in SQL
