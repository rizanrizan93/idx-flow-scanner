from __future__ import annotations

import numpy as np
import pandas as pd

from idx_flow_scanner.config import ScannerConfig
from idx_flow_scanner.data import normalize_broker_summary
from idx_flow_scanner.engines.smc import compute_smc_features
from idx_flow_scanner.pipeline import scan_one


def _prices(n: int = 100) -> pd.DataFrame:
    dates = pd.bdate_range("2026-01-02", periods=n)
    close = 100.0 + np.linspace(0.0, 8.0, n) + np.sin(np.arange(n) / 5.0)
    return pd.DataFrame(
        {
            "date": dates,
            "open": close - 0.5,
            "high": close + 1.0,
            "low": close - 1.0,
            "close": close,
            "volume": np.full(n, 2_000_000.0),
        }
    )


def _one_day_pending_broker(trade_date) -> pd.DataFrame:
    rows = []
    for code, buy, sell in [
        ("YP", 10_000_000.0, 3_000_000.0),
        ("BK", 7_000_000.0, 2_100_000.0),
        ("AK", 5_000_000.0, 1_500_000.0),
        ("NI", 3_000_000.0, 10_000_000.0),
        ("PD", 2_100_000.0, 7_000_000.0),
        ("CC", 1_500_000.0, 5_000_000.0),
    ]:
        rows.append(
            {
                "ticker": "TEST",
                "trade_date": trade_date,
                "broker_code": code,
                "buy_value": buy,
                "sell_value": sell,
                "buy_volume": buy / 100.0,
                "sell_volume": sell / 100.0,
                "buy_avg": 104.0,
                "sell_avg": 105.0,
                "source": "TEST_DIRECT",
                "source_verified": True,
                "direct_broker_eligible": True,
            }
        )
    return normalize_broker_summary(pd.DataFrame(rows))


def test_pending_broker_has_zero_alpha_influence():
    px = _prices()
    pending = _one_day_pending_broker(px["date"].iloc[-1])
    no_broker = scan_one("TEST", px, pd.DataFrame(), ScannerConfig())
    with_pending = scan_one("TEST", px, pending, ScannerConfig())

    assert no_broker.evidence_tier == "PRICE_PROXY"
    assert with_pending.evidence_tier == "PRICE_PROXY"
    assert with_pending.diagnostics["broker_alpha_applied"] is False
    assert with_pending.final_score == no_broker.final_score
    assert with_pending.retail_exhaustion_score == no_broker.retail_exhaustion_score
    assert with_pending.price_flow_divergence_score == no_broker.price_flow_divergence_score
    assert with_pending.estimated_smart_money_cost is None
    assert with_pending.premium_to_cost_pct is None


def test_invalid_execution_geometry_fails_closed():
    dates = pd.bdate_range("2026-01-02", periods=30)
    price = pd.DataFrame(
        {
            "date": dates,
            "open": np.zeros(30),
            "high": np.zeros(30),
            "low": np.zeros(30),
            "close": np.zeros(30),
            "volume": np.full(30, 1_000_000.0),
        }
    )
    result = compute_smc_features(price)

    assert result["execution_geometry_valid"] is False
    assert result["smc_execution_score"] <= 25.0
    assert result["entry_low"] is None
    assert result["entry_high"] is None
    assert result["invalidation"] is None
    assert result["tp1"] is None
    assert result["tp2"] is None
