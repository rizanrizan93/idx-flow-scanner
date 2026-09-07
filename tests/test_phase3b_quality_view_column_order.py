from pathlib import Path


MIGRATION = Path(
    "supabase/migrations/20260907050000_phase3b_consensus_reliability_closure.sql"
)


def _view_sql() -> str:
    sql = MIGRATION.read_text(encoding="utf-8")
    return sql.split("create or replace view public.flow_phase3b_quality_summary as", 1)[1]


def test_phase3b_replace_view_preserves_existing_column_prefix():
    view = _view_sql()
    # CREATE OR REPLACE VIEW must preserve the names/order of the existing 18 columns.
    assert "c.missing_stock_confirmation_rows,\n  a.failed_audit_rows,\n  case" in view
    assert "end phase3b_gate_state,\n  c.missing_reliability_rows," in view


def test_phase3b_reliability_diagnostics_are_appended_after_existing_gate_column():
    view = _view_sql()
    failed_pos = view.index("a.failed_audit_rows,\n  case")
    gate_pos = view.index("end phase3b_gate_state,")
    missing_pos = view.index("c.missing_reliability_rows,", gate_pos)
    violation_pos = view.index("c.reliability_violation_rows,", missing_pos)
    full_pos = view.index("c.full_breadth_reliability_violation_rows", violation_pos)
    assert failed_pos < gate_pos < missing_pos < violation_pos < full_pos
