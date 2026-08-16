from __future__ import annotations

import pandas as pd

from idx_flow_scanner.foreign_evidence import prepare_foreign_evidence
from idx_flow_scanner.providers.zapi import normalize_zapi_foreign_payload


def _price(dates: pd.DatetimeIndex) -> pd.DataFrame:
    return pd.DataFrame({
        "date": dates,
        "open": 100.0,
        "high": 105.0,
        "low": 98.0,
        "close": 100.0,
        "volume": 10_000_000,
    })


def test_zapi_foreign_payload_preserves_share_units():
    payload = {
        "date": "2026-08-14",
        "unit": "shares",
        "total": 1,
        "data": [{
            "code": "ELSA",
            "value": 1_000_000_000,
            "volume": 10_000_000,
            "foreignBuyShares": 1_500_000,
            "foreignSellShares": 500_000,
            "netForeignShares": 1_000_000,
        }],
    }
    out = normalize_zapi_foreign_payload(payload, "2026-08-14", ["ELSA"])
    assert len(out) == 1
    row = out.iloc[0]
    assert row["ticker"] == "ELSA"
    assert row["foreign_buy"] == 1_500_000
    assert row["foreign_sell"] == 500_000
    assert row["foreign_net"] == 1_000_000
    assert row["volume"] == 10_000_000
    assert row["source"] == "ZAPI_IDX_FOREIGN_FLOW"


def test_selector_uses_zapi_when_direct_idx_coverage_is_lower():
    dates = pd.bdate_range("2026-07-20", periods=20)
    direct = pd.DataFrame({
        "ticker": ["ELSA"] * 2,
        "trade_date": dates[:2],
        "foreign_buy": [100_000] * 2,
        "foreign_sell": [50_000] * 2,
        "foreign_net": [50_000] * 2,
        "volume": [10_000_000] * 2,
        "source": ["IDX_OFFICIAL_STOCK_SUMMARY"] * 2,
    })
    zapi = pd.DataFrame({
        "ticker": ["ELSA"] * 20,
        "trade_date": dates,
        "foreign_buy": [100_000] * 20,
        "foreign_sell": [50_000] * 20,
        "foreign_net": [50_000] * 20,
        "volume": [10_000_000] * 20,
        "source": ["ZAPI_IDX_FOREIGN_FLOW"] * 20,
    })
    candidates = pd.concat([direct, zapi], ignore_index=True)
    selected, stats = prepare_foreign_evidence(
        ["ELSA"], candidates, lambda ticker: _price(dates), lookback=20
    )
    assert stats["zapi_selected_tickers"] == 1
    assert stats["idx_direct_selected_tickers"] == 0
    assert set(selected["flow_unit"]) == {"SHARES"}
    assert set(selected["foreign_evidence_source"]) == {"ZAPI_IDX_FOREIGN_FLOW"}
    assert len(selected) == 20


def test_selector_prefers_direct_idx_on_equal_coverage_without_double_counting():
    dates = pd.bdate_range("2026-07-20", periods=20)
    common = {
        "ticker": ["ELSA"] * 20,
        "trade_date": dates,
        "foreign_buy": [100_000] * 20,
        "foreign_sell": [50_000] * 20,
        "foreign_net": [50_000] * 20,
        "volume": [10_000_000] * 20,
    }
    direct = pd.DataFrame({**common, "source": ["IDX_OFFICIAL_STOCK_SUMMARY"] * 20})
    zapi = pd.DataFrame({**common, "source": ["ZAPI_IDX_FOREIGN_FLOW"] * 20})
    selected, stats = prepare_foreign_evidence(
        ["ELSA"], pd.concat([direct, zapi], ignore_index=True), lambda ticker: _price(dates), lookback=20
    )
    assert stats["idx_direct_selected_tickers"] == 1
    assert stats["zapi_selected_tickers"] == 0
    assert set(selected["foreign_evidence_source"]) == {"IDX_OFFICIAL_STOCK_SUMMARY"}
    assert len(selected) == 20
