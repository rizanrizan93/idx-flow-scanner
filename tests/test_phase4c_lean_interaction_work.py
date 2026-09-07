from pathlib import Path

SQL = Path('supabase/migrations/20260907162500_phase4c_lean_interaction_work.sql').read_text()


def test_pre_registered_only_and_event_aware():
    assert 'flow_factor_interaction_catalog_v4' in SQL
    assert 'PREREGISTERED_10_INTERACTIONS_NO_CARTESIAN' in SQL
    assert "then x.a>0" in SQL
    assert "then x.b>0" in SQL
    assert 'percentile_cont(0.8)' in SQL
    assert "array[20,60,120]" in SQL
    assert "('ALL','EARLY','MIDDLE','RECENT')" in SQL
    assert 'BOUNDED_PREREGISTERED_LEAN_WORK_INTERACTION' in SQL


def test_private_invoker_contract():
    low = SQL.lower()
    assert 'security invoker' in low
    assert 'revoke all on function public.flow_refresh_interaction_window_work_v4(text,text) from public,anon,authenticated' in low
    assert 'grant execute on function public.flow_refresh_interaction_window_work_v4(text,text) to service_role' in low
