from pathlib import Path


MIGRATION = Path("supabase/migrations/20260907103500_phase4c_direct_interaction_slices.sql")
SQL = MIGRATION.read_text(encoding="utf-8")


def test_interaction_slice_is_preregistered_and_bounded():
    assert "flow_factor_interaction_catalog_v4" in SQL
    assert "PREREGISTERED_10_INTERACTIONS_NO_CARTESIAN" in SQL
    assert "flow_refresh_interaction_slice_v4" in SQL


def test_interaction_slice_never_materializes_market_panel():
    assert "DIRECT_AGGREGATE_NO_PANEL_MATERIALIZATION" in SQL
    assert "create temp table" not in SQL.lower()
    assert "create table" not in SQL.lower()


def test_interaction_slice_uses_clean_targets_and_stability_windows():
    assert "clean_forward_return_" in SQL
    assert "clean_hit_up_10pct_20d" in SQL
    assert "clean_hit_up_20pct_60d" in SQL
    assert "clean_hit_up_50pct_120d" in SQL
    assert "flow_factor_stability_windows_v4" in SQL


def test_event_factors_do_not_use_meaningless_percentile_zero_split():
    assert "when %7$L='EVENT' then x.a>0" in SQL
    assert "when %8$L='EVENT' then x.b>0" in SQL


def test_missing_interaction_evidence_is_never_fabricated():
    assert "GENUINE_EVIDENCE_ABSENT_OR_IMMATURE_NOT_FABRICATED" in SQL
    assert "INSUFFICIENT_SAMPLE" in SQL
