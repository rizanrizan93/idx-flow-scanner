from __future__ import annotations

from dataclasses import dataclass
from datetime import date, timedelta

from idx_flow_scanner.verified_foreign_store import (
    IDX_OFFICIAL_STOCK_SUMMARY_SOURCE,
    load_verified_daily_foreign_flows,
)
from idx_flow_scanner.vendor_foreign_store import ZAPI_FOREIGN_FLOW_SOURCE


@dataclass
class _Response:
    data: list[dict[str, object]]


class _Query:
    SERVER_MAX_ROWS = 500

    def __init__(self, rows):
        self.rows = list(rows)
        self._range: tuple[int, int] | None = None

    def select(self, *_args, **_kwargs):
        return self

    def in_(self, column, values):
        allowed = set(values)
        self.rows = [row for row in self.rows if row.get(column) in allowed]
        return self

    def eq(self, column, value):
        self.rows = [row for row in self.rows if row.get(column) == value]
        return self

    def gte(self, *_args, **_kwargs):
        return self

    def order(self, column, *_args, **_kwargs):
        self.rows = sorted(self.rows, key=lambda row: str(row.get(column) or ""))
        return self

    def range(self, start, end):
        self._range = (int(start), int(end))
        return self

    def execute(self):
        if self._range is None:
            return _Response(self.rows[: self.SERVER_MAX_ROWS])
        start, end = self._range
        return _Response(self.rows[start : end + 1])


class _Client:
    def __init__(self, rows):
        self.rows = rows

    def table(self, name):
        assert name == "flow_vendor_foreign_flows"
        return _Query(self.rows)


class _Store:
    def __init__(self, rows):
        self.client = _Client(rows)


def _row(ticker, source, buy, sell, *, trade_date="2026-09-04"):
    return {
        "ticker": ticker,
        "trade_date": trade_date,
        "foreign_buy": buy,
        "foreign_sell": sell,
        "foreign_net": buy - sell,
        "volume": 10000,
        "traded_value": 1000000,
        "flow_unit": "SHARES",
        "market_type": "ALL",
        "source": source,
        "source_verified": True,
        "source_url": "https://example.test",
        "provenance_state": "VERIFIED",
    }


def test_official_idx_source_replaces_vendor_transport_for_same_ticker():
    store = _Store([
        _row("BBCA", ZAPI_FOREIGN_FLOW_SOURCE, 10, 3),
        _row("BBCA", IDX_OFFICIAL_STOCK_SUMMARY_SOURCE, 10, 3),
        _row("BBRI", ZAPI_FOREIGN_FLOW_SOURCE, 20, 5),
    ])

    out = load_verified_daily_foreign_flows(store, ["BBCA", "BBRI"])

    bbca = out[out["ticker"].eq("BBCA")]
    bbri = out[out["ticker"].eq("BBRI")]
    assert bbca["source"].tolist() == [IDX_OFFICIAL_STOCK_SUMMARY_SOURCE]
    assert bbri["source"].tolist() == [ZAPI_FOREIGN_FLOW_SOURCE]


def test_zapi_can_be_disabled_without_affecting_official_idx_rows():
    store = _Store([
        _row("BBCA", IDX_OFFICIAL_STOCK_SUMMARY_SOURCE, 10, 3),
        _row("BBRI", ZAPI_FOREIGN_FLOW_SOURCE, 20, 5),
    ])

    out = load_verified_daily_foreign_flows(
        store,
        ["BBCA", "BBRI"],
        allow_zapi_fallback=False,
    )

    assert out["ticker"].tolist() == ["BBCA"]
    assert out["source"].tolist() == [IDX_OFFICIAL_STOCK_SUMMARY_SOURCE]


def test_official_idx_history_is_not_truncated_by_postgrest_page_limit():
    tickers = [f"T{i:03d}" for i in range(40)]
    start = date.today() - timedelta(days=19)
    rows = []
    for ticker_index, ticker in enumerate(tickers):
        for day_offset in range(20):
            rows.append(
                _row(
                    ticker,
                    IDX_OFFICIAL_STOCK_SUMMARY_SOURCE,
                    1000 + ticker_index + day_offset,
                    100 + day_offset,
                    trade_date=(start + timedelta(days=day_offset)).isoformat(),
                )
            )

    assert len(rows) == 800
    out = load_verified_daily_foreign_flows(
        _Store(rows),
        tickers,
        lookback_calendar_days=120,
        allow_zapi_fallback=False,
    )

    assert len(out) == 800
    assert out["ticker"].nunique() == 40
    assert out.groupby("ticker")["trade_date"].nunique().eq(20).all()
