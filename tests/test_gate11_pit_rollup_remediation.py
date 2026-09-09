from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MIG = ROOT / "supabase" / "migrations" / "20260909022532_restore_gate11_pit_rollups_v1.sql"


def sql() -> str:
    assert MIG.exists()
    return MIG.read_text(encoding="utf-8")


def test_remediation_restores_frozen_pit_safe_rollups():
    text = sql()
    for token in (
        "FLOW_PERSISTENCE_20D",
        "FLOW_ACCELERATION_5V20",
        "LIQ_ADTV20",
        "MKT_BREADTH_20D",
        "MKT_RISK_ON_CONTEXT",
        "PV_VOLUME_EXPANSION",
        "PV_VOLATILITY_EXPANSION",
        "PV_VOLATILITY_CONTRACTION",
        "TECH_BOS_20D",
        "TECH_CHOCH",
        "TECH_DISPLACEMENT",
        "TECH_FVG_BULLISH",
        "TECH_LIQUIDITY_SWEEP_20D",
        "TECH_REVERSAL_ACCUMULATION",
        "TECH_TREND_STRUCTURE",
    ):
        assert token in text


def test_rollups_use_only_trailing_or_same_signal_date_information():
    text = sql().lower()
    assert "rows between 20 preceding and current row" in text
    assert "rows between 19 preceding and current row" in text
    assert "rows between 20 preceding and 1 preceding" in text
    assert "rows between 5 preceding and 1 preceding" in text
    assert "lag(s.high,2)" in text
    assert "percent_rank() over(partition by as_of_date order by return_20d_pct)" in text
    assert "f.signal_date=m.as_of_date" in text
    assert "b.max_d" in text
    assert "following" not in text


def test_technical_formulas_match_gate10_contract():
    text = sql().lower()
    assert "(close>prior_high20)::int" in text
    assert "(return_20d_pct<0 and close>prior_high5)::int" in text
    assert "return_1d_pct/nullif(return_sd20,0)" in text
    assert "(low>high_lag2)::int" in text
    assert "(low<prior_low20 and close>prior_low20)::int" in text
    assert "foreign_net_volume_pct>0" in text
    assert "(return20_xsec_rank+(close>=close_avg20)::int)/2.0" in text


def test_refresh_wrapper_makes_remediation_persistent():
    text = sql().lower()
    assert "rename to flow_refresh_driver_panel_reuse_only_v1" in text
    assert "flow_restore_gate11_pit_rollups_v1" in text
    assert "flow_refresh_driver_panel_reuse_only_v1()" in text
    assert "pit_rollup_restore" in text


def test_remediation_is_secured_and_production_isolated():
    text = sql().lower()
    assert text.count("security invoker") >= 2
    assert text.count("set search_path=''" ) >= 2
    assert "sector_membership_repaired',false" in text
    assert "production_influence_enabled',false" in text
    for token in (
        "update public.flow_scan_results",
        "insert into public.flow_scan_results",
        "delete from public.flow_scan_results",
        "update public.flow_phase4e",
        "insert into public.flow_phase4e",
    ):
        assert token not in text
