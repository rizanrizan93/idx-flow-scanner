from pathlib import Path

MIGRATION = Path('supabase/migrations/20260907193000_phase4d_lean_work_path.sql')


def test_phase4d_reuses_lean_transient_work_table():
    sql = MIGRATION.read_text(encoding='utf-8')
    assert "flow_phase4c_work_base_v4" in sql
    assert "LEAN_TRANSIENT_WORK_TABLE" in sql
    assert "flow_market_learning_labels_clean_v4c" not in sql
    assert "flow_phase4c_factor_source_v4" not in sql
    assert "security invoker" in sql.lower()
    assert "set search_path=pg_catalog,public" in sql
