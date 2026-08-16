from __future__ import annotations

from datetime import date, timedelta
from typing import Any, Iterable

import numpy as np
import pandas as pd

from .data import canonical_ticker


def load_vendor_foreign_flows(
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
        resp = (
            store.client.table("flow_vendor_foreign_flows")
            .select(
                "ticker,trade_date,foreign_buy,foreign_sell,foreign_net,flow_unit,market_type,"
                "source,source_verified,source_url,provenance_state"
            )
            .in_("ticker", chunk)
            .gte("trade_date", since)
            .order("trade_date")
            .execute()
        )
        rows.extend(resp.data or [])
    if not rows:
        return pd.DataFrame()
    out = pd.DataFrame(rows)
    out["ticker"] = out["ticker"].map(canonical_ticker)
    out["trade_date"] = pd.to_datetime(out["trade_date"], errors="coerce").dt.normalize()
    return out.dropna(subset=["ticker", "trade_date"]).sort_values(["ticker", "trade_date"]).reset_index(drop=True)


def upsert_vendor_foreign_flows(store: Any, frame: pd.DataFrame) -> int:
    if store is None or frame is None or frame.empty:
        return 0
    cols = [
        "ticker", "trade_date", "foreign_buy", "foreign_sell", "foreign_net",
        "flow_unit", "market_type", "source", "source_verified", "source_url",
        "provenance_state",
    ]
    clean = frame.copy()
    for col in cols:
        if col not in clean.columns:
            clean[col] = None
    clean["ticker"] = clean["ticker"].map(canonical_ticker)
    clean["trade_date"] = pd.to_datetime(clean["trade_date"], errors="coerce").dt.date.astype("string")
    clean = clean.dropna(subset=["ticker", "trade_date"])
    clean = clean.replace({np.nan: None})
    rows = clean[cols].to_dict("records")
    for i in range(0, len(rows), 500):
        store.client.table("flow_vendor_foreign_flows").upsert(
            rows[i:i + 500], on_conflict="ticker,trade_date,source,market_type"
        ).execute()
    return len(rows)
