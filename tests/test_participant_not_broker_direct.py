from __future__ import annotations

import numpy as np
import pandas as pd

from idx_flow_scanner.data import normalize_broker_summary
from idx_flow_scanner.pipeline import _broker_verified_source_pct, scan_one


def _prices(n: int = 110) -> pd.DataFrame:
    dates = pd.bdate_range("2026-01-02", periods=n)
    close = 100.0 + np.linspace(0.0, 8.0, n) + np.sin(np.arange(n) / 7.0)
    return pd.DataFrame({
        "date": dates, "open": close - 0.5, "high": close + 1.0,
        "low": close - 1.0, "close": close,
        "volume": np.full(n, 2_000_000.0),
    })


def _participant_rows(dates) -> pd.DataFrame:
    rows = []
    for day in dates:
        for code, buy, sell in [
            ("AB", 12_000_000.0, 2_000_000.0), ("CD", 10_000_000.0, 3_000_000.0),
            ("EF", 8_000_000.0, 3_000_000.0), ("GH", 3_000_000.0, 10_000_000.0),
            ("IJ", 2_000_000.0, 9_000_000.0), ("KL", 2_000_000.0, 8_000_000.0),
        ]:
            rows.append({
                "ticker":"TEST", "trade_date":day, "broker_code":code,
                "buy_value":buy, "sell_value":sell,
                "buy_volume":buy/100.0, "sell_volume":sell/100.0,
                "buy_avg":104.0, "sell_avg":105.0, "market_type":"RG",
                "source":"IDX_OFFICIAL_PUBLIC_TRADE_DETAIL_PARTICIPANT_FLOW",
                "source_verified":True, "direct_broker_eligible":False,
                "provenance_state":"VERIFIED_IDX_PUBLIC_TRADE_DETAIL_PARTICIPANT_FLOW_NOT_BENEFICIAL_OWNER",
            })
    return normalize_broker_summary(pd.DataFrame(rows))


def test_official_participant_flow_never_unlocks_broker_direct():
    price = _prices()
    broker = _participant_rows(price["date"].tail(60))
    result = scan_one(
        "TEST", price, broker,
        reference_date=str(pd.Timestamp(price["date"].iloc[-1]).date()),
    )
    assert result.evidence_tier == "PRICE_PROXY"
    assert result.diagnostics["broker_alpha_applied"] is False
    assert result.diagnostics["broker_verified_source_pct"] == 0.0


def test_mixed_participant_and_direct_rows_apply_eligibility_row_by_row():
    frame = pd.DataFrame([
        {
            "buy_value": 100.0, "sell_value": 100.0,
            "source_verified": True,
            "source": "IDX_OFFICIAL_BROKER_SUMMARY",
            "provenance_state": "VERIFIED_IDX_PUBLIC_TRADING_SUMMARY_STOCK_LEVEL",
            "direct_broker_eligible": pd.NA,
        },
        {
            "buy_value": 100.0, "sell_value": 100.0,
            "source_verified": True,
            "source": "IDX_OFFICIAL_PUBLIC_TRADE_DETAIL_PARTICIPANT_FLOW",
            "provenance_state": "VERIFIED_IDX_PUBLIC_TRADE_DETAIL_PARTICIPANT_FLOW_NOT_BENEFICIAL_OWNER",
            "direct_broker_eligible": False,
        },
    ])

    assert _broker_verified_source_pct(frame) == 50.0
