import pandas as pd

from idx_flow_scanner.vendor_foreign_store import (
    ZAPI_FOREIGN_FLOW_SOURCE,
    normalize_zapi_vendor_foreign,
)


def test_zapi_vendor_foreign_normalization_preserves_share_volume_and_provenance():
    raw = pd.DataFrame([
        {
            "ticker": "BBCA.JK",
            "trade_date": "2026-08-14",
            "foreign_buy": 1200,
            "foreign_sell": 700,
            "foreign_net": -999,  # must be recomputed from the source legs
            "volume": 5000,
            "traded_value": 7500000,
            "source": ZAPI_FOREIGN_FLOW_SOURCE,
        }
    ])
    out = normalize_zapi_vendor_foreign(raw)
    assert len(out) == 1
    row = out.iloc[0]
    assert row["ticker"] == "BBCA"
    assert float(row["foreign_net"]) == 500.0
    assert float(row["volume"]) == 5000.0
    assert float(row["traded_value"]) == 7500000.0
    assert row["flow_unit"] == "SHARES"
    assert bool(row["source_verified"]) is True
    assert row["provenance_state"] == "VENDOR_AUTHENTICATED_IDX_DERIVED"
    assert "zpi.web.id" in row["source_url"]


def test_vendor_path_rejects_direct_idx_and_unknown_sources():
    raw = pd.DataFrame([
        {
            "ticker": "BBCA",
            "trade_date": "2026-08-14",
            "foreign_buy": 1,
            "foreign_sell": 2,
            "source": "IDX_OFFICIAL_STOCK_SUMMARY",
        },
        {
            "ticker": "BBRI",
            "trade_date": "2026-08-14",
            "foreign_buy": 1,
            "foreign_sell": 2,
            "source": "UNKNOWN_VENDOR",
        },
    ])
    assert normalize_zapi_vendor_foreign(raw).empty
