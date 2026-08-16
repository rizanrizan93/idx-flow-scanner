from __future__ import annotations

import pandas as pd
import pytest

from idx_flow_scanner.foreign_evidence import prepare_foreign_evidence
from idx_flow_scanner.providers.indexalpha import fetch_indexalpha_foreign_batch


class _ForeignResponse:
    status_code = 200
    headers = {"X-Monthly-Remaining": "24999"}
    text = ""

    def json(self):
        return {
            "success": True,
            "data": {
                "ELSA": {
                    "foreign_buy": 1_250_000_000,
                    "foreign_sell": 830_000_000,
                    "net_foreign": 420_000_000,
                }
            },
            "error": None,
        }


def test_indexalpha_foreign_values_are_explicit_idr_and_verified(monkeypatch):
    def fake_post(*args, **kwargs):
        assert kwargs["json"]["tickers"] == ["ELSA"]
        assert kwargs["json"]["market"] == "ALL"
        return _ForeignResponse()

    monkeypatch.setattr("curl_cffi.requests.post", fake_post)
    out = fetch_indexalpha_foreign_batch(["ELSA"], "2026-08-14", api_token="test-token")
    assert len(out) == 1
    row = out.iloc[0]
    assert row["flow_unit"] == "IDR"
    assert row["foreign_net"] == 420_000_000
    assert row["source"] == "INDEXALPHA_FOREIGN_FLOW"
    assert bool(row["source_verified"])


def test_selector_uses_vendor_when_official_coverage_is_lower_without_mixing_units():
    dates = pd.bdate_range("2026-07-20", periods=20)
    price = pd.DataFrame({
        "date": dates,
        "open": 100.0,
        "high": 105.0,
        "low": 98.0,
        "close": 100.0,
        "volume": 10_000_000,
    })
    official = pd.DataFrame({
        "ticker": ["ELSA"] * 2,
        "trade_date": dates[:2],
        "foreign_buy": [100_000, 100_000],
        "foreign_sell": [50_000, 50_000],
        "foreign_net": [50_000, 50_000],
        "volume": [10_000_000, 10_000_000],
        "source": ["IDX_OFFICIAL_STOCK_SUMMARY"] * 2,
    })
    vendor = pd.DataFrame({
        "ticker": ["ELSA"] * 20,
        "trade_date": dates,
        "foreign_buy": [80_000_000.0] * 20,
        "foreign_sell": [40_000_000.0] * 20,
        "foreign_net": [40_000_000.0] * 20,
        "flow_unit": ["IDR"] * 20,
        "source": ["INDEXALPHA_FOREIGN_FLOW"] * 20,
        "source_verified": [True] * 20,
    })

    selected, stats = prepare_foreign_evidence(
        ["ELSA"], official, vendor, lambda ticker: price, lookback=20
    )
    assert stats["vendor_selected_tickers"] == 1
    assert stats["idx_official_selected_tickers"] == 0
    assert set(selected["flow_unit"]) == {"IDR"}
    assert set(selected["foreign_evidence_source"]) == {"VERIFIED_VENDOR"}
    assert selected["volume"].iloc[-1] == pytest.approx(1_000_000_000.0)


def test_selector_prefers_official_on_equal_coverage():
    dates = pd.bdate_range("2026-07-20", periods=20)
    price = pd.DataFrame({"date": dates, "close": 100.0, "volume": 10_000_000})
    official = pd.DataFrame({
        "ticker": ["ELSA"] * 20,
        "trade_date": dates,
        "foreign_buy": [100_000] * 20,
        "foreign_sell": [50_000] * 20,
        "foreign_net": [50_000] * 20,
        "volume": [10_000_000] * 20,
        "source": ["IDX_OFFICIAL_STOCK_SUMMARY"] * 20,
    })
    vendor = pd.DataFrame({
        "ticker": ["ELSA"] * 20,
        "trade_date": dates,
        "foreign_buy": [80_000_000.0] * 20,
        "foreign_sell": [40_000_000.0] * 20,
        "foreign_net": [40_000_000.0] * 20,
        "flow_unit": ["IDR"] * 20,
        "source": ["INDEXALPHA_FOREIGN_FLOW"] * 20,
    })
    selected, stats = prepare_foreign_evidence(
        ["ELSA"], official, vendor, lambda ticker: price, lookback=20
    )
    assert stats["idx_official_selected_tickers"] == 1
    assert set(selected["flow_unit"]) == {"SHARES"}
