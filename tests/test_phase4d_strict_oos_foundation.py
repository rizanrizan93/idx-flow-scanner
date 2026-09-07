from pathlib import Path

MIGRATION = Path('supabase/migrations/20260907190000_phase4d_strict_oos_foundation.sql')


def test_phase4d_strict_oos_contract():
    sql = MIGRATION.read_text(encoding='utf-8')
    assert 'PURGED_EXPANDING_WALKFORWARD_V4D_1' in sql
    assert "array[5,20,60,120]" in sql
    assert '60+' in sql
    assert 'train_selected' in sql
    assert 'train_fdr_q_value' in sql
    assert 'signed_oos_effect_pct' in sql
    assert 'INSUFFICIENT_STRICT_OOS_HISTORY' in sql
    assert 'PHASE4D_HISTORICAL_OOS_READY' in sql
    assert 'production_scoring_changed' in sql
    assert 'production_eligible boolean not null default false' in sql
    assert 'PREREGISTERED_10_INTERACTIONS_NO_CARTESIAN' in sql
    assert 'security_invoker=true' in sql
    assert 'revoke all on public.flow_phase4d_factor_oos_v4 from public,anon,authenticated' in sql


def test_phase4d_does_not_modify_production_scoring_code():
    sql = MIGRATION.read_text(encoding='utf-8')
    forbidden = ('flow_scan_results set final_score', 'update public.flow_scan_results', 'alter table public.flow_scan_results')
    assert not any(token in sql.lower() for token in forbidden)
