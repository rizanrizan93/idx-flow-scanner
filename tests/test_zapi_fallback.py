from __future__ import annotations

import pandas as pd

from idx_flow_scanner.providers import zapi


def test_normalize_zapi_stock_summary_preserves_share_units():
    payload = {
        "data": [
            {
                "Date": "2026-08-14T00:00:00",
                "StockCode": "ELSA",
                "Value": 1_250_000_000,
                "Volume": 2_000_000,
                "ForeignBuy": 800_000,
                "ForeignSell": 300_000,
                "Frequency": 100,
                "Bid": 680,
                "Offer": 685,
                "BidVolume": 25_000,
                "OfferVolume": 30_000,
                "ListedShares": 7_000_000_000,
                "TradebleShares": 7_000_000_000,
            }
        ],
        "recordsTotal": 1,
    }
    out = zapi.normalize_zapi_stock_summary_payload(payload, "2026-08-14", ["ELSA"])
    assert len(out) == 1
    row = out.iloc[0]
    assert row["ticker"] == "ELSA"
    assert row["foreign_buy"] == 800_000
    assert row["foreign_sell"] == 300_000
    assert row["foreign_net"] == 500_000
    assert row["volume"] == 2_000_000
    assert row["source"] == "ZAPI_IDX_STOCK_SUMMARY"
    assert pd.Timestamp(row["trade_date"]) == pd.Timestamp("2026-08-14")


def test_foreign_flow_day_falls_back_to_stock_summary_when_dedicated_endpoint_empty(monkeypatch):
    calls: list[str] = []

    def fake_get(url, params, api_key, timeout):
        calls.append(url)
        if url == zapi.ZAPI_FOREIGN_FLOW_URL:
            return {
                "data": [],
                "date": "2026-08-14T00:00:00",
                "unit": "shares",
                "start": 0,
                "total": 0,
                "length": 0,
            }
        if url == zapi.ZAPI_STOCK_SUMMARY_URL:
            return {
                "data": [
                    {
                        "Date": "2026-08-14T00:00:00",
                        "StockCode": "ELSA",
                        "Value": 1_250_000_000,
                        "Volume": 2_000_000,
                        "ForeignBuy": 800_000,
                        "ForeignSell": 300_000,
                    }
                ],
                "start": 0,
                "length": 1,
                "recordsTotal": 1,
                "recordsFiltered": 1,
            }
        raise AssertionError(url)

    monkeypatch.setattr(zapi, "_get_json", fake_get)
    out = zapi.fetch_zapi_foreign_flow_day(["ELSA"], "2026-08-14", api_key="zpi_test")
    assert len(out) == 1
    assert out.iloc[0]["foreign_net"] == 500_000
    assert out.iloc[0]["source"] == "ZAPI_IDX_STOCK_SUMMARY"
    assert calls == [zapi.ZAPI_FOREIGN_FLOW_URL, zapi.ZAPI_STOCK_SUMMARY_URL]
