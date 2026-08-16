import pandas as pd

from idx_flow_scanner.database_first import prepare_database_first_prices


def _frame(ticker: str, rows: int = 90) -> pd.DataFrame:
    dates = pd.date_range("2026-01-01", periods=rows, freq="D")
    return pd.DataFrame({
        "ticker": [ticker] * rows,
        "date": dates,
        "open": range(100, 100 + rows),
        "high": range(101, 101 + rows),
        "low": range(99, 99 + rows),
        "close": range(100, 100 + rows),
        "volume": [1000] * rows,
    })


def test_prepare_database_first_prices_prefers_bulk_store(monkeypatch):
    class BulkStore:
        def __init__(self):
            self.bulk_calls = 0
            self.single_calls = 0

        def load_prices_bulk(self, tickers, *, min_rows=80, limit=450, chunk_size=20, progress=None):
            self.bulk_calls += 1
            if progress:
                progress(len(tickers), len(tickers), len(tickers))
            return {ticker: _frame(ticker) for ticker in tickers}

        def load_prices(self, ticker, min_rows=80):
            self.single_calls += 1
            raise AssertionError("single-ticker DB path must not run when bulk RPC succeeds")

    def fail_fetch(*args, **kwargs):
        raise AssertionError("Yahoo must not run when bulk cache is complete")

    monkeypatch.setattr("idx_flow_scanner.database_first.fetch_yfinance_prices_batch", fail_fetch)
    store = BulkStore()
    messages = []
    loader, stats = prepare_database_first_prices(
        ["AAA", "BBB"], store, period="1y", status=messages.append
    )

    assert store.bulk_calls == 1
    assert store.single_calls == 0
    assert stats["bulk_cache_used"] is True
    assert stats["cache_hits"] == 2
    assert stats["unavailable"] == 0
    assert len(loader("AAA")) == 90
    assert any("2/2" in message for message in messages)


def test_bulk_store_incomplete_subset_uses_seed_not_single_db(monkeypatch, tmp_path):
    seed = pd.concat([_frame("BBB")], ignore_index=True)
    seed_path = tmp_path / "seed.csv.gz"
    seed.to_csv(seed_path, index=False, compression="gzip")

    class BulkStore:
        def __init__(self):
            self.single_calls = 0
            self.persisted = []

        def load_prices_bulk(self, tickers, **kwargs):
            return {"AAA": _frame("AAA")}

        def load_prices(self, ticker, min_rows=80):
            self.single_calls += 1
            return pd.DataFrame()

        def upsert_prices(self, ticker, frame, source="YFINANCE"):
            self.persisted.append((ticker, source))
            return len(frame)

    monkeypatch.setattr(
        "idx_flow_scanner.database_first.fetch_yfinance_prices_batch",
        lambda *args, **kwargs: {},
    )
    store = BulkStore()
    loader, stats = prepare_database_first_prices(
        ["AAA", "BBB"], store, period="1y", seed_path=seed_path
    )

    assert store.single_calls == 0
    assert stats["cache_hits"] == 1
    assert stats["seed_hits"] == 1
    assert stats["unavailable"] == 0
    assert len(loader("BBB")) == 90
