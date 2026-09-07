from pathlib import Path


MIGRATION = Path("supabase/migrations/20260907090500_phase4c_sparse_runtime_closure.sql")
SQL = MIGRATION.read_text(encoding="utf-8")
LOWER = SQL.lower()


def test_sparse_advanced_history_is_explicit_not_fabricated():
    assert "flow_fill_factor_placeholders_v4" in SQL
    assert "GENUINE_EVIDENCE_ABSENT_OR_IMMATURE_NOT_FABRICATED" in SQL
    assert "sample_count,missingness_pct" in SQL
    assert "0,100.0" in SQL
    assert "INSUFFICIENT_SAMPLE" in SQL


def test_sparse_interactions_are_explicit_and_bounded():
    assert "flow_fill_interaction_placeholders_v4" in SQL
    assert "GENUINE_INTERACTION_EVIDENCE_ABSENT_OR_IMMATURE_NOT_FABRICATED" in SQL
    assert "cross join (values(20),(60),(120))" in LOWER
    assert "flow_factor_interaction_catalog_v4" in SQL


def test_stability_math_is_zero_safe():
    assert "nullif(w.valid_windows,0)" in SQL


def test_5d_regime_target_is_null_safe():
    assert "v_target_expr" in SQL
    assert "case when v_target_col is null then 'null::boolean'" in SQL


def test_runtime_closure_remains_security_invoker_only():
    assert "security definer" not in LOWER
    assert "security invoker" in LOWER
    assert "from public,anon,authenticated" in LOWER
