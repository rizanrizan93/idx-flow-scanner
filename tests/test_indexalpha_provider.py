from __future__ import annotations

import pandas as pd

from idx_flow_scanner.providers.indexalpha import (
    choose_broker_refresh_tickers,
    fetch_indexalpha_broker_batch,
)


class _FakeResponse:
    status_code = 200
    headers = {"X-Monthly-Remaining": "24999"}
    text = ""

    def json(self):
        return {
            "success": True,
            "data": {
                "ELSA": [
                    {
                        "code": "SQ",
                        "buy_freq": 100,
                        "buy_volume": 2_000_000,
                        "buy_value": 1_360_000_000,
                        "sell_freq": 50,
                        "sell_volume": 500_000,
                        "sell_value": 342_500_000,
                        "buy_avg": 680.0,
                        "sell_avg": 685.0,
                    }
                ]
            },
            "error": None,
        }


def test_indexalpha_batch_is_normalized_as_provenanced_stock_level_broker(monkeypatch):
    def fake_post(*args, **kwargs):
        assert kwargs["json"]["tickers"] == ["ELSA"]
        assert kwargs["json"]["market"] == "RG"
        assert kwargs["headers"]["Authorization"] == "Bearer test-token"
        return _FakeResponse()

    monkeypatch.setattr("curl_cffi.requests.post", fake_post)
    out = fetch_indexalpha_broker_batch(["ELSA"], "2026-08-14", api_token="test-token")
    assert len(out) == 1
    row = out.iloc[0]
    assert row["ticker"] == "ELSA"
    assert row["broker_code"] == "SQ"
    assert row["net_value"] == 1_017_500_000
    assert row["source"] == "INDEXALPHA_API"
    assert bool(row["source_verified"])
    assert row["provenance_state"] == "VERIFIED_VENDOR_API"


def test_quota_selection_prioritizes_missing_then_stalest_tickers():
    existing = pd.DataFrame({
        "ticker": ["ELSA", "OMED"],
        "trade_date": ["2026-08-14", "2026-08-10"],
    })
    selected = choose_broker_refresh_tickers(
        ["ELSA", "OMED", "MARK", "MMIX"],
        existing,
        budget_units=3,
    )
    assert selected[:2] == ["MARK", "MMIX"]
    assert selected[2] == "OMED"
