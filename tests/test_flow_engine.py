from __future__ import annotations

import numpy as np
import pandas as pd

from idx_flow_scanner.config import ScannerConfig
from idx_flow_scanner.data import normalize_broker_summary
from idx_flow_scanner.engines.flow import compute_broker_features
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
            rows.append({"ticker":"TEST","trade_date":d,"broker_code":code,"buy_value":buy,"sell_value":sell,"buy_volume":bvol,"sell_volume":svol,"buy_avg":104.0,"sell_avg":105.0,"source":"TEST_DIRECT","source_verified":verified})
        for code,scale in sellers:
            buy=3_000_000*scale if accumulating else 10_000_000*scale
            sell=10_000_000*scale if accumulating else 3_000_000*scale
            bvol=30_000*scale if accumulating else 100_000*scale
            svol=100_000*scale if accumulating else 30_000*scale
            rows.append({"ticker":"TEST","trade_date":d,"broker_code":code,"buy_value":buy,"sell_value":sell,"buy_volume":bvol,"sell_volume":svol,"buy_avg":104.0,"sell_avg":105.0,"source":"TEST_DIRECT","source_verified":verified})
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
            rows.append({"ticker":"TEST","trade_date":d,"broker_code":code,"buy_value":buy,"sell_value":sell,"buy_volume":bvol,"sell_volume":svol,"buy_avg":104.0,"sell_avg":108.0,"source":"TEST_DIRECT","source_verified":True})
        for code,scale in sellers:
            if reversal: buy,sell,bvol,svol=18_000_000*scale,1_000_000*scale,180_000*scale,10_000*scale
            else: buy,sell,bvol,svol=2_000_000*scale,10_000_000*scale,20_000*scale,100_000*scale
            rows.append({"ticker":"TEST","trade_date":d,"broker_code":code,"buy_value":buy,"sell_value":sell,"buy_volume":bvol,"sell_volume":svol,"buy_avg":104.0,"sell_avg":108.0,"source":"TEST_DIRECT","source_verified":True})
    br=normalize_broker_summary(pd.DataFrame(rows)); result=scan_one("TEST",px,br,ScannerConfig())
    assert result.evidence_tier=="BROKER_DIRECT"
    assert result.distribution_risk>=65; assert result.phase=="DISTRIBUTION"; assert result.action=="REDUCE_AVOID"; assert result.real_money_state=="GUARDED"
