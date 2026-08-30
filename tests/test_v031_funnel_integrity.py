from __future__ import annotations

import numpy as np
import pandas as pd

from idx_flow_scanner.data import normalize_broker_summary
from idx_flow_scanner.engines.smc import compute_smc_features
from idx_flow_scanner.funnel import select_guarded_top5
from idx_flow_scanner.pipeline import scan_one


def _guarded_row(
    ticker: str,
    score: float,
    accumulation: float,
    *,
    evidence_tier: str = "PRICE_PROXY",
    dist: float = 45.0,
) -> dict[str, object]:
    return {
        "ticker": ticker,
        "as_of_date": "2026-08-14",
        "final_score": score,
        "phase": "ACCUMULATION",
        "action": "RESEARCH_ONLY",
        "real_money_state": "GUARDED",
        "evidence_tier": evidence_tier,
        "accumulation_score": accumulation,
        "foreign_institutional_score": 70.0,
        "smc_execution_score": 55.0,
        "price_data_quality_score": 100.0,
        "distribution_risk": dist,
        "diagnostics": {
            "foreign_evidence_coverage_pct": 100.0,
            "foreign_provider_selected": "IDX_DIRECT",
            "foreign_provider_selection_state": "IDX_DIRECT",
            "foreign_provider_reconciliation_state": "SINGLE_PROVIDER",
            "foreign_provider_conflict": False,
            "foreign_window_state": "FULL",
            "price_staleness_days": 0, "zero_volume_ratio_20d": 0.0, "zero_volume_ratio_60d": 0.0,
        },
    }


def _prices(n: int = 100) -> pd.DataFrame:
    dates = pd.bdate_range("2026-01-02", periods=n)
    close = 100.0 + np.linspace(0, 8, n) + np.sin(np.arange(n) / 5.0)
    return pd.DataFrame(
        {
            "date": dates,
            "open": close - 0.5,
            "high": close + 1.0,
            "low": close - 1.0,
            "close": close,
            "volume": np.full(n, 2_000_000),
        }
    )


def _one_day_balanced_broker(trade_date: pd.Timestamp) -> pd.DataFrame:
    rows: list[dict[str, object]] = []
    buyers = [("YP", 1.0), ("BK", 0.7), ("AK", 0.5)]
    sellers = [("NI", 1.0), ("PD", 0.7), ("CC", 0.5)]
    for code, scale in buyers:
        rows.append(
            {
                "ticker": "TEST",
                "trade_date": trade_date,
                "broker_code": code,
                "buy_value": 10_000_000 * scale,
                "sell_value": 3_000_000 * scale,
                "buy_volume": 100_000 * scale,
                "sell_volume": 30_000 * scale,
                "buy_avg": 104.0,
                "sell_avg": 105.0,
                "source": "TEST_DIRECT",
                "source_verified": True,
                "direct_broker_eligible": True,
            }
        )
    for code, scale in sellers:
        rows.append(
            {
                "ticker": "TEST",
                "trade_date": trade_date,
                "broker_code": code,
                "buy_value": 3_000_000 * scale,
                "sell_value": 10_000_000 * scale,
                "buy_volume": 30_000 * scale,
                "sell_volume": 100_000 * scale,
                "buy_avg": 104.0,
                "sell_avg": 105.0,
                "source": "TEST_DIRECT",
                "source_verified": True,
                "direct_broker_eligible": True,
            }
        )
    return normalize_broker_summary(pd.DataFrame(rows))


def test_guarded_selector_always_uses_best_five_healthy_proxy_candidates():
    rows = [
        _guarded_row("MMIX", 67.48, 82.46),
        _guarded_row("PKPK", 61.97, 72.47),
        _guarded_row("DAYA", 61.89, 81.24),
        _guarded_row("MDLA", 61.79, 62.69),
        _guarded_row("OMED", 61.79, 82.49),
        _guarded_row("DIRECT", 99.0, 99.0, evidence_tier="BROKER_DIRECT"),
        _guarded_row("DIST", 98.0, 98.0, dist=80.0),
    ]

    out = select_guarded_top5(pd.DataFrame(rows), top_n=5)

    assert out["ticker"].tolist() == ["MMIX", "PKPK", "DAYA", "OMED", "MDLA"]
    assert out["guarded_rank"].tolist() == [1, 2, 3, 4, 5]
    assert (out["final_score"] < 65.0).sum() == 4
    assert set(out["evidence_tier"]) == {"PRICE_PROXY"}


def test_pending_broker_evidence_has_zero_alpha_influence():
    price = _prices()
    pending = _one_day_balanced_broker(price["date"].iloc[-1])

    proxy = scan_one("TEST", price, pd.DataFrame())
    with_pending = scan_one("TEST", price, pending)

    assert with_pending.evidence_tier == "PRICE_PROXY"
    assert with_pending.diagnostics["broker_days"] == 1
    assert with_pending.diagnostics["broker_alpha_applied"] is False
    assert with_pending.final_score == proxy.final_score
    assert with_pending.retail_exhaustion_score == proxy.retail_exhaustion_score
    assert with_pending.price_flow_divergence_score == proxy.price_flow_divergence_score
    assert with_pending.accumulation_score == proxy.accumulation_score
    assert with_pending.estimated_smart_money_cost is None
    assert with_pending.premium_to_cost_pct is None


def test_flat_price_execution_geometry_is_fail_closed():
    dates = pd.bdate_range("2026-01-02", periods=100)
    price = pd.DataFrame(
        {
            "date": dates,
            "open": 78.0,
            "high": 78.0,
            "low": 78.0,
            "close": 78.0,
            "volume": 1_000_000,
        }
    )

    sf = compute_smc_features(price)

    assert sf["execution_geometry_valid"] is False
    assert sf["smc_execution_score"] <= 25.0
    assert sf["entry_low"] is None
    assert sf["entry_high"] is None
    assert sf["invalidation"] is None
    assert sf["tp1"] is None
    assert sf["tp2"] is None
