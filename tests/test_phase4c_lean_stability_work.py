from pathlib import Path

SQL = Path('supabase/migrations/20260907154500_phase4c_lean_stability_work.sql').read_text()


def test_lean_stability_work_contract():
    assert 'LEAN_TRANSIENT_UNLOGGED_DROP_AFTER_CLOSURE' in SQL
    assert 'clean_forward_return_250d_pct' in SQL
    assert 'clean_mfe_5d_pct' not in SQL
    assert "set work_mem='24MB'" in SQL
    assert "p_stability_window not in ('EARLY','MIDDLE','RECENT')" in SQL
    assert 'percentile_cont(0.10)' in SQL
    assert 'percentile_cont(0.90)' in SQL
    assert 'LEAKAGE_SAFE_CLEAN_LABEL_LEAN_WORK_STABILITY' in SQL
    assert 'GENUINE_EVIDENCE_ABSENT_OR_IMMATURE_NOT_FABRICATED' in SQL
    assert 'case when p.advanced_3abc_available then p.phase3a_score end' in SQL
