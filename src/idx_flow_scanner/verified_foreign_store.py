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


def load_verified_daily_foreign_flows(
    store: Any,
    universe: Iterable[str],
    *,
    lookback_calendar_days: int = 120,
    allow_zapi_fallback: bool = True,
) -> pd.DataFrame:
    """Load verified daily foreign buy/sell share evidence from Supabase.

    Official IDX Stock Summary is authoritative. ZAPI rows are retained only for
    tickers that have no official IDX rows in the requested database window, so
    the scanner cannot double-count two transports of the same underlying IDX
    observation. Unknown sources, non-share units and unverified rows are ignored.
    """
    names = list(dict.fromkeys(canonical_ticker(t) for t in universe if canonical_ticker(t)))
    if store is None or not names:
        return pd.DataFrame()

    since = (date.today() - timedelta(days=int(lookback_calendar_days))).isoformat()
    allowed = (
        VERIFIED_DAILY_SHARE_SOURCES
        if allow_zapi_fallback
        else frozenset({IDX_OFFICIAL_STOCK_SUMMARY_SOURCE})
    )
    rows: list[dict[str, object]] = []
    try:
        for i in range(0, len(names), 40):
            chunk = names[i:i + 40]
            response = (
                store.client.table("flow_vendor_foreign_flows")
                .select(
                    "ticker,trade_date,foreign_buy,foreign_sell,foreign_net,volume,traded_value,"
                    "flow_unit,market_type,source,source_verified,source_url,provenance_state"
                )
                .in_("ticker", chunk)
                .in_("source", sorted(allowed))
                .eq("flow_unit", "SHARES")
                .eq("source_verified", True)
                .gte("trade_date", since)
                .order("trade_date")
                .execute()
            )
            rows.extend(response.data or [])
    except Exception:
        return pd.DataFrame()

    if not rows:
        return pd.DataFrame()

    out = pd.DataFrame(rows)
    out["ticker"] = out["ticker"].map(canonical_ticker)
    out["trade_date"] = pd.to_datetime(out["trade_date"], errors="coerce").dt.normalize()
    out = out.dropna(subset=["ticker", "trade_date"]).copy()
    out = out[out["source"].astype(str).isin(allowed)].copy()
    if out.empty:
        return out

    # Source-level precedence, not row summation: once a ticker has verified
    # official IDX history, vendor transport rows for that ticker are excluded.
    official_tickers = set(
        out.loc[out["source"].eq(IDX_OFFICIAL_STOCK_SUMMARY_SOURCE), "ticker"]
        .dropna()
        .astype(str)
    )
    if official_tickers:
        out = out[
            out["source"].eq(IDX_OFFICIAL_STOCK_SUMMARY_SOURCE)
            | ~out["ticker"].isin(official_tickers)
        ].copy()

    return out.drop_duplicates(
        ["ticker", "trade_date", "source", "market_type"], keep="last"
    ).sort_values(["ticker", "trade_date", "source"], kind="stable").reset_index(drop=True)
