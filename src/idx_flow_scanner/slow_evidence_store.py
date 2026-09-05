from __future__ import annotations

from datetime import date, timedelta
from typing import Any, Iterable

import pandas as pd

from .data import canonical_ticker

STOCK_SOURCE = "ZAPI_IDX_STOCK_SUMMARY"
STOCK_SOURCE_URL = "https://api.zpi.web.id/v1/finance:idx/stock-summary"
STOCK_PROVENANCE = "VERIFIED_ZAPI_IDX_STOCK_SUMMARY_NOT_BROKER_IDENTITY"
OWNERSHIP_PROVENANCE = frozenset(
    {
        "VERIFIED_IDX_KSEI_FILE_VIA_ZAPI_INDEX",
        "VERIFIED_IDX_COMPANY_PROFILE_VIA_ZAPI",
    }
)
CAPITAL_ACTION_PROVENANCE = "VERIFIED_IDX_DATASET_VIA_ZAPI"


def _bool_series(value: pd.Series) -> pd.Series:
    if pd.api.types.is_bool_dtype(value):
        return value.fillna(False)
    return value.fillna("").astype(str).str.strip().str.lower().isin(
        {"1", "true", "yes", "y", "verified"}
    )


def _records(frame: pd.DataFrame) -> list[dict[str, object]]:
    if frame is None or frame.empty:
        return []
    clean = frame.copy().where(pd.notna(frame), None)
    rows: list[dict[str, object]] = []
    for row in clean.to_dict("records"):
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


def normalize_stock_summary(frame: pd.DataFrame | None) -> pd.DataFrame:
    if frame is None or frame.empty:
        return pd.DataFrame()
    out = frame.copy()
    out.columns = [str(column).strip().lower() for column in out.columns]
    required = {"ticker", "trade_date", "listed_shares", "tradable_shares"}
    if not required.issubset(out.columns):
        return pd.DataFrame()
    out["ticker"] = out["ticker"].map(canonical_ticker)
    out["trade_date"] = pd.to_datetime(out["trade_date"], errors="coerce").dt.normalize()
    out = out.dropna(subset=["ticker", "trade_date"])
    if out.empty:
        return pd.DataFrame()

    source = out.get("source", pd.Series(STOCK_SOURCE, index=out.index)).fillna(STOCK_SOURCE).astype(str)
    out = out[source.eq(STOCK_SOURCE)].copy()
    if out.empty:
        return pd.DataFrame()
    out["source"] = STOCK_SOURCE
    out["source_verified"] = True
    out["source_url"] = STOCK_SOURCE_URL
    out["provenance_state"] = STOCK_PROVENANCE

    numeric = (
        "foreign_buy", "foreign_sell", "foreign_net", "volume", "traded_value",
        "frequency", "bid", "offer", "bid_volume", "offer_volume",
        "listed_shares", "tradable_shares",
    )
    for column in numeric:
        if column not in out.columns:
            out[column] = None
        out[column] = pd.to_numeric(out[column], errors="coerce")
    valid = (
        out["listed_shares"].gt(0)
        & out["tradable_shares"].gt(0)
        & out["tradable_shares"].le(out["listed_shares"] * 1.05)
    )
    out = out[valid].copy()
    if out.empty:
        return pd.DataFrame()
    columns = [
        "ticker", "trade_date", "foreign_buy", "foreign_sell", "foreign_net",
        "volume", "traded_value", "frequency", "bid", "offer", "bid_volume",
        "offer_volume", "listed_shares", "tradable_shares", "source",
        "source_verified", "source_url", "provenance_state",
    ]
    return out[columns].drop_duplicates(
        ["ticker", "trade_date", "source"], keep="last"
    ).sort_values(["ticker", "trade_date"], kind="stable").reset_index(drop=True)


def normalize_ownership(frame: pd.DataFrame | None) -> pd.DataFrame:
    if frame is None or frame.empty:
        return pd.DataFrame()
    out = frame.copy()
    out.columns = [str(column).strip().lower() for column in out.columns]
    required = {"ticker", "category", "holder_identity_hash", "report_date", "provenance_state"}
    if not required.issubset(out.columns):
        return pd.DataFrame()
    out["ticker"] = out["ticker"].map(canonical_ticker)
    out["report_date"] = pd.to_datetime(out["report_date"], errors="coerce").dt.normalize()
    if "publication_date" not in out.columns:
        out["publication_date"] = None
    out["publication_date"] = pd.to_datetime(out["publication_date"], errors="coerce").dt.normalize()
    out["category"] = out["category"].fillna("").astype(str).str.strip().str.lower()
    out["holder_identity_hash"] = out["holder_identity_hash"].fillna("").astype(str).str.strip().str.lower()
    out["provenance_state"] = out["provenance_state"].fillna("").astype(str).str.strip()
    if "source_verified" not in out.columns:
        out["source_verified"] = False
    out["source_verified"] = _bool_series(out["source_verified"])
    out = out[
        out["ticker"].ne("")
        & out["category"].ne("")
        & out["holder_identity_hash"].str.fullmatch(r"[0-9a-f]{64}", na=False)
        & out["report_date"].notna()
        & out["source_verified"]
        & out["provenance_state"].isin(OWNERSHIP_PROVENANCE)
    ].copy()
    if out.empty:
        return pd.DataFrame()
    for column in ("shares_held", "ownership_percentage"):
        if column not in out.columns:
            out[column] = None
        out[column] = pd.to_numeric(out[column], errors="coerce")
    invalid_pct = out["ownership_percentage"].notna() & ~out["ownership_percentage"].between(0, 100)
    invalid_shares = out["shares_held"].notna() & out["shares_held"].lt(0)
    out = out[~invalid_pct & ~invalid_shares].copy()
    for column in (
        "holder_name", "holder_classification", "holder_type", "local_foreign_state",
        "report_date_kind", "source_url", "source_file_hash",
    ):
        if column not in out.columns:
            out[column] = None
    columns = [
        "ticker", "category", "holder_identity_hash", "holder_name", "shares_held",
        "ownership_percentage", "holder_classification", "holder_type",
        "local_foreign_state", "report_date", "report_date_kind", "publication_date",
        "source_url", "source_file_hash", "source_verified", "provenance_state",
    ]
    return out[columns].drop_duplicates(
        ["ticker", "report_date", "category", "holder_identity_hash"], keep="last"
    ).sort_values(["ticker", "report_date", "category"], kind="stable").reset_index(drop=True)


def normalize_capital_actions(frame: pd.DataFrame | None) -> pd.DataFrame:
    if frame is None or frame.empty:
        return pd.DataFrame()
    out = frame.copy()
    out.columns = [str(column).strip().lower() for column in out.columns]
    required = {"ticker", "event_type", "event_date", "source_feed", "provenance_state"}
    if not required.issubset(out.columns):
        return pd.DataFrame()
    out["ticker"] = out["ticker"].map(canonical_ticker)
    for column in ("event_date", "event_start_date", "event_end_date", "publication_date", "observed_on"):
        if column not in out.columns:
            out[column] = None
        out[column] = pd.to_datetime(out[column], errors="coerce").dt.normalize()
    out["event_type"] = out["event_type"].fillna("").astype(str).str.strip().str.upper()
    out["source_feed"] = out["source_feed"].fillna("").astype(str).str.strip().str.lower()
    out["provenance_state"] = out["provenance_state"].fillna("").astype(str).str.strip()
    if "source_verified" not in out.columns:
        out["source_verified"] = False
    out["source_verified"] = _bool_series(out["source_verified"])
    out = out[
        out["ticker"].ne("")
        & out["event_type"].ne("")
        & out["source_feed"].ne("")
        & out["event_date"].notna()
        & out["source_verified"]
        & out["provenance_state"].eq(CAPITAL_ACTION_PROVENANCE)
    ].copy()
    if out.empty:
        return pd.DataFrame()
    for column in (
        "pre_shares", "post_shares", "delta_shares", "delta_percent",
        "ratio_before", "ratio_after",
    ):
        if column not in out.columns:
            out[column] = None
        out[column] = pd.to_numeric(out[column], errors="coerce")
    for column in ("raw_action", "source", "source_url"):
        if column not in out.columns:
            out[column] = None
    columns = [
        "ticker", "event_type", "event_date", "event_start_date", "event_end_date",
        "publication_date", "pre_shares", "post_shares", "delta_shares",
        "delta_percent", "ratio_before", "ratio_after", "raw_action", "source_feed",
        "source", "source_url", "source_verified", "observed_on", "provenance_state",
    ]
    return out[columns].drop_duplicates(
        ["ticker", "event_type", "event_date", "source_feed"], keep="last"
    ).sort_values(["event_date", "ticker", "event_type"], kind="stable").reset_index(drop=True)


def upsert_stock_summary(store: Any, frame: pd.DataFrame | None) -> int:
    clean = normalize_stock_summary(frame)
    rows = _records(clean)
    if store is None or not rows:
        return 0
    for start in range(0, len(rows), 500):
        store.client.table("flow_zapi_stock_summary").upsert(
            rows[start:start + 500], on_conflict="ticker,trade_date,source"
        ).execute()
    return len(rows)


def upsert_ownership(store: Any, frame: pd.DataFrame | None) -> int:
    clean = normalize_ownership(frame)
    rows = _records(clean)
    if store is None or not rows:
        return 0
    for start in range(0, len(rows), 500):
        store.client.table("flow_zapi_ownership").upsert(
            rows[start:start + 500],
            on_conflict="ticker,report_date,category,holder_identity_hash",
        ).execute()
    return len(rows)


def upsert_capital_actions(store: Any, frame: pd.DataFrame | None) -> int:
    clean = normalize_capital_actions(frame)
    rows = _records(clean)
    if store is None or not rows:
        return 0
    for start in range(0, len(rows), 500):
        store.client.table("flow_zapi_capital_actions").upsert(
            rows[start:start + 500],
            on_conflict="ticker,event_type,event_date,source_feed",
        ).execute()
    return len(rows)


def _names(universe: Iterable[str]) -> list[str]:
    return list(dict.fromkeys(canonical_ticker(value) for value in universe if canonical_ticker(value)))


def load_stock_summary(store: Any, universe: Iterable[str], *, lookback_days: int = 45) -> pd.DataFrame:
    names = _names(universe)
    if store is None or not names:
        return pd.DataFrame()
    since = (date.today() - timedelta(days=max(1, int(lookback_days)))).isoformat()
    rows: list[dict[str, object]] = []
    try:
        for start in range(0, len(names), 40):
            response = (
                store.client.table("flow_zapi_stock_summary")
                .select("*")
                .in_("ticker", names[start:start + 40])
                .gte("trade_date", since)
                .order("trade_date")
                .execute()
            )
            rows.extend(response.data or [])
    except Exception:
        return pd.DataFrame()
    return normalize_stock_summary(pd.DataFrame(rows)) if rows else pd.DataFrame()


def load_ownership(store: Any, universe: Iterable[str], *, lookback_days: int = 550) -> pd.DataFrame:
    names = _names(universe)
    if store is None or not names:
        return pd.DataFrame()
    since = (date.today() - timedelta(days=max(90, int(lookback_days)))).isoformat()
    rows: list[dict[str, object]] = []
    try:
        for start in range(0, len(names), 40):
            response = (
                store.client.table("flow_zapi_ownership")
                .select("*")
                .in_("ticker", names[start:start + 40])
                .gte("report_date", since)
                .order("report_date")
                .execute()
            )
            rows.extend(response.data or [])
    except Exception:
        return pd.DataFrame()
    return normalize_ownership(pd.DataFrame(rows)) if rows else pd.DataFrame()


def load_capital_actions(store: Any, universe: Iterable[str], *, lookback_days: int = 450) -> pd.DataFrame:
    names = _names(universe)
    if store is None or not names:
        return pd.DataFrame()
    since = (date.today() - timedelta(days=max(120, int(lookback_days)))).isoformat()
    rows: list[dict[str, object]] = []
    try:
        for start in range(0, len(names), 40):
            response = (
                store.client.table("flow_zapi_capital_actions")
                .select("*")
                .in_("ticker", names[start:start + 40])
                .gte("event_date", since)
                .order("event_date")
                .execute()
            )
            rows.extend(response.data or [])
    except Exception:
        return pd.DataFrame()
    return normalize_capital_actions(pd.DataFrame(rows)) if rows else pd.DataFrame()


def merge_stock_summary(database: pd.DataFrame, bundled: pd.DataFrame) -> pd.DataFrame:
    parts = [normalize_stock_summary(frame) for frame in (bundled, database)]
    parts = [frame for frame in parts if not frame.empty]
    if not parts:
        return pd.DataFrame()
    return pd.concat(parts, ignore_index=True).drop_duplicates(
        ["ticker", "trade_date", "source"], keep="last"
    ).sort_values(["ticker", "trade_date"], kind="stable").reset_index(drop=True)


def merge_ownership(database: pd.DataFrame, bundled: pd.DataFrame) -> pd.DataFrame:
    parts = [normalize_ownership(frame) for frame in (bundled, database)]
    parts = [frame for frame in parts if not frame.empty]
    if not parts:
        return pd.DataFrame()
    return pd.concat(parts, ignore_index=True).drop_duplicates(
        ["ticker", "report_date", "category", "holder_identity_hash"], keep="last"
    ).sort_values(["ticker", "report_date", "category"], kind="stable").reset_index(drop=True)


def merge_capital_actions(database: pd.DataFrame, bundled: pd.DataFrame) -> pd.DataFrame:
    parts = [normalize_capital_actions(frame) for frame in (bundled, database)]
    parts = [frame for frame in parts if not frame.empty]
    if not parts:
        return pd.DataFrame()
    return pd.concat(parts, ignore_index=True).drop_duplicates(
        ["ticker", "event_type", "event_date", "source_feed"], keep="last"
    ).sort_values(["event_date", "ticker", "event_type"], kind="stable").reset_index(drop=True)


def hydrate_slow_evidence(
    store: Any,
    universe: Iterable[str],
    *,
    bundled_stock: pd.DataFrame,
    bundled_ownership: pd.DataFrame,
    bundled_capital_actions: pd.DataFrame,
) -> tuple[pd.DataFrame, pd.DataFrame, pd.DataFrame, dict[str, object]]:
    """Read Supabase first, merge factual bundled fallback, then backfill the DB.

    Missing tables or transient PostgREST errors never alter evidence semantics:
    the caller receives the verified bundled cache unchanged as fallback. No
    synthetic free-float, ownership, or corporate-action rows are created.
    """
    db_stock = load_stock_summary(store, universe)
    db_ownership = load_ownership(store, universe)
    db_actions = load_capital_actions(store, universe)

    stock = merge_stock_summary(db_stock, bundled_stock)
    ownership = merge_ownership(db_ownership, bundled_ownership)
    actions = merge_capital_actions(db_actions, bundled_capital_actions)

    persisted = {"stock_summary_rows": 0, "ownership_rows": 0, "capital_action_rows": 0}
    errors: list[str] = []
    for key, writer, frame in (
        ("stock_summary_rows", upsert_stock_summary, bundled_stock),
        ("ownership_rows", upsert_ownership, bundled_ownership),
        ("capital_action_rows", upsert_capital_actions, bundled_capital_actions),
    ):
        try:
            persisted[key] = int(writer(store, frame))
        except Exception as exc:
            errors.append(f"{key}:{type(exc).__name__}")

    stats = {
        "database_stock_tickers": int(db_stock["ticker"].nunique()) if not db_stock.empty else 0,
        "database_ownership_tickers": int(db_ownership["ticker"].nunique()) if not db_ownership.empty else 0,
        "database_capital_action_tickers": int(db_actions["ticker"].nunique()) if not db_actions.empty else 0,
        "merged_stock_tickers": int(stock["ticker"].nunique()) if not stock.empty else 0,
        "merged_ownership_tickers": int(ownership["ticker"].nunique()) if not ownership.empty else 0,
        "merged_capital_action_tickers": int(actions["ticker"].nunique()) if not actions.empty else 0,
        **persisted,
        "persistence_errors": errors,
        "database_first": True,
        "no_fabricated_evidence": True,
    }
    return stock, ownership, actions, stats
