from __future__ import annotations

import pandas as pd

from idx_flow_scanner.engines.flow import compute_official_foreign_features
from idx_flow_scanner.providers.idx_official import normalize_idx_stock_summary_payload


def test_idx_stock_summary_normalization_and_foreign_score():
    payload = {
        "data": [
            {
                "StockCode": "ELSA",
                "Date": "2026-08-14T00:00:00",
                "ForeignBuy": 15_000_000_000,
                "ForeignSell": 5_000_000_000,
                "Value": 100_000_000_000,
                "Volume": 200_000_000,
                "Frequency": 1200,
                "Bid": 680,
                "Offer": 685,
                "BidVolume": 100000,
                "OfferVolume": 90000,
                "ListedShares": 10_000_000_000,
                "TradebleShares": 4_000_000_000,
            }
        ]
    }
    one = normalize_idx_stock_summary_payload(payload, "2026-08-14")
    assert len(one) == 1
    assert one.iloc[0]["ticker"] == "ELSA"
    assert one.iloc[0]["foreign_net"] == 10_000_000_000

    dates = pd.bdate_range("2026-07-20", periods=20)
    flow = pd.concat([one.assign(trade_date=d) for d in dates], ignore_index=True)
    price = pd.DataFrame({
        "date": dates,
        "open": 650.0,
        "high": 690.0,
        "low": 640.0,
        "close": 680.0,
        "volume": 200_000_000,
    })
    feat = compute_official_foreign_features(flow, price)
    assert feat["official_foreign_coverage_pct"] == 100.0
    assert feat["foreign_institutional_score"] > 70
