import pandas as pd

from idx_flow_scanner.database_first import prepare_database_first_prices


def _payload(start: str = "2026-01-01", rows: int = 90):
    dates = pd.date_range(start, periods=rows, freq="D")
    return [
        {
            "trade_date": d.date().isoformat(),
            "open": 100 + i,
            "high": 101 + i,
            "low": 99 + i,
            "close": 100 + i,
            "volume": 1_000_000,
        }
        for i, d in enumerate(dates)
    ]


class _Response:
    def __init__(self, data):
        self.data = data


class _RpcCall:
    def __init__(self, data):
        self.data = data

    def execute(self):
        return _Response(self.data)


class _Client:
    def __init__(self):
        self.calls = []

    def rpc(self, name, params):
        self.calls.append((name, params))
        assert name == "flow_load_price_cache_by_ticker"
        return _RpcCall([
            {"ticker": ticker, "payload": _payload()}
            for ticker in params["p_tickers"]
        ])


class _Store:
    def __init__(self):
        self.client = _Client()
        self.legacy_calls = 0

    def load_prices_bulk(self, *args, **kwargs):
        self.legacy_calls += 1
        raise AssertionError("legacy rowset RPC must not run when per-ticker transport succeeds")

    def load_prices(self, *args, **kwargs):
        raise AssertionError("single ticker fallback must not run")


def test_per_ticker_rpc_is_preferred_and_uses_bounded_batches(monkeypatch):
    store = _Store()
    universe = [f"T{i:03d}" for i in range(85)]

    monkeypatch.setattr(
        "idx_flow_scanner.database_first.fetch_yfinance_prices_batch",
        lambda *args, **kwargs: (_ for _ in ()).throw(AssertionError("Yahoo must not run")),
    )

    loader, stats = prepare_database_first_prices(universe, store, min_rows=80)

    assert stats["bulk_cache_used"] is True
    assert stats["bulk_cache_transport"] == "PER_TICKER_JSON_RPC_BOUNDED"
    assert stats["cache_hits"] == 85
    assert stats["unavailable"] == 0
    assert store.legacy_calls == 0
    batch_sizes = [len(params["p_tickers"]) for _, params in store.client.calls]
    assert batch_sizes == [8] * 10 + [5]
    assert all(params["p_limit"] == 120 for _, params in store.client.calls)
    assert all(name == "flow_load_price_cache_by_ticker" for name, _ in store.client.calls)
    assert len(loader("T084")) == 90
