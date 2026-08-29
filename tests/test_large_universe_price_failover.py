from __future__ import annotations

import numpy as np
import pandas as pd

import idx_flow_scanner.large_universe_prices as lup


def _frame(ticker: str, n: int = 80) -> pd.DataFrame:
    dates = pd.bdate_range("2026-04-20", periods=n)
    close = 100.0 + np.arange(n, dtype=float) * 0.1
    return pd.DataFrame(
        {
            "date": dates,
            "open": close - 0.5,
            "high": close + 1.0,
            "low": close - 1.0,
            "close": close,
            "volume": np.full(n, 1_000_000),
        }
    )


class _RpcCall:
    def __init__(self, *, raises: bool = False):
        self.raises = raises

    def execute(self):
        if self.raises:
            raise TimeoutError("simulated PostgREST timeout")
        return type("Response", (), {"data": []})()


class _Client:
    def __init__(self, *, raises: bool = False):
        self.raises = raises
        self.calls = 0

    def rpc(self, name, payload):
        assert name == "flow_load_price_cache_by_ticker"
        assert len(payload["p_tickers"]) <= lup.DB_CHUNK_SIZE
        self.calls += 1
        return _RpcCall(raises=self.raises)


class _Store:
    def __init__(self, *, raises: bool = False):
        self.client = _Client(raises=raises)

    def load_prices(self, *args, **kwargs):
        raise AssertionError("large-universe failover must not enter single-ticker DB reads")


def test_large_universe_rpc_failure_goes_directly_to_seed(monkeypatch):
    monkeypatch.setattr(lup, "_frame_recent_enough", lambda frame, **kwargs: True)
    names = [f"T{i:03d}" for i in range(100)]
    seed = {ticker: _frame(ticker) for ticker in names}
    monkeypatch.setattr(lup, "load_bundled_price_seed", lambda *a, **k: seed)
    monkeypatch.setattr(lup, "fetch_yfinance_prices_batch", lambda *a, **k: {})
    store = _Store(raises=True)

    load, stats = lup.prepare_large_universe_prices(names, store, min_rows=80)

    assert store.client.calls == 1
    assert stats["db_read_errors"] == 1
    assert stats["seed_hits"] == 100
    assert stats["unavailable"] == 0
    assert stats["bulk_cache_transport"] == "DB_RPC_FAILED_FAST_TO_SEED"
    assert len(load("T000")) == 80


def test_large_universe_repeated_empty_rpc_is_bounded(monkeypatch):
    monkeypatch.setattr(lup, "_frame_recent_enough", lambda frame, **kwargs: True)
    names = [f"T{i:03d}" for i in range(100)]
    seed = {ticker: _frame(ticker) for ticker in names}
    monkeypatch.setattr(lup, "load_bundled_price_seed", lambda *a, **k: seed)
    monkeypatch.setattr(lup, "fetch_yfinance_prices_batch", lambda *a, **k: {})
    store = _Store(raises=False)

    _, stats = lup.prepare_large_universe_prices(names, store, min_rows=80)

    assert store.client.calls == lup.MAX_CONSECUTIVE_EMPTY_DB_CHUNKS
    assert stats["seed_hits"] == 100
    assert stats["unavailable"] == 0
    assert stats["bulk_cache_transport"] == "DB_EMPTY_FAST_TO_SEED"


def test_large_universe_rejects_stale_seed_before_market_reference(monkeypatch):
    names = [f"T{i:03d}" for i in range(100)]
    stale = {ticker: _frame(ticker) for ticker in names}
    monkeypatch.setattr(lup, "load_bundled_price_seed", lambda *args, **kwargs: stale)
    monkeypatch.setattr(lup, "fetch_yfinance_prices_batch", lambda *args, **kwargs: {})
    store = _Store(raises=True)
    load, stats = lup.prepare_large_universe_prices(names, store, period="1y", min_rows=80)
    assert stats["seed_hits"] == 0
    assert stats["unavailable"] == 100
    assert stats["cache_freshness_contract"] == "MAX_7_CALENDAR_DAYS"
