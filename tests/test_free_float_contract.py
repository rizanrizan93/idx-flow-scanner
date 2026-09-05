from __future__ import annotations

import pandas as pd

from idx_flow_scanner.canonical_slow_evidence import compute_slow_evidence_canonical


def test_missing_regulatory_free_float_does_not_hard_block_slow_evidence() -> None:
    dates = pd.bdate_range("2026-04-01", periods=100)
    price = pd.DataFrame(
        {
            "date": dates,
            "open": 100.0,
            "high": 102.0,
            "low": 99.0,
            "close": 101.0,
            "volume": 1_000_000.0,
        }
    )
    stock = pd.DataFrame(
        [{"ticker": "TEST", "trade_date": "2026-08-31", "listed_shares": 1_000_000, "tradable_shares": 1_000_000}]
    )
    result = compute_slow_evidence_canonical(
        "TEST",
        price,
        {"foreign_net_20d": 0.0},
        stock_summary=stock,
    )
    assert result["free_float_pct"] is None
    assert result["free_float_structure_score"] == 50.0
    assert result["free_float_available"] is False
