from __future__ import annotations

import pandas as pd

from idx_flow_scanner.providers.goapi import (
    choose_goapi_backfill_jobs,
    normalize_goapi_broker_payload,
)


def test_goapi_net_side_rows_map_to_broker_contract_with_lot_conversion():
    payload = {
        "status": "success",
        "data": {
            "results": [
                {
                    "broker": {"code": "SQ"},
                    "code": "SQ",
                    "date": "2026-08-14",
                    "side": "BUY",
                    "lot": 12_345,
                    "value": 840_000_000,
                    "transaction_type": "NET",
                    "investor": "ALL",
                    "avg": 680.0,
                    "symbol": "ELSA",
                },
                {
                    "broker": {"code": "YP"},
                    "code": "YP",
                    "date": "2026-08-14",
                    "side": "SELL",
                    "lot": 5_000,
                    "value": 342_500_000,
                    "transaction_type": "NET",
                    "investor": "ALL",
                    "avg": 685.0,
                    "symbol": "ELSA",
                },
            ]
        },
    }
    out = normalize_goapi_broker_payload(payload, "ELSA", "2026-08-14")
    assert len(out) == 2
    buy = out[out["broker_code"] == "SQ"].iloc[0]
    sell = out[out["broker_code"] == "YP"].iloc[0]
    assert buy["buy_volume"] == 1_234_500
    assert buy["sell_volume"] == 0
    assert buy["net_value"] == 840_000_000
    assert sell["sell_volume"] == 500_000
    assert sell["net_value"] == -342_500_000
    assert buy["source"] == "GOAPI_BROKER_SUMMARY_NET"
    assert bool(buy["source_verified"])
    assert "NET_SIDE" in buy["provenance_state"]


def test_goapi_backfill_jobs_are_date_major_and_skip_existing():
    existing = pd.DataFrame({
        "ticker": ["ELSA", "OMED"],
        "trade_date": ["2026-08-14", "2026-08-13"],
    })
    jobs = choose_goapi_backfill_jobs(
        ["ELSA", "OMED", "MARK"],
        existing,
        ["2026-08-14", "2026-08-13"],
        budget_requests=4,
    )
    assert jobs == [
        ("OMED", "2026-08-14"),
        ("MARK", "2026-08-14"),
        ("ELSA", "2026-08-13"),
        ("MARK", "2026-08-13"),
    ]
