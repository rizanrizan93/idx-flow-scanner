from pathlib import Path


MIGRATION = Path("supabase/migrations/20260907104500_phase4c_direct_regime_slices.sql")
SQL = MIGRATION.read_text(encoding="utf-8")


def test_regime_dimensions_are_explicit_and_bounded():
    for name in ("MARKET_REGIME", "SECTOR", "VOLATILITY_BUCKET", "LIQUIDITY_BUCKET"):
        assert name in SQL
    assert "flow_refresh_regime_slice_v4" in SQL


def test_sector_history_limitation_is_not_hidden():
    assert "CURRENT_REGISTRY_CLASSIFICATION_NOT_HISTORICAL" in SQL


def test_regime_slice_never_materializes_market_panel():
    assert "DIRECT_AGGREGATE_NO_PANEL_MATERIALIZATION" in SQL
    assert "create temp table" not in SQL.lower()
    assert "create table" not in SQL.lower()


def test_regime_slice_uses_clean_outcomes():
    assert "clean_forward_return_" in SQL
    assert "clean_hit_up_10pct_20d" in SQL
    assert "clean_hit_up_100pct_250d" in SQL


def test_challenger_requires_robust_signal_and_regime_breadth():
    assert "ROBUST_DISCOVERY_SIGNAL" in SQL
    assert "s.groups>=6" in SQL
    assert "s.agreement>=60.0" in SQL
    assert "flow_finalize_regime_eligibility_v4" in SQL
