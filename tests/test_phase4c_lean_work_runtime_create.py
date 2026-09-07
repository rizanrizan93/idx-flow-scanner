from pathlib import Path

SQL = Path('supabase/migrations/20260907155500_phase4c_lean_work_runtime_create.sql').read_text()


def test_runtime_staging_is_private_and_lean():
    assert 'create unlogged table public.flow_phase4c_work_base_v4' in SQL
    assert 'clean_forward_return_250d_pct' in SQL
    assert 'clean_mfe_5d_pct' not in SQL
    assert 'enable row level security' in SQL
    assert 'revoke all on public.flow_phase4c_work_base_v4 from public,anon,authenticated' in SQL
    assert 'RUNTIME_ONLY' in SQL
    assert 'case when p.advanced_3abc_available then p.advanced_broker_score end' in SQL
