from pathlib import Path

SQL = Path('supabase/migrations/20260907171000_phase4c_runtime_work_cleanup.sql').read_text().lower()


def test_runtime_work_table_is_dropped_after_closure():
    assert 'drop table if exists public.flow_phase4c_work_base_v4' in SQL
    assert 'no duplicated market-learning panel' in SQL
