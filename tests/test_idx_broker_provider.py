from __future__ import annotations

from idx_flow_scanner.providers.idx_official import normalize_idx_broker_stock_summary_payload


def test_normalize_idx_broker_stock_summary_payload_preserves_stock_identity():
    payload = {
        "data": [
            {
                "StockCode": "MMIX",
                "Date": "2026-08-14",
                "IDFirm": "YP",
                "FirmName": "Yap",
                "BuyValue": 10000000,
                "SellValue": 3000000,
                "BuyVolume": 100000,
                "SellVolume": 30000,
                "BuyAvg": 104.0,
                "SellAvg": 105.0,
            },
            {
                "StockCode": "MMIX",
                "Date": "2026-08-14",
                "IDFirm": "NI",
                "FirmName": "N1",
                "BuyValue": 3000000,
                "SellValue": 10000000,
                "BuyVolume": 30000,
                "SellVolume": 100000,
                "BuyAvg": 104.0,
                "SellAvg": 105.0,
            },
        ]
    }
    out = normalize_idx_broker_stock_summary_payload(payload, "MMIX", "2026-08-14")
    assert len(out) == 2
    assert set(out["ticker"]) == {"MMIX"}
    assert set(out["broker_code"]) == {"YP", "NI"}
    assert set(out["source"]) == {"IDX_OFFICIAL_BROKER_SUMMARY"}
    assert out["source_verified"].all()


def test_normalize_idx_broker_stock_summary_rejects_mismatched_ticker():
    payload = {
        "data": [
            {"StockCode": "OTHER", "IDFirm": "YP", "BuyValue": 1, "SellValue": 2}
        ]
    }
    out = normalize_idx_broker_stock_summary_payload(payload, "MMIX", "2026-08-14")
    assert out.empty
