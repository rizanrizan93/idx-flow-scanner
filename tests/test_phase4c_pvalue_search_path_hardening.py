from pathlib import Path

SQL = Path('supabase/migrations/20260907172000_phase4c_pvalue_search_path_hardening.sql').read_text().lower()


def test_search_path_and_acl_are_locked():
    assert 'set search_path=pg_catalog,public' in SQL
    assert 'revoke all on function public.flow_normal_two_sided_p_v4(double precision) from public,anon,authenticated' in SQL
    assert 'grant execute on function public.flow_normal_two_sided_p_v4(double precision) to service_role' in SQL
    assert 'security definer' not in SQL
