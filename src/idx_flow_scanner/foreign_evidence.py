from __future__ import annotations

from typing import Callable, Iterable

import pandas as pd

from .data import canonical_ticker

DIRECT_IDX_SOURCE = "IDX_OFFICIAL_STOCK_SUMMARY"
ZAPI_IDX_SOURCE = "ZAPI_IDX_FOREIGN_FLOW"
ZAPI_STOCK_SUMMARY_SOURCE = "ZAPI_IDX_STOCK_SUMMARY"
ZAPI_SOURCES = frozenset({ZAPI_IDX_SOURCE, ZAPI_STOCK_SUMMARY_SOURCE})
SOURCE_PRIORITY = {
    DIRECT_IDX_SOURCE: 2,
    ZAPI_IDX_SOURCE: 1,
    ZAPI_STOCK_SUMMARY_SOURCE: 1,
}


def _coverage(frame: pd.DataFrame, price: pd.DataFrame, lookback: int = 20) -> float:
    if frame is None or frame.empty or price is None or price.empty:
        return 0.0
    px_days = pd.DatetimeIndex(pd.to_datetime(price["date"], errors="coerce").dropna().unique())[-lookback:]
    flow_days = pd.DatetimeIndex(pd.to_datetime(frame["trade_date"], errors="coerce").dropna().unique())
    return 100.0 * len(px_days.intersection(flow_days)) / max(len(px_days), 1)


def prepare_foreign_evidence(
    universe: Iterable[str],
    candidates: pd.DataFrame,
    price_loader: Callable[[str], pd.DataFrame],
    *,
    lookback: int = 20,
) -> tuple[pd.DataFrame, dict[str, object]]:
    """Choose exactly one share-unit foreign source per ticker.

    Direct IDX and Zapi IDX-derived foreign flow both expose share counts. The
    selector still never concatenates two providers for a ticker because doing so
    would double-count the same exchange activity. Highest trading-day coverage
    wins; an exact tie prefers the direct IDX endpoint.
    """
    frame = candidates.copy() if candidates is not None else pd.DataFrame()
    if not frame.empty:
        frame["ticker"] = frame["ticker"].map(canonical_ticker)
        frame["trade_date"] = pd.to_datetime(frame["trade_date"], errors="coerce").dt.normalize()
        frame["source"] = frame.get("source", "UNKNOWN").fillna("UNKNOWN").astype(str)

    selected: list[pd.DataFrame] = []
    counts = {DIRECT_IDX_SOURCE: 0, "ZAPI": 0, "OTHER": 0, "NONE": 0}
    coverage_values: list[float] = []

    for raw_ticker in universe:
        ticker = canonical_ticker(raw_ticker)
        price = price_loader(ticker)
        ticker_rows = frame[frame["ticker"] == ticker].copy() if not frame.empty else pd.DataFrame()
        if ticker_rows.empty:
            counts["NONE"] += 1
            coverage_values.append(0.0)
            continue

        options: list[tuple[float, int, str, pd.DataFrame]] = []
        for source, source_rows in ticker_rows.groupby("source", observed=True):
            coverage = _coverage(source_rows, price, lookback)
            priority = SOURCE_PRIORITY.get(str(source), 0)
            options.append((coverage, priority, str(source), source_rows.copy()))
        options.sort(key=lambda item: (item[0], item[1], item[2]), reverse=True)
        coverage, _, source, chosen = options[0]
        if coverage <= 0:
            counts["NONE"] += 1
            coverage_values.append(0.0)
            continue

        chosen["flow_unit"] = "SHARES"
        chosen["foreign_evidence_source"] = source
        selected.append(chosen)
        if source == DIRECT_IDX_SOURCE:
            counts[DIRECT_IDX_SOURCE] += 1
        elif source in ZAPI_SOURCES:
            counts["ZAPI"] += 1
        else:
            counts["OTHER"] += 1
        coverage_values.append(float(coverage))

    out = pd.concat(selected, ignore_index=True) if selected else pd.DataFrame()
    stats = {
        "idx_direct_selected_tickers": counts[DIRECT_IDX_SOURCE],
        "zapi_selected_tickers": counts["ZAPI"],
        "other_selected_tickers": counts["OTHER"],
        "foreign_unavailable_tickers": counts["NONE"],
        "median_selected_coverage_pct": float(pd.Series(coverage_values).median()) if coverage_values else 0.0,
    }
    return out, stats
