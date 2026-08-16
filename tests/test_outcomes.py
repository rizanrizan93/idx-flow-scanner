from __future__ import annotations

from types import SimpleNamespace

import numpy as np
import pandas as pd

from idx_flow_scanner.outcomes import compute_signal_outcome, refresh_pending_outcomes


def _prices(periods: int = 90) -> pd.DataFrame:
    dates = pd.bdate_range("2026-01-02", periods=periods)
    close = 100 + np.arange(periods, dtype=float)
    return pd.DataFrame({
        "date": dates,
        "open": close - 0.5,
        "high": close + 1.0,
        "low": close - 1.0,
        "close": close,
        "volume": 1_000_000,
    })


def test_forward_outcome_uses_only_future_bars_after_signal():
    price = _prices()
    dates = price["date"]
    out = compute_signal_outcome(price, dates.iloc[10])
    assert round(out.entry_close, 6) == 110.0
    assert round(out.return_5d, 6) == round(100 * (115 / 110 - 1), 6)
    assert round(out.return_20d, 6) == round(100 * (130 / 110 - 1), 6)
    assert out.return_60d is not None
    assert out.evaluation_status == "COMPLETE"


def test_missing_signal_date_does_not_slide_entry_forward():
    price = _prices()
    missing = pd.Timestamp(price["date"].iloc[10])
    price = price[price["date"] != missing].reset_index(drop=True)
    out = compute_signal_outcome(price, missing)
    assert out.entry_close is None
    assert out.return_5d is None
    assert out.evaluation_status == "PENDING"


def test_forward_split_like_gap_is_excluded_from_oos_returns():
    price = _prices()
    signal_i = 10
    split_i = signal_i + 3
    prev_close = float(price.loc[split_i - 1, "close"])
    split_open = prev_close * 0.5
    price.loc[split_i, ["open", "high", "low", "close"]] = [split_open, split_open * 1.02, split_open * 0.98, split_open * 1.01]

    out = compute_signal_outcome(price, price.loc[signal_i, "date"])

    assert out.entry_close == float(price.loc[signal_i, "close"])
    assert out.evaluation_status == "EXCLUDED"
    assert out.evaluation_note == "CORPORATE_ACTION_LIKE_GAP_IN_FORWARD_WINDOW"
    assert out.return_5d is None
    assert out.return_20d is None
    assert out.return_60d is None
    assert out.mfe_20d is None
    assert out.mae_20d is None


class _FakeTable:
    def __init__(self, rows, writes):
        self.rows = rows
        self.writes = writes
        self.start = 0
        self.end = len(rows) - 1

    def select(self, *_args, **_kwargs): return self
    def in_(self, *_args, **_kwargs): return self
    def order(self, *_args, **_kwargs): return self
    def range(self, start, end):
        self.start, self.end = int(start), int(end)
        return self
    def execute(self):
        return SimpleNamespace(data=self.rows[self.start:self.end + 1])
    def upsert(self, payload, **_kwargs):
        self.writes.extend(payload)
        return _FakeWrite()


class _FakeWrite:
    def execute(self): return SimpleNamespace(data=[])


class _FakeClient:
    def __init__(self, rows):
        self.rows = rows
        self.writes = []
    def table(self, _name): return _FakeTable(self.rows, self.writes)


class _FakeStore:
    def __init__(self, rows): self.client = _FakeClient(rows)


def test_refresh_pages_all_open_rows_and_loads_price_once_per_ticker():
    price = _prices()
    d10 = price["date"].iloc[10].date().isoformat()
    d11 = price["date"].iloc[11].date().isoformat()
    rows = [
        {"run_id":"00000000-0000-0000-0000-000000000001","ticker":"AAA","as_of_date":d10,"evaluation_status":"PENDING","evaluated_through":None},
        {"run_id":"00000000-0000-0000-0000-000000000002","ticker":"AAA","as_of_date":d11,"evaluation_status":"PENDING","evaluated_through":None},
        {"run_id":"00000000-0000-0000-0000-000000000003","ticker":"BBB","as_of_date":d10,"evaluation_status":"PENDING","evaluated_through":None},
    ]
    store = _FakeStore(rows)
    calls = []
    def loader(ticker):
        calls.append(ticker)
        return price

    stats = refresh_pending_outcomes(store, ["AAA","BBB"], loader, page_size=2, max_rows=10)
    assert stats["checked"] == 3
    assert stats["updated"] == 3
    assert stats["complete"] == 3
    assert stats["excluded"] == 0
    assert calls == ["AAA","BBB"]
    assert len(store.client.writes) == 3
