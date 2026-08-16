import pandas as pd

from idx_flow_scanner.database_first import _load_prices_per_ticker_json


# Regression contract: oversized caller values must be clamped before the RPC
# so free-tier PostgREST responses remain bounded during managed OHLCV_PREP.
def _payload(ticker: str, rows: int = 120):
    dates = pd.bdate_range("2026-01-02", periods=rows)
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


def test_per_ticker_rpc_bounds_chunk_and_bar_payload():
    calls = []

    class Response:
        def __init__(self, data):
            self.data = data

    class Request:
        def __init__(self, data):
            self.data = data

        def execute(self):
            return Response(self.data)

    class Client:
        def rpc(self, name, params):
            assert name == "flow_load_price_cache_by_ticker"
            calls.append(params.copy())
            tickers = params["p_tickers"]
            assert len(tickers) <= 8
            assert params["p_limit"] <= 160
            return Request([{"ticker": ticker, "payload": _payload(ticker, params["p_limit"])} for ticker in tickers])

    class Store:
        client = Client()

    names = [f"T{i:03d}" for i in range(19)]
    messages = []
    out = _load_prices_per_ticker_json(
        Store(),
        names,
        min_rows=80,
        limit=320,
        chunk_size=40,
        status=messages.append,
    )

    assert len(out) == 19
    assert [len(call["p_tickers"]) for call in calls] == [8, 8, 3]
    assert all(call["p_limit"] == 160 for call in calls)
    assert all(len(frame) == 160 for frame in out.values())
    assert any("19/19" in message for message in messages)
