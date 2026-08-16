from __future__ import annotations

from datetime import date, timedelta
from typing import Any, Iterable

import pandas as pd

from .data import canonical_ticker

ZAPI_FOREIGN_FLOW_SOURCE = "ZAPI_IDX_FOREIGN_FLOW"
ZAPI_STOCK_SUMMARY_SOURCE = "ZAPI_IDX_STOCK_SUMMARY"
ZAPI_VENDOR_SOURCES = frozenset({ZAPI_FOREIGN_FLOW_SOURCE, ZAPI_STOCK_SUMMARY_SOURCE})
ZAPI_SOURCE_URLS = {
    ZAPI_FOREIGN_FLOW_SOURCE: "https://api.zpi.web.id/v1/finance:idx/foreign-flow",
    ZAPI_STOCK_SUMMARY_SOURCE: "https://api.zpi.web.id/v1/finance:idx/stock-summary",
}


def normalize_zapi_vendor_foreign(frame: pd.DataFrame | None) -> pd.DataFrame:
    """Normalize authenticated Zapi IDX-derived foreign transport for vendor storage.

    This path is intentionally separate from ``flow_official_stock_flows``. Zapi
    exposes IDX-derived share data through an authenticated vendor transport, so
    provenance is verified as vendor-derived but is never relabelled direct IDX.
    """
    if frame is None or frame.empty:
        return pd.DataFrame()
    out = frame.copy()
    required = {"ticker", "trade_date", "foreign_buy", "foreign_sell", "source"}
    if not required.issubset(out.columns):
        return pd.DataFrame()
    out["source"] = out["source"].fillna("").astype(str)
    out = out[out["source"].isin(ZAPI_VENDOR_SOURCES)].copy()
    if out.empty:
        return pd.DataFrame()
    out["ticker"] = out["ticker"].map(canonical_ticker)
    out["trade_date"] = pd.to_datetime(out["trade_date"], errors="coerce").dt.normalize()
    out = out.dropna(subset=["ticker", "trade_date"])
    for col in ("foreign_buy", "foreign_sell", "foreign_net", "volume", "traded_value"):
        if col not in out.columns:
            out[col] = 0.0
        out[col] = pd.to_numeric(out[col], errors="coerce").fillna(0.0)
    # Recompute net from the two source legs. This avoids trusting a stale derived
    # field while preserving the provider's raw buy/sell share counts.
    out["foreign_net"] = out["foreign_buy"] - out["foreign_sell"]
    out["flow_unit"] = "SHARES"
    out["market_type"] = "ALL"
    out["source_verified"] = True
    out["source_url"] = out["source"].map(ZAPI_SOURCE_URLS)
    out["provenance_state"] = "VENDOR_AUTHENTICATED_IDX_DERIVED"
    cols = [
        "ticker", "trade_date", "foreign_buy", "foreign_sell", "foreign_net",
        "volume", "traded_value", "flow_unit", "market_type", "source",
        "source_verified", "source_url", "provenance_state",
    ]
    return out[cols].drop_duplicates(
        ["ticker", "trade_date", "source", "market_type"], keep="last"
    ).sort_values(["ticker", "trade_date", "source"], kind="stable").reset_index(drop=True)


def _records(frame: pd.DataFrame) -> list[dict[str, object]]:
    rows: list[dict[str, object]] = []
    for row in frame.to_dict("records"):
        item: dict[str, object] = {}
        for key, value in row.items():
            if isinstance(value, pd.Timestamp):
                item[key] = value.date().isoformat()
            elif hasattr(value, "item"):
                try:
                    item[key] = value.item()
                except Exception:
                    item[key] = value
            else:
                item[key] = value
        rows.append(item)
    return rows


def upsert_zapi_vendor_foreign_flows(store: Any, frame: pd.DataFrame | None) -> int:
    clean = normalize_zapi_vendor_foreign(frame)
    if store is None or clean.empty:
        return 0
    rows = _records(clean)
    for i in range(0, len(rows), 500):
        store.client.table("flow_vendor_foreign_flows").upsert(
            rows[i:i + 500],
            on_conflict="ticker,trade_date,source,market_type",
        ).execute()
    return len(rows)


def load_zapi_vendor_foreign_flows(
    store: Any,
    universe: Iterable[str],
    *,
    lookback_calendar_days: int = 120,
) -> pd.DataFrame:
    names = list(dict.fromkeys(canonical_ticker(t) for t in universe if canonical_ticker(t)))
    if store is None or not names:
        return pd.DataFrame()
    since = (date.today() - timedelta(days=int(lookback_calendar_days))).isoformat()
    rows: list[dict[str, object]] = []
    for i in range(0, len(names), 40):
        chunk = names[i:i + 40]
        response = (
            store.client.table("flow_vendor_foreign_flows")
            .select(
                "ticker,trade_date,foreign_buy,foreign_sell,foreign_net,volume,traded_value,"
                "flow_unit,market_type,source,source_verified,source_url,provenance_state"
            )
            .in_("ticker", chunk)
            .eq("flow_unit", "SHARES")
            .eq("source_verified", True)
            .gte("trade_date", since)
            .order("trade_date")
            .execute()
        )
        rows.extend(response.data or [])
    if not rows:
        return pd.DataFrame()
    out = pd.DataFrame(rows)
    out = out[out["source"].astype(str).isin(ZAPI_VENDOR_SOURCES)].copy()
    out["ticker"] = out["ticker"].map(canonical_ticker)
    out["trade_date"] = pd.to_datetime(out["trade_date"], errors="coerce").dt.normalize()
    return out.dropna(subset=["ticker", "trade_date"]).sort_values(
        ["ticker", "trade_date", "source"], kind="stable"
    ).reset_index(drop=True)
