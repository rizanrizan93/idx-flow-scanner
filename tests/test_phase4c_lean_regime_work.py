from pathlib import Path

SQL = Path('supabase/migrations/20260907164000_phase4c_lean_regime_work.sql').read_text()


def test_four_regime_dimensions_and_semantics():
    assert "array['MARKET_REGIME','SECTOR','VOLATILITY_BUCKET','LIQUIDITY_BUCKET']" in SQL
    assert 'CURRENT_REGISTRY_CLASSIFICATION_NOT_HISTORICAL' in SQL
    assert 'AS_OF_DERIVED_LIQUIDITY_QUINTILE' in SQL
    assert 'LEAN_WORK_REGIME_CONDITIONING_NO_RAW_REJOIN' in SQL
    assert "then case when factor_value>0 then 5 else 1 end" in SQL
    assert 'ntile(5) over(partition by regime_value order by factor_value)' in SQL


def test_private_invoker_contract():
    low = SQL.lower()
    assert 'security invoker' in low
    assert 'revoke all on function public.flow_refresh_regime_factor_work_v4(text,integer) from public,anon,authenticated' in low
    assert 'grant execute on function public.flow_refresh_regime_factor_work_v4(text,integer) to service_role' in low
