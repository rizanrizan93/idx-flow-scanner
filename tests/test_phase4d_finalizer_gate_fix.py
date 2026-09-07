from pathlib import Path

MIGRATION = Path('supabase/migrations/20260907194500_phase4d_finalizer_gate_fix.sql')


def test_finalizer_uses_physical_phase4c_snapshot_columns():
    sql = MIGRATION.read_text(encoding='utf-8')
    assert "discovery_state='COMPLETE'" in sql
    assert 'source_verified' in sql
    assert 'not production_scoring_changed' in sql
    assert "where phase4c_gate_state='PHASE4C_READY'" not in sql
    assert "PHASE4D_HISTORICAL_OOS_READY" in sql
    assert "production_scoring_changed',false" in sql
