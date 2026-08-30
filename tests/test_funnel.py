from __future__ import annotations

from types import SimpleNamespace

import pandas as pd

import idx_flow_scanner.funnel as funnel
from idx_flow_scanner.config import ScannerConfig


def _row(ticker: str, score: float, *, dist: float = 30.0, foreign_cov: float = 100.0) -> dict:
    return {
        "ticker": ticker,
        "as_of_date": "2026-08-14",
        "final_score": score,
        "phase": "ACCUMULATION",
        "action": "RESEARCH_ONLY",
        "real_money_state": "GUARDED",
        "evidence_tier": "PRICE_PROXY",
        "evidence_coverage_pct": 0.0,
        "accumulation_score": score,
        "operator_dominance_score": 50.0,
        "cost_basis_score": 50.0,
        "retail_exhaustion_score": 50.0,
        "foreign_institutional_score": 70.0,
        "supply_concentration_score": 50.0,
        "price_flow_divergence_score": 50.0,
        "market_context_score": 61.0,
        "smc_execution_score": 65.0,
        "risk_liquidity_score": 70.0,
        "price_data_quality_score": 90.0,
        "distribution_risk": dist,
        "estimated_smart_money_cost": None,
        "premium_to_cost_pct": None,
        "entry_low": 100.0,
        "entry_high": 102.0,
        "invalidation": 95.0,
        "tp1": 110.0,
        "tp2": 120.0,
        "guardrail_reason": "direct broker evidence unavailable",
        "diagnostics": {
            "foreign_evidence_coverage_pct": foreign_cov,
            "foreign_provider_selected": "IDX_DIRECT",
            "foreign_provider_selection_state": "IDX_DIRECT",
            "foreign_provider_reconciliation_state": "SINGLE_PROVIDER",
            "foreign_provider_conflict": False,
            "foreign_window_state": "FULL" if foreign_cov == 100 else "PARTIAL",
            "price_staleness_days": 0,
            "zero_volume_ratio_20d": 0.0,
            "zero_volume_ratio_60d": 0.0,
            "market_regime_score": 57.0,
            "market_regime_label": "NEUTRAL",
            "market_breadth_20d": 52.0,
            "market_breadth_60d": 55.0,
            "relative_strength_20d_pct": 4.0,
            "relative_strength_60d_pct": 8.0,
            "market_context_basis": "CROSS_SECTIONAL_400",
            "market_context_coverage": 400,
        },
    }


def test_select_guarded_top5_is_proxy_foreign_only_and_fail_closed():
    rows = [
        _row("AAAA", 81),
        _row("BBBB", 79),
        _row("CCCC", 77),
        _row("DDDD", 75),
        _row("EEEE", 73),
        _row("FFFF", 90, dist=75),
        _row("GGGG", 88, foreign_cov=40),
    ]
    result = funnel.select_guarded_top5(pd.DataFrame(rows), ScannerConfig(), top_n=5)
    assert result["ticker"].tolist() == ["AAAA", "BBBB", "CCCC", "DDDD", "EEEE"]
    assert result["guarded_rank"].tolist() == [1, 2, 3, 4, 5]
    assert set(result["evidence_tier"]) == {"PRICE_PROXY"}


def test_verify_guarded_top5_preserves_400_ticker_market_context(monkeypatch):
    guarded = funnel.select_guarded_top5(pd.DataFrame([_row("AAAA", 81), _row("BBBB", 79)]), top_n=2)
    captured = []

    def fake_scan_one(ticker, price, broker, config, official_flow=None, market_features=None, reference_date=None):
        captured.append((ticker, market_features.copy()))
        direct = ticker == "AAAA"
        return SimpleNamespace(
            to_dict=lambda: {
                **_row(ticker, 85 if direct else 76),
                "evidence_tier": "BROKER_DIRECT" if direct else "PRICE_PROXY",
                "evidence_coverage_pct": 90.0 if direct else 10.0,
                "real_money_state": "ELIGIBLE" if direct else "GUARDED",
                "action": "BUY_ON_WEAKNESS" if direct else "RESEARCH_ONLY",
                "diagnostics": {
                    "broker_days": 12 if direct else 1,
                    "broker_verified_source_pct": 100.0,
                    "broker_data_valid": True,
                    "broker_freshness_state": "FRESH",
                    "foreign_provider_selected": "IDX_DIRECT",
                    "foreign_provider_selection_state": "IDX_DIRECT",
                    "foreign_provider_reconciliation_state": "SINGLE_PROVIDER",
                    "foreign_provider_conflict": False,
                    "foreign_window_state": "FULL",
                    "foreign_data_valid": True,
                    "foreign_data_freshness": "FRESH",
                },
            }
        )

    monkeypatch.setattr(funnel, "scan_one", fake_scan_one)
    prices = {"AAAA": pd.DataFrame({"date": ["2026-08-14"]}), "BBBB": pd.DataFrame({"date": ["2026-08-14"]})}
    broker = pd.DataFrame({"ticker": ["AAAA", "BBBB"]})
    out, errors = funnel.verify_guarded_top5(guarded, lambda t: prices[t], broker)

    assert not errors
    assert captured[0][1]["market_context_coverage"] == 400
    assert captured[0][1]["market_sector_score"] == 61.0
    statuses = dict(zip(out["ticker"], out["broker_verification_status"]))
    assert statuses["AAAA"] == "BROKER_VERIFIED"
    assert statuses["BBBB"] == "BROKER_PENDING"


def test_merge_verified_finalists_replaces_only_finalist_rows():
    base = pd.DataFrame([_row("AAAA", 80), _row("BBBB", 70), _row("CCCC", 60)])
    broker = pd.DataFrame([{**_row("AAAA", 91), "evidence_tier": "BROKER_DIRECT", "real_money_state": "ELIGIBLE"}])
    merged = funnel.merge_verified_finalists(base, broker)
    by_ticker = merged.set_index("ticker")
    assert by_ticker.loc["AAAA", "final_score"] == 91
    assert by_ticker.loc["AAAA", "evidence_tier"] == "BROKER_DIRECT"
    assert by_ticker.loc["BBBB", "final_score"] == 70
    assert by_ticker.loc["CCCC", "final_score"] == 60


def test_guarded_top5_rejects_extreme_zero_volume_candidate_before_broker_budget():
    good = _row("GOOD", 70)
    bad = _row("ILLQ", 99)
    bad["diagnostics"]["zero_volume_ratio_20d"] = 0.25
    result = funnel.select_guarded_top5(pd.DataFrame([bad, good]), ScannerConfig(), top_n=5)
    assert result["ticker"].tolist() == ["GOOD"]
