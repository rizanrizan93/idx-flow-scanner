from __future__ import annotations

from typing import Any

import pandas as pd

from .slow_evidence_store import (
    load_capital_actions,
    load_ownership,
    load_stock_summary,
    merge_capital_actions,
    merge_ownership,
    merge_stock_summary,
    normalize_capital_actions,
    normalize_ownership,
    normalize_stock_summary,
)


def database_records(frame: pd.DataFrame | None) -> list[dict[str, object]]:
    """Convert normalized evidence rows into strict JSON/PostgREST records.

    pandas float/datetime dtypes can retain NaN/NaT even after DataFrame.where.
    PostgREST expects JSON null instead. Normalize every scalar explicitly before
    any upsert so database writes cannot emit NaN/NaT tokens.
    """
    if frame is None or frame.empty:
        return []

    rows: list[dict[str, object]] = []
    for row in frame.to_dict("records"):
        item: dict[str, object] = {}
        for key, value in row.items():
            try:
                missing = bool(pd.isna(value))
            except (TypeError, ValueError):
                missing = False
            if missing:
                item[key] = None
                continue
            if isinstance(value, pd.Timestamp):
                item[key] = value.date().isoformat()
                continue
            if hasattr(value, "item"):
                try:
                    value = value.item()
                except Exception:
                    pass
            item[key] = value
        rows.append(item)
    return rows


def _upsert(
    store: Any,
    table: str,
    frame: pd.DataFrame | None,
    *,
    on_conflict: str,
    batch_size: int = 500,
) -> int:
    rows = database_records(frame)
    if store is None or not rows:
        return 0
    size = max(1, int(batch_size))
    for start in range(0, len(rows), size):
        store.client.table(table).upsert(
            rows[start : start + size],
            on_conflict=on_conflict,
        ).execute()
    return len(rows)


def upsert_stock_summary(store: Any, frame: pd.DataFrame | None) -> int:
    clean = normalize_stock_summary(frame)
    return _upsert(
        store,
        "flow_zapi_stock_summary",
        clean,
        on_conflict="ticker,trade_date,source",
    )


def upsert_ownership(store: Any, frame: pd.DataFrame | None) -> int:
    clean = normalize_ownership(frame)
    return _upsert(
        store,
        "flow_zapi_ownership",
        clean,
        on_conflict="ticker,report_date,category,holder_identity_hash",
    )


def upsert_capital_actions(store: Any, frame: pd.DataFrame | None) -> int:
    clean = normalize_capital_actions(frame)
    return _upsert(
        store,
        "flow_zapi_capital_actions",
        clean,
        on_conflict="ticker,event_type,event_date,source_feed",
    )


__all__ = [
    "database_records",
    "load_stock_summary",
    "load_ownership",
    "load_capital_actions",
    "merge_stock_summary",
    "merge_ownership",
    "merge_capital_actions",
    "normalize_stock_summary",
    "normalize_ownership",
    "normalize_capital_actions",
    "upsert_stock_summary",
    "upsert_ownership",
    "upsert_capital_actions",
]
