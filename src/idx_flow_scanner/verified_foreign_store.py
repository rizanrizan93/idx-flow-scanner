from __future__ import annotations

from datetime import date, timedelta
from typing import Any, Iterable

import pandas as pd

from .data import canonical_ticker
from .vendor_foreign_store import ZAPI_VENDOR_SOURCES

IDX_OFFICIAL_STOCK_SUMMARY_SOURCE = "IDX_OFFICIAL_STOCK_SUMMARY"
VERIFIED_DAILY_SHARE_SOURCES = frozenset(
    {IDX_OFFICIAL_STOCK_SUMMARY_SOURCE, *ZAPI_VENDOR_SOURCES}
)

_QUERY_CHUNK_SIZE = 40
_QUERY_PAGE_SIZE = 500
_SELECT_COLUMNS = (
    "ticker,trade_date,foreign_buy,foreign_sell,foreign_net,volume,traded_value,"
    "flow_unit,market_type,source,source_verified,source_url,provenance_state"
)


def _fetch_source_rows(
    store: Any,
    tickers: list[str],
    sources: Iterable[str],
    *,
    since: str,
) -> list[dict[str, object]]:
    """Fetch one source class with explicit PostgREST pagination.

    Supabase/PostgREST installations commonly cap a response page. Foreign-flow
    history can exceed that cap even for a modest ticker chunk, so an unpaged
    query silently truncates ticker/date coverage. Pagination is part of the
    evidence contract rather than an optimization.
    """
    source_names = sorted({str(source) for source in sources if str(source)})
    if not tickers or not source_names:
        return []

    rows: list[dict[str, object]] = []
    offset = 0
    while True:
        response = (
            store.client.table("flow_vendor_foreign_flows")
            .select(_SELECT_COLUMNS)
            .in_("ticker", tickers)
            .in_("source", source_names)
            .eq("flow_unit", "SHARES")
            .eq("source_verified", True)
            .gte("trade_date", since)
            .order("trade_date")
            .range(offset, offset + _QUERY_PAGE_SIZE - 1)
            .execute()
        )
        batch = list(response.data or [])
        rows.extend(batch)
        if len(batch) < _QUERY_PAGE_SIZE:
            break
        offset += _QUERY_PAGE_SIZE
    return rows


def load_verified_daily_foreign_flows(
    store: Any,
    universe: Iterable[str],
    *,
    lookback_calendar_days: int = 120,
    allow_zapi_fallback: bool = True,
) -> pd.DataFrame:
    """Load verified daily foreign buy/sell share evidence from Supabase.

    Official IDX Stock Summary is authoritative. It is fetched first and with
    explicit pagination. ZAPI rows are then fetched only for tickers that have
    no official IDX rows in the requested database window, so the scanner cannot
    double-count two transports of the same underlying IDX observation.
    Unknown sources, non-share units and unverified rows are ignored.
    """
    names = list(
        dict.fromkeys(canonical_ticker(t) for t in universe if canonical_ticker(t))
    )
    if store is None or not names:
        return pd.DataFrame()

    since = (date.today() - timedelta(days=int(lookback_calendar_days))).isoformat()
    rows: list[dict[str, object]] = []
    try:
        for i in range(0, len(names), _QUERY_CHUNK_SIZE):
            chunk = names[i : i + _QUERY_CHUNK_SIZE]
            official_rows = _fetch_source_rows(
                store,
                chunk,
                [IDX_OFFICIAL_STOCK_SUMMARY_SOURCE],
                since=since,
            )
            rows.extend(official_rows)

            if not allow_zapi_fallback:
                continue

            official_tickers = {
                canonical_ticker(row.get("ticker"))
                for row in official_rows
                if canonical_ticker(row.get("ticker"))
            }
            fallback_tickers = [
                ticker for ticker in chunk if ticker not in official_tickers
            ]
            if fallback_tickers:
                rows.extend(
                    _fetch_source_rows(
                        store,
                        fallback_tickers,
                        ZAPI_VENDOR_SOURCES,
                        since=since,
                    )
                )
    except Exception:
        return pd.DataFrame()

    if not rows:
        return pd.DataFrame()

    allowed = (
        VERIFIED_DAILY_SHARE_SOURCES
        if allow_zapi_fallback
        else frozenset({IDX_OFFICIAL_STOCK_SUMMARY_SOURCE})
    )
    out = pd.DataFrame(rows)
    out["ticker"] = out["ticker"].map(canonical_ticker)
    out["trade_date"] = pd.to_datetime(
        out["trade_date"], errors="coerce"
    ).dt.normalize()
    out = out.dropna(subset=["ticker", "trade_date"]).copy()
    out = out[out["source"].astype(str).isin(allowed)].copy()
    if out.empty:
        return out

    # Defensive precedence after retrieval as well: once a ticker has verified
    # official IDX history, vendor transport rows for that ticker are excluded.
    official_tickers = set(
        out.loc[
            out["source"].eq(IDX_OFFICIAL_STOCK_SUMMARY_SOURCE), "ticker"
        ]
        .dropna()
        .astype(str)
    )
    if official_tickers:
        out = out[
            out["source"].eq(IDX_OFFICIAL_STOCK_SUMMARY_SOURCE)
            | ~out["ticker"].isin(official_tickers)
        ].copy()

    return (
        out.drop_duplicates(
            ["ticker", "trade_date", "source", "market_type"], keep="last"
        )
        .sort_values(["ticker", "trade_date", "source"], kind="stable")
        .reset_index(drop=True)
    )
