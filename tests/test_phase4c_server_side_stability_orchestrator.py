from pathlib import Path

SQL = Path('supabase/migrations/20260907144500_phase4c_server_side_stability_orchestrator.sql').read_text()


def test_phase4c_stability_orchestrator_is_backend_temp_only_and_private():
    assert 'flow_run_phase4c_stability_family_v4' in SQL
    assert "security invoker" in SQL.lower()
    assert "set statement_timeout='0'" in SQL.lower()
    assert 'flow_prepare_phase4c_temp_family_v4' in SQL
    assert 'flow_refresh_factor_discovery_one_v4' in SQL
    assert 'flow_phase4c_all_backup' in SQL
    assert "stability_window='ALL'" in SQL
    assert 'insert into public.flow_factor_discovery_v4\n  select * from pg_temp.flow_phase4c_all_backup' in SQL
    assert "BACKEND_SESSION_TEMP_ONLY_NO_PERSISTENT_PANEL" in SQL
    assert 'revoke all on function public.flow_run_phase4c_stability_family_v4(text) from public,anon,authenticated' in SQL
    assert 'grant execute on function public.flow_run_phase4c_stability_family_v4(text) to service_role' in SQL


def test_phase4c_stability_orchestrator_rejects_sparse_families():
    assert "p_factor_family not in ('PRICE_MOMENTUM','FLOW_LIQUIDITY','MARKET_REGIME','RISK_ACTION')" in SQL
    assert 'ADVANCED_BROKER' not in SQL.split("p_factor_family not in", 1)[1].split('then', 1)[0]
    assert 'OWNERSHIP' not in SQL.split("p_factor_family not in", 1)[1].split('then', 1)[0]
