from pathlib import Path

SQL = Path('supabase/migrations/20260907151500_phase4c_transient_work_table.sql').read_text()


def test_transient_work_table_contract():
    assert 'create unlogged table public.flow_phase4c_work_base_v4' in SQL
    assert 'enable row level security' in SQL
    assert 'revoke all on public.flow_phase4c_work_base_v4 from public,anon,authenticated' in SQL
    assert "p_stability_window not in ('EARLY','MIDDLE','RECENT')" in SQL
    assert 'case when p.advanced_3abc_available then p.phase3a_score end' in SQL
    assert 'case when p.advanced_3abc_available then p.advanced_broker_score end' in SQL
    assert 'create temp view flow_phase4c_base as select * from public.flow_phase4c_work_base_v4' in SQL
    assert "and stability_window='ALL'" in SQL
    assert 'Expected five canonical ALL rows' in SQL
    assert "execute 'drop table if exists public.flow_phase4c_work_base_v4'" in SQL
    assert 'TRANSIENT_WORK_TABLE_NO_PERSISTENT_PANEL' in SQL
