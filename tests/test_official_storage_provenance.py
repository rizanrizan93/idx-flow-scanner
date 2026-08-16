from __future__ import annotations

from types import SimpleNamespace

import pandas as pd

from idx_flow_scanner.providers.idx_official import upsert_idx_official_flows


class _Table:
    def __init__(self):
        self.rows = []

    def upsert(self, rows, on_conflict=None):
        self.rows.extend(rows)
        return self

    def execute(self):
        return SimpleNamespace(data=self.rows)


class _Client:
    def __init__(self):
        self.tables = {}

    def table(self, name):
        self.tables.setdefault(name, _Table())
        return self.tables[name]


class _Store:
    def __init__(self):
        self.client = _Client()


def test_vendor_foreign_never_enters_official_idx_table():
    store = _Store()
    frame = pd.DataFrame([
        {
            "ticker": "ELSA",
            "trade_date": "2026-08-14",
            "foreign_buy": 2_000_000,
            "foreign_sell": 1_500_000,
            "foreign_net": 500_000,
            "volume": 10_000_000,
            "source": "ZAPI_IDX_STOCK_SUMMARY",
        }
    ])

    assert upsert_idx_official_flows(store, frame) == 0
    assert "flow_official_stock_flows" not in store.client.tables


def test_direct_idx_rows_are_persisted_to_official_table():
    store = _Store()
    frame = pd.DataFrame([
        {
            "ticker": "ELSA",
            "trade_date": "2026-08-14",
            "foreign_buy": 2_000_000,
            "foreign_sell": 1_500_000,
            "foreign_net": 500_000,
            "volume": 10_000_000,
            "source": "IDX_OFFICIAL_STOCK_SUMMARY",
        }
    ])

    assert upsert_idx_official_flows(store, frame) == 1
    rows = store.client.tables["flow_official_stock_flows"].rows
    assert len(rows) == 1
    assert rows[0]["source"] == "IDX_OFFICIAL_STOCK_SUMMARY"
