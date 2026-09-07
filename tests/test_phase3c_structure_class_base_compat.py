from pathlib import Path


HOTFIX = Path(
    "supabase/migrations/20260907055000_phase3c_structure_class_base_compat.sql"
)
CLOSURE = Path(
    "supabase/migrations/20260907054000_phase3c_member_reliability_closure.sql"
)


def test_phase3c_base_builder_can_insert_before_structure_finalizer():
    sql = HOTFIX.read_text(encoding="utf-8")
    assert "alter column structure_class drop not null" in sql


def test_phase3c_finalizer_and_gate_still_require_structure_class():
    sql = CLOSURE.read_text(encoding="utf-8")
    assert "set structure_class=case" in sql
    assert "integrity.bad_structure_class_rows=0" in sql
    assert "structure_class='PAIR'" in sql
    assert "structure_class='CLUSTER'" in sql
    assert "structure_class='BROAD_CLUSTER'" in sql
