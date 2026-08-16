from __future__ import annotations

from types import SimpleNamespace

import pandas as pd

from idx_flow_scanner.database_first import _load_prices_bulk_json


class _RpcCall:
    def __init__(self, payload):
        self._payload = payload

    def execute(self):
        return SimpleNamespace(data=[{"payload": self._payload}])


class _Client:
    def __init__(self, payload):
        self.payload = payload
        self.calls = []

    def rpc(self, name, params):
        self.calls.append((name, params))
        return _RpcCall(self.payload)


class _Store:
    def __init__(self, payload):
        self.client = _Client(payload)


def _payload(tickers=("AAAA", "BBBB"), bars=100):
    out = []
    dates = pd.bdate_range("2026-01-02", periods=bars)
    for offset, ticker in enumerate(tickers):
        for i, day in enumerate(dates):
            close = 100.0 + offset * 10 + i * 0.1
            out.append({
                "ticker": ticker,
                "trade_date": day.date().isoformat(),
                "open": close - 0.5,
                "high": close + 1.0,
                "low": close - 1.0,
                "close": close,
                "volume": 1_000_000,
            })
    return out


def test_json_bulk_price_rpc_recovers_all_tickers_without_rowset_truncation():
    store = _Store(_payload())
    result = _load_prices_bulk_json(
        store,
        ["AAAA", "BBBB"],
        min_rows=80,
        limit=450,
        chunk_size=20,
    )

    assert set(result) == {"AAAA", "BBBB"}
    assert len(result["AAAA"]) == 100
    assert len(result["BBBB"]) == 100
    assert store.client.calls[0][0] == "flow_load_price_cache_json"


def test_json_bulk_price_rpc_drops_incomplete_ticker_only():
    payload = _payload(("AAAA",), bars=100) + _payload(("BBBB",), bars=50)
    store = _Store(payload)
    result = _load_prices_bulk_json(
        store,
        ["AAAA", "BBBB"],
        min_rows=80,
        limit=450,
        chunk_size=20,
    )

    assert set(result) == {"AAAA"}
