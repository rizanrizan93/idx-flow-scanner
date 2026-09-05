from __future__ import annotations

import math

import pandas as pd

from idx_flow_scanner.evidence_database import (
    database_records,
    normalize_capital_actions,
    normalize_ownership,
    normalize_stock_summary,
    upsert_stock_summary,
)


class _Result:
    data = []


class _Table:
    def __init__(self, sink: list[dict[str, object]]) -> None:
        self.sink = sink

    def upsert(self, rows, on_conflict=None):
        self.sink.append({"rows": rows, "on_conflict": on_conflict})
        return self

    def execute(self):
        return _Result()


class _Client:
    def __init__(self) -> None:
        self.calls: list[dict[str, object]] = []
        self.tables: list[str] = []

    def table(self, name: str):
        self.tables.append(name)
        return _Table(self.calls)


class _Store:
    def __init__(self) -> None:
        self.client = _Client()


def test_database_records_converts_nan_nat_and_timestamp_to_json_scalars():
    frame = pd.DataFrame(
        {
            "ticker": ["BBCA"],
            "trade_date": [pd.Timestamp("2026-09-02")],
            "optional_number": [float("nan")],
            "optional_date": [pd.NaT],
        }
    )
    row = database_records(frame)[0]
    assert row["ticker"] == "BBCA"
    assert row["trade_date"] == "2026-09-02"
    assert row["optional_number"] is None
    assert row["optional_date"] is None


def test_stock_summary_normalization_is_factual_and_rejects_invalid_float():
    frame = pd.DataFrame(
        [
            {
                "ticker": "BBCA",
                "trade_date": "2026-09-02",
                "listed_shares": 1000,
                "tradable_shares": 900,
                "foreign_buy": 10,
                "foreign_sell": 3,
                "foreign_net": 7,
                "source": "ZAPI_IDX_STOCK_SUMMARY",
            },
            {
                "ticker": "FAKE",
                "trade_date": "2026-09-02",
                "listed_shares": 1000,
                "tradable_shares": 1500,
                "source": "ZAPI_IDX_STOCK_SUMMARY",
            },
        ]
    )
    out = normalize_stock_summary(frame)
    assert out["ticker"].tolist() == ["BBCA"]
    assert bool(out.iloc[0]["source_verified"]) is True
    assert out.iloc[0]["provenance_state"] == "VERIFIED_ZAPI_IDX_STOCK_SUMMARY_NOT_BROKER_IDENTITY"


def test_ownership_and_capital_actions_require_verified_provenance():
    holder_hash = "a" * 64
    ownership = pd.DataFrame(
        [
            {
                "ticker": "BBCA",
                "category": "company-profile",
                "holder_identity_hash": holder_hash,
                "holder_name": "Holder",
                "shares_held": 100,
                "ownership_percentage": 1.0,
                "report_date": "2026-09-02",
                "source_verified": True,
                "provenance_state": "VERIFIED_IDX_COMPANY_PROFILE_VIA_ZAPI",
            },
            {
                "ticker": "BBRI",
                "category": "company-profile",
                "holder_identity_hash": "b" * 64,
                "shares_held": 100,
                "report_date": "2026-09-02",
                "source_verified": False,
                "provenance_state": "VERIFIED_IDX_COMPANY_PROFILE_VIA_ZAPI",
            },
        ]
    )
    own = normalize_ownership(ownership)
    assert own["ticker"].tolist() == ["BBCA"]

    actions = pd.DataFrame(
        [
            {
                "ticker": "BBCA",
                "event_type": "RIGHTS_OFFERING",
                "event_date": "2026-09-03",
                "source_feed": "rights-offerings",
                "source_verified": True,
                "provenance_state": "VERIFIED_IDX_DATASET_VIA_ZAPI",
            },
            {
                "ticker": "BBRI",
                "event_type": "RIGHTS_OFFERING",
                "event_date": "2026-09-03",
                "source_feed": "rights-offerings",
                "source_verified": True,
                "provenance_state": "UNVERIFIED",
            },
        ]
    )
    cap = normalize_capital_actions(actions)
    assert cap["ticker"].tolist() == ["BBCA"]


def test_stock_summary_upsert_never_sends_non_finite_json_numbers():
    store = _Store()
    frame = pd.DataFrame(
        [
            {
                "ticker": "BBCA",
                "trade_date": "2026-09-02",
                "listed_shares": 1000,
                "tradable_shares": 900,
                "foreign_buy": 10,
                "foreign_sell": 3,
                "foreign_net": 7,
                "frequency": float("nan"),
                "source": "ZAPI_IDX_STOCK_SUMMARY",
            }
        ]
    )
    assert upsert_stock_summary(store, frame) == 1
    assert store.client.tables == ["flow_zapi_stock_summary"]
    payload = store.client.calls[0]["rows"][0]
    assert payload["frequency"] is None
    for value in payload.values():
        if isinstance(value, float):
            assert math.isfinite(value)
