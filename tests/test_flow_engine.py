from __future__ import annotations

import numpy as np
import pandas as pd

from idx_flow_scanner.config import ScannerConfig
from idx_flow_scanner.data import normalize_broker_summary
from idx_flow_scanner.engines.flow import compute_broker_features, compute_official_foreign_features
from idx_flow_scanner.engines.scoring import final_score
from idx_flow_scanner.engines.smc import compute_smc_features, is_valid_idx_price
from idx_flow_scanner.pipeline import scan_one


def prices(n=100, start=100.0):
    dates = pd.bdate_range("2026-01-02", periods=n)
    close = start + np.linspace(0, 8, n) + np.sin(np.arange(n)/5)
    return pd.DataFrame({"date":dates,"open":close-.5,"high":close+1,"low":close-1,"close":close,"volume":np.full(n,2_000_000)})


def broker_rows(dates, accumulating=True, verified=True):
    """Balanced full-market-like broker sample: every buy has an opposing seller."""
    rows=[]
    buyers=[("YP",1.0),("BK",.7),("AK",.5)]
    sellers=[("NI",1.0),("PD",.7),("CC",.5)]
    for d in dates:
        for code,scale in buyers:
            buy=10_000_000*scale if accumulating else 3_000_000*scale
            sell=3_000_000*scale if accumulating else 10_000_000*scale
            bvol=100_000*scale if accumulating else 30_000*scale
            svol=30_000*scale if accumulating else 100_000*scale
            rows.append({"ticker":"TEST","trade_date":d,"broker_code":code,"buy_value":buy,"sell_value":sell,"buy_volume":bvol,"sell_volume":svol,"buy_avg":104.0,"sell_avg":105.0,"source":"TEST_DIRECT","source_verified":verified,"direct_broker_eligible":verified})
        for code,scale in sellers:
            buy=3_000_000*scale if accumulating else 10_000_000*scale
            sell=10_000_000*scale if accumulating else 3_000_000*scale
            bvol=30_000*scale if accumulating else 100_000*scale
            svol=100_000*scale if accumulating else 30_000*scale
            rows.append({"ticker":"TEST","trade_date":d,"broker_code":code,"buy_value":buy,"sell_value":sell,"buy_volume":bvol,"sell_volume":svol,"buy_avg":104.0,"sell_avg":105.0,"source":"TEST_DIRECT","source_verified":verified,"direct_broker_eligible":verified})
    return normalize_broker_summary(pd.DataFrame(rows))


def test_direct_accumulation_scores_above_no_data():
    px=prices(); br=broker_rows(px["date"].tail(60)); feat=compute_broker_features(br,px,ScannerConfig())
    assert feat["coverage_pct"]==100.0
    assert feat["broker_balance_error_pct"] < 1e-9
    assert feat["accumulation_score"]>65
    assert feat["estimated_smart_money_cost"] is not None


def test_no_broker_data_is_never_real_money_eligible():
    result=scan_one("TEST",prices(),pd.DataFrame(),ScannerConfig())
    assert result.evidence_tier=="PRICE_PROXY"; assert result.real_money_state=="GUARDED"; assert result.action=="RESEARCH_ONLY"


def test_direct_broker_data_can_pass_evidence_tier():
    px=prices(); br=broker_rows(px["date"].tail(60)); result=scan_one("TEST",px,br,ScannerConfig())
    assert result.evidence_tier=="BROKER_DIRECT"; assert result.evidence_coverage_pct==100.0
    assert result.diagnostics["broker_verified_source_pct"] == 100.0


def test_complete_but_unverified_broker_file_cannot_be_broker_direct():
    px=prices(); br=broker_rows(px["date"].tail(60), verified=False)
    result=scan_one("TEST",px,br,ScannerConfig())
    assert result.evidence_tier=="PRICE_PROXY"
    assert result.real_money_state=="GUARDED"
    assert "verified_source=0.0%" in result.guardrail_reason


def test_partial_unbalanced_broker_file_cannot_be_broker_direct():
    px=prices(); br=broker_rows(px["date"].tail(60))
    br=br[br["broker_code"].isin(["YP","BK","AK"])].copy()
    result=scan_one("TEST",px,br,ScannerConfig())
    assert result.evidence_tier=="PRICE_PROXY"
    assert result.real_money_state=="GUARDED"
    assert "integrity gate failed" in result.guardrail_reason


def test_prior_accumulators_reversing_to_sell_triggers_distribution_warning():
    px=prices(); dates=list(px["date"].tail(60)); rows=[]
    buyers=[("YP",1.0),("BK",0.8),("AK",0.6)]
    sellers=[("NI",1.0),("PD",0.8),("CC",0.6)]
    for i,d in enumerate(dates):
        reversal=i>=55
        for code,scale in buyers:
            if reversal: buy,sell,bvol,svol=1_000_000*scale,18_000_000*scale,10_000*scale,180_000*scale
            else: buy,sell,bvol,svol=10_000_000*scale,2_000_000*scale,100_000*scale,20_000*scale
            rows.append({"ticker":"TEST","trade_date":d,"broker_code":code,"buy_value":buy,"sell_value":sell,"buy_volume":bvol,"sell_volume":svol,"buy_avg":104.0,"sell_avg":108.0,"source":"TEST_DIRECT","source_verified":True,"direct_broker_eligible":True})
        for code,scale in sellers:
            if reversal: buy,sell,bvol,svol=18_000_000*scale,1_000_000*scale,180_000*scale,10_000*scale
            else: buy,sell,bvol,svol=2_000_000*scale,10_000_000*scale,20_000*scale,100_000*scale
            rows.append({"ticker":"TEST","trade_date":d,"broker_code":code,"buy_value":buy,"sell_value":sell,"buy_volume":bvol,"sell_volume":svol,"buy_avg":104.0,"sell_avg":108.0,"source":"TEST_DIRECT","source_verified":True,"direct_broker_eligible":True})
    br=normalize_broker_summary(pd.DataFrame(rows)); result=scan_one("TEST",px,br,ScannerConfig())
    assert result.evidence_tier=="BROKER_DIRECT"
    assert result.distribution_risk>=65; assert result.phase=="DISTRIBUTION"; assert result.action=="REDUCE_AVOID"; assert result.real_money_state=="GUARDED"


def test_future_broker_rows_cannot_upgrade_historical_scan():
    px = prices()
    future_dates = pd.bdate_range(px["date"].max() + pd.Timedelta(days=1), periods=20)
    future_broker = broker_rows(future_dates, verified=True)
    result = scan_one("TEST", px, future_broker, ScannerConfig())

    assert result.evidence_tier == "PRICE_PROXY"
    assert result.real_money_state == "GUARDED"
    assert result.diagnostics["broker_future_rows_filtered"] == len(future_broker)
    assert result.diagnostics["broker_days"] == 0


def test_future_foreign_rows_do_not_enter_historical_features():
    px = prices()
    future_dates = pd.bdate_range(px["date"].max() + pd.Timedelta(days=1), periods=20)
    flow = pd.DataFrame({
        "ticker": ["TEST"] * len(future_dates),
        "trade_date": future_dates,
        "foreign_buy": [2_000_000] * len(future_dates),
        "foreign_sell": [100_000] * len(future_dates),
        "volume": [10_000_000] * len(future_dates),
        "source": ["IDX_OFFICIAL_STOCK_SUMMARY"] * len(future_dates),
    })
    feat = compute_official_foreign_features(flow, px)
    assert feat["foreign_evidence_coverage_pct"] == 0.0
    assert feat["foreign_institutional_score"] == 50.0


def test_proxy_final_score_ignores_duplicate_ohlcv_votes():
    cfg = ScannerConfig()
    base = {
        "direct_broker": False,
        "proxy_accumulation_score": 70.0,
        "proxy_distribution_risk": 50.0,
        "proxy_absorption_score": 10.0,
        "proxy_supply_tightness_score": 10.0,
        "retail_exhaustion_score": 10.0,
        "price_flow_divergence_score": 10.0,
        "foreign_institutional_score": 55.0,
        "market_sector_score": 60.0,
        "smc_execution_score": 65.0,
        "risk_liquidity_score": 70.0,
        "price_data_quality_score": 100.0,
    }
    duplicate_extreme = dict(base)
    duplicate_extreme.update({
        "proxy_absorption_score": 100.0,
        "proxy_supply_tightness_score": 100.0,
        "retail_exhaustion_score": 100.0,
        "price_flow_divergence_score": 100.0,
    })
    assert final_score(base, cfg) == final_score(duplicate_extreme, cfg)


def _structural_price_frame():
    dates = pd.bdate_range("2026-01-02", periods=100)
    close = np.linspace(98.0, 101.0, 100)
    high = close + 1.0
    low = close - 1.0
    # Observed resistance pivots materially above the current execution zone.
    high[55] = 115.0
    high[75] = 123.0
    # Observed recent support provides structural invalidation.
    low[-6:-1] = 96.0
    return pd.DataFrame({
        "date": dates, "open": close - 0.3, "high": high,
        "low": low, "close": close, "volume": np.full(100, 2_000_000.0),
    })


def test_smc_execution_requires_structural_levels_and_valid_idx_fractions():
    sf = compute_smc_features(_structural_price_frame())
    assert sf["execution_geometry_valid"] is True
    assert sf["execution_levels_tradeable"] is True
    assert sf["stop_basis"] == "OBSERVED_SWING_SUPPORT"
    assert sf["target_basis"] == "OBSERVED_SWING_RESISTANCE"
    assert sf["execution_rr1"] >= 1.5
    assert sf["execution_rr2"] >= 2.0
    for key in ("entry_low", "entry_high", "invalidation", "tp1", "tp2"):
        assert is_valid_idx_price(sf[key])


def test_smc_does_not_manufacture_r_multiple_targets_without_resistance():
    px = prices(start=137.3)
    sf = compute_smc_features(px)
    if sf["target_candidate_count"] < 2:
        assert sf["execution_geometry_valid"] is False
        assert sf["target_basis"] == "STRUCTURE_UNAVAILABLE"
        assert sf["tp1"] is None
        assert sf["tp2"] is None



def test_proxy_ohlcv_family_cannot_create_high_conviction_with_neutral_external_evidence():
    cfg = ScannerConfig()
    features = {
        "direct_broker": False,
        "proxy_accumulation_score": 100.0,
        "proxy_distribution_risk": 50.0,
        "proxy_absorption_score": 100.0,
        "proxy_supply_tightness_score": 100.0,
        "retail_exhaustion_score": 100.0,
        "price_flow_divergence_score": 100.0,
        "foreign_institutional_score": 50.0,
        "market_sector_score": 50.0,
        "smc_execution_score": 100.0,
        "risk_liquidity_score": 100.0,
        "price_data_quality_score": 100.0,
    }

    score = final_score(features, cfg)

    assert score < 75.0
