from __future__ import annotations

import pandas as pd

from .data import canonical_ticker, normalize_broker_summary

# Prefer the richer closed-book gross buy/sell contract when more than one vendor
# covers the exact same ticker-day. Unknown sources remain usable but lower-priority;
# provenance gates still decide whether they can ever become BROKER_DIRECT.
SOURCE_PRIORITY = {
    "IDX_OFFICIAL_BROKER_SUMMARY": 50,
    "IDX_OFFICIAL_STOCK_BROKER_SUMMARY": 50,  # legacy persisted alias
    "INDEX_ALPHA_BROKER_SUMMARY": 40,
    "GOAPI_BROKER_SUMMARY_NET": 30,
}


def _verified_pct(frame: pd.DataFrame) -> float:
    if frame is None or frame.empty or "source_verified" not in frame.columns:
        return 0.0
    raw = frame["source_verified"]
    if pd.api.types.is_bool_dtype(raw):
        ok = raw.fillna(False)
    else:
        ok = raw.astype(str).str.strip().str.lower().isin({"1", "true", "yes", "y", "verified"})
    return 100.0 * float(ok.mean()) if len(ok) else 0.0


def select_broker_evidence(frame: pd.DataFrame | None) -> tuple[pd.DataFrame, dict[str, object]]:
    """Select one broker provider for every ticker-day to avoid double counting.

    Provider selection is local to a ticker-day so a coherent history can still be
    assembled when one source has holes. Within the same day, all broker rows from
    exactly one source are retained. Selection order is verified provenance first,
    then explicit contract priority, then broker-row quorum.
    """
    if frame is None or frame.empty:
        return pd.DataFrame(), {"selected_ticker_days": 0, "source_ticker_days": {}}
    work = normalize_broker_summary(frame)
    if work.empty:
        return work, {"selected_ticker_days": 0, "source_ticker_days": {}}
    work["ticker"] = work["ticker"].map(canonical_ticker)
    work["trade_date"] = pd.to_datetime(work["trade_date"], errors="coerce").dt.normalize()
    work["source"] = work.get("source", "UNKNOWN").fillna("UNKNOWN").astype(str)
    work = work.dropna(subset=["ticker", "trade_date"])

    chosen: list[pd.DataFrame] = []
    source_days: dict[str, int] = {}
    for (_, _), day_rows in work.groupby(["ticker", "trade_date"], observed=True, sort=False):
        options: list[tuple[float, int, int, str, pd.DataFrame]] = []
        for source, source_rows in day_rows.groupby("source", observed=True, sort=False):
            options.append((
                _verified_pct(source_rows),
                SOURCE_PRIORITY.get(str(source), 0),
                int(source_rows["broker_code"].nunique()) if "broker_code" in source_rows.columns else 0,
                str(source),
                source_rows.copy(),
            ))
        options.sort(key=lambda item: (item[0], item[1], item[2], item[3]), reverse=True)
        _, _, _, source, selected = options[0]
        chosen.append(selected)
        source_days[source] = source_days.get(source, 0) + 1

    out = normalize_broker_summary(pd.concat(chosen, ignore_index=True)) if chosen else pd.DataFrame()
    return out.sort_values(["ticker", "trade_date", "broker_code"], kind="stable").reset_index(drop=True), {
        "selected_ticker_days": int(sum(source_days.values())),
        "source_ticker_days": source_days,
    }
