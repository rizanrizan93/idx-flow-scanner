from __future__ import annotations

from dataclasses import dataclass

import pandas as pd

from idx_flow_scanner.broker_behavior import load_official_broker_activity
from idx_flow_scanner.official_index_context import load_official_index_summary


@dataclass
class _Response:
    data: list[dict[str, object]]


class _Query:
    def __init__(self, rows):
        self.rows = list(rows)
        self._start = 0
        self._end = len(self.rows) - 1

    def select(self, *_args, **_kwargs):
        return self

    def eq(self, column, value):
        self.rows = [row for row in self.rows if row.get(column) == value]
        return self

    def gte(self, column, value):
        self.rows = [row for row in self.rows if str(row.get(column) or "") >= str(value)]
        return self

    def order(self, *_args, **_kwargs):
        return self

    def range(self, start, end):
        self._start = int(start)
        self._end = int(end)
        return self

    def execute(self):
        return _Response(self.rows[self._start : self._end + 1])


class _Client:
    def __init__(self, tables):
        self.tables = tables

    def table(self, name):
        return _Query(self.tables[name])


class _Store:
    def __init__(self, tables):
        self.client = _Client(tables)


def _broker_rows():
    rows = []
    dates = pd.bdate_range("2026-08-17", periods=15)
    for day in dates:
        for broker_no in range(88):
            rows.append(
                {
                    "trade_date": day.date().isoformat(),
                    "broker_code": f"B{broker_no:02d}",
                    "broker_name": f"Broker {broker_no:02d}",
                    "traded_value": float(1_000_000 + broker_no),
                    "volume": float(10_000 + broker_no),
                    "frequency": float(100 + broker_no),
                    "source": "IDX_OFFICIAL_BROKER_SUMMARY",
                    "source_verified": True,
                    "source_url": "https://block.idx.id/test",
                    "provenance_state": "VERIFIED_OFFICIAL_IDX_BROKER_SUMMARY",
                }
            )
    return rows


def _index_rows():
    rows = []
    dates = pd.bdate_range("2026-07-27", periods=30)
    codes = ["COMPOSITE"] + [f"IDXTEST{i:02d}" for i in range(44)]
    for day_no, day in enumerate(dates):
        for code_no, code in enumerate(codes):
            rows.append(
                {
                    "trade_date": day.date().isoformat(),
                    "index_code": code,
                    "close": float(1000 + day_no + code_no),
                    "source": "IDX_OFFICIAL_INDEX_SUMMARY",
                    "source_verified": True,
                    "source_url": "https://block.idx.id/test",
                    "provenance_state": "VERIFIED_OFFICIAL_IDX_INDEX_SUMMARY",
                }
            )
    return rows


def test_broker_loader_reads_all_pages_beyond_default_postgrest_cap():
    raw = _broker_rows()
    store = _Store({"flow_official_broker_activity": raw})

    out = load_official_broker_activity(store, lookback_calendar_days=120)

    assert len(raw) == 1320
    assert len(out) == 1320
    assert out["trade_date"].nunique() == 15
    assert out["trade_date"].max() == pd.Timestamp("2026-09-04")


def test_index_loader_reads_all_pages_beyond_default_postgrest_cap():
    raw = _index_rows()
    store = _Store({"flow_official_index_summary": raw})

    out = load_official_index_summary(store, lookback_calendar_days=140)

    assert len(raw) == 1350
    assert out is not None
    assert len(out) == 1350
    assert out["trade_date"].nunique() == 30
    assert out["trade_date"].max() == pd.Timestamp("2026-09-04")
