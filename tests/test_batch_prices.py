import pandas as pd

from idx_flow_scanner.data import _extract_yfinance_symbol, normalize_price_frame
from idx_flow_scanner.database_first import prepare_database_first_prices


def _price_frame(rows: int = 90) -> pd.DataFrame:
    dates = pd.date_range("2026-01-01", periods=rows, freq="D")
    return pd.DataFrame({
        "date": dates,
        "open": range(100, 100 + rows),
        "high": range(101, 101 + rows),
        "low": range(99, 99 + rows),
        "close": range(100, 100 + rows),
        "volume": [1000] * rows,
    })


def test_extract_yfinance_symbol_from_ticker_first_multiindex():
    dates = pd.date_range("2026-01-01", periods=3, freq="D")
    columns = pd.MultiIndex.from_product([
        ["AAA.JK", "BBB.JK"],
        ["Open", "High", "Low", "Close", "Volume"],
    ])
    raw = pd.DataFrame(
        [
            [10, 11, 9, 10, 1000, 20, 21, 19, 20, 2000],
            [11, 12, 10, 11, 1100, 21, 22, 20, 21, 2100],
            [12, 13, 11, 12, 1200, 22, 23, 21, 22, 2200],
        ],
        index=dates,
        columns=columns,
    )
    raw.index.name = "Date"

    out = _extract_yfinance_symbol(raw, "BBB.JK", "BBB")

    assert len(out) == 3
    assert out["ticker"].iloc[-1] == "BBB"
    assert float(out["close"].iloc[-1]) == 22.0


def test_normalize_price_frame_keeps_raw_close_when_adj_close_is_present():
    dates = pd.date_range("2026-01-01", periods=3, freq="D")
    raw = pd.DataFrame({
        "Open": [100.0, 101.0, 102.0],
        "High": [103.0, 104.0, 105.0],
        "Low": [99.0, 100.0, 101.0],
        "Close": [102.0, 103.0, 104.0],
        "Adj Close": [51.0, 51.5, 52.0],
        "Volume": [1000, 1100, 1200],
    }, index=dates)
    raw.index.name = "Date"

    out = normalize_price_frame(raw, "AAA")

    assert out["close"].tolist() == [102.0, 103.0, 104.0]
    assert out.columns.tolist() == ["ticker", "date", "open", "high", "low", "close", "volume"]


def test_normalize_price_frame_uses_adj_close_only_when_raw_close_missing():
    dates = pd.date_range("2026-01-01", periods=2, freq="D")
    raw = pd.DataFrame({
        "Open": [100.0, 101.0],
        "High": [103.0, 104.0],
        "Low": [99.0, 100.0],
        "Adj Close": [102.0, 103.0],
        "Volume": [1000, 1100],
    }, index=dates)
    raw.index.name = "Date"

    out = normalize_price_frame(raw, "AAA")

    assert out["close"].tolist() == [102.0, 103.0]


def test_prepare_database_first_prices_uses_cache_then_batch(monkeypatch):
    cached = _price_frame()
    fresh = _price_frame()

    class FakeStore:
        def __init__(self):
            self.persisted = []

        def load_prices(self, ticker, min_rows=80):
            return cached if ticker == "AAA" else pd.DataFrame()

        def upsert_prices(self, ticker, frame, source="YFINANCE"):
            self.persisted.append((ticker, source, len(frame)))
            return len(frame)

    def fake_batch(tickers, period="1y"):
        assert tickers == ["BBB"]
        return {"BBB": fresh}

    monkeypatch.setattr("idx_flow_scanner.database_first.fetch_yfinance_prices_batch", fake_batch)
    store = FakeStore()

    loader, stats = prepare_database_first_prices(["AAA", "BBB"], store, period="1y")

    assert len(loader("AAA")) == 90
    assert len(loader("BBB")) == 90
    assert stats["cache_hits"] == 1
    assert stats["fetched_valid"] == 1
    assert stats["unavailable"] == 0
    assert store.persisted == [("BBB", "YFINANCE_BATCH", 90)]
