from pathlib import Path

SQL = Path('supabase/migrations/20260907160500_phase4c_pvalue_underflow_guard.sql').read_text()


def test_pvalue_underflow_guard_contract():
    assert 'z>=37.0' in SQL
    assert 'greatest(-700.0,-0.5*z*z)' in SQL
    assert 'returns double precision' in SQL.lower()
    assert 'immutable' in SQL.lower()
    assert 'parallel safe' in SQL.lower()
