from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Callable, Iterable, Any

import numpy as np
import pandas as pd

from .data import canonical_ticker


@dataclass(frozen=True)
class SignalOutcome:
    entry_close: float | None
    return_5d: float | None
    return_20d: float | None
    return_60d: float | None
    mfe_20d: float | None
    mae_20d: float | None
    evaluated_through: str | None
    evaluation_status: str
    evaluation_note: str | None = None


def _pct(value: float, base: float) -> float:
    return 100.0 * (value / base - 1.0)


def _split_like_forward_window(px: pd.DataFrame, entry_index: int, max_steps: int = 60) -> bool:
    """Mirror the database RPC corporate-action discontinuity guard.

    Detect large overnight price-scale changes close to common split/reverse-split
    factors while rejecting ordinary intraday gaps. This keeps the Python fallback
    semantically aligned with ``flow_refresh_signal_outcomes`` so an RPC outage
    cannot accidentally score corporate-action-distorted forward returns.
    """
    if px is None or px.empty or entry_index < 0:
        return False
    end = min(entry_index + max_steps, len(px) - 1)
    factors = np.array([0.1, 0.2, 0.25, 1.0 / 3.0, 0.5, 2.0, 3.0, 4.0, 5.0, 10.0], dtype=float)
    for j in range(entry_index + 1, end + 1):
        prev_close = float(px.loc[j - 1, "close"])
        open_px = float(px.loc[j, "open"])
        close_px = float(px.loc[j, "close"])
        if not (np.isfinite(prev_close) and np.isfinite(open_px) and np.isfinite(close_px)):
            continue
        if prev_close <= 0 or open_px <= 0:
            continue
        ratio = open_px / prev_close
        if abs(ratio - 1.0) < 0.35:
            continue
        if abs(close_px / open_px - 1.0) > 0.25:
            continue
        relative_error = np.min(np.abs(ratio - factors) / factors)
        if relative_error <= 0.06:
            return True
    return False


def compute_signal_outcome(price: pd.DataFrame, as_of_date: str | pd.Timestamp) -> SignalOutcome:
    """Strictly forward walk-forward evaluation; never used by signal generation itself.

    The signal baseline must exist on the exact signal date. We intentionally do
    not slide a missing baseline to a later bar because that would change the
    historical entry after the fact and contaminate OOS calibration. Forward
    split/reverse-split-like discontinuities are excluded, matching the database
    RPC path.
    """
    if price is None or price.empty:
        return SignalOutcome(None, None, None, None, None, None, None, "PENDING")
    px = price.copy()
    px["date"] = pd.to_datetime(px["date"], errors="coerce").dt.normalize()
    px = px.dropna(subset=["date", "close"]).drop_duplicates("date", keep="last").sort_values("date").reset_index(drop=True)
    target = pd.Timestamp(as_of_date).normalize()
    matches = px.index[px["date"] == target]
    if len(matches) == 0:
        return SignalOutcome(None, None, None, None, None, None, None, "PENDING")
    i = int(matches[0])
    entry = float(px.loc[i, "close"])
    if not np.isfinite(entry) or entry <= 0:
        return SignalOutcome(None, None, None, None, None, None, None, "PENDING")

    through = px["date"].iloc[-1].date().isoformat() if len(px) else None
    if _split_like_forward_window(px, i):
        return SignalOutcome(
            entry, None, None, None, None, None, through, "EXCLUDED",
            "CORPORATE_ACTION_LIKE_GAP_IN_FORWARD_WINDOW",
        )

    def ret_at(step: int) -> float | None:
        j = i + step
        if j >= len(px):
            return None
        value = float(px.loc[j, "close"])
        return _pct(value, entry) if np.isfinite(value) else None

    r5, r20, r60 = ret_at(5), ret_at(20), ret_at(60)
    end20 = min(i + 20, len(px) - 1)
    future20 = px.iloc[i + 1:end20 + 1]
    mfe = mae = None
    if not future20.empty:
        highs = pd.to_numeric(future20.get("high"), errors="coerce")
        lows = pd.to_numeric(future20.get("low"), errors="coerce")
        if highs.notna().any():
            mfe = _pct(float(highs.max()), entry)
        if lows.notna().any():
            mae = _pct(float(lows.min()), entry)
    status = "COMPLETE" if r60 is not None else ("PARTIAL" if r5 is not None or r20 is not None else "PENDING")
    return SignalOutcome(entry, r5, r20, r60, mfe, mae, through, status)


def _finite_or_none(value: object) -> float | None:
    try:
        out = float(value)
        return out if np.isfinite(out) else None
    except (TypeError, ValueError):
        return None


def seed_signal_outcomes(
    store: Any,
    run_id: str,
    results: pd.DataFrame,
    price_loader: Callable[[str], pd.DataFrame],
) -> int:
    """Register today's signals for future OOS scoring without feeding outcomes back into the signal."""
    if store is None or results is None or results.empty:
        return 0
    rows = []
    for row in results.to_dict("records"):
        ticker = canonical_ticker(row.get("ticker"))
        as_of = row.get("as_of_date")
        if not ticker or not as_of:
            continue
        outcome = compute_signal_outcome(price_loader(ticker), as_of)
        rows.append({
            "run_id": run_id,
            "ticker": ticker,
            "as_of_date": str(as_of),
            "phase": str(row.get("phase") or "UNKNOWN"),
            "evidence_tier": str(row.get("evidence_tier") or "PRICE_PROXY"),
            "final_score": _finite_or_none(row.get("final_score")) or 0.0,
            "entry_close": _finite_or_none(outcome.entry_close),
            "return_5d": _finite_or_none(outcome.return_5d),
            "return_20d": _finite_or_none(outcome.return_20d),
            "return_60d": _finite_or_none(outcome.return_60d),
            "mfe_20d": _finite_or_none(outcome.mfe_20d),
            "mae_20d": _finite_or_none(outcome.mae_20d),
            "evaluated_through": outcome.evaluated_through,
            "evaluation_status": outcome.evaluation_status,
            "evaluation_note": outcome.evaluation_note,
            "evaluated_at": datetime.now(timezone.utc).isoformat() if outcome.evaluation_status != "PENDING" else None,
        })
    for i in range(0, len(rows), 500):
        store.client.table("flow_signal_outcomes").upsert(rows[i:i + 500], on_conflict="run_id,ticker").execute()
    return len(rows)


def _load_open_outcomes(store: Any, *, page_size: int = 1000, max_rows: int = 30000) -> list[dict[str, object]]:
    """Page through open OOS rows so old rows cannot starve newer signals."""
    page_size = max(1, min(int(page_size), 1000))
    max_rows = max(page_size, int(max_rows))
    rows: list[dict[str, object]] = []
    offset = 0
    while len(rows) < max_rows:
        end = min(offset + page_size - 1, max_rows - 1)
        response = (store.client.table("flow_signal_outcomes")
                    .select("run_id,ticker,as_of_date,evaluation_status,evaluated_through")
                    .in_("evaluation_status", ["PENDING", "PARTIAL"])
                    .order("as_of_date")
                    .range(offset, end).execute())
        batch = list(response.data or [])
        rows.extend(batch)
        if len(batch) < (end - offset + 1):
            break
        offset = end + 1
    return rows[:max_rows]


def _refresh_pending_outcomes_python(
    store: Any,
    universe: Iterable[str],
    price_loader: Callable[[str], pd.DataFrame],
    *,
    max_rows: int,
    page_size: int,
) -> dict[str, object]:
    names = set(canonical_ticker(t) for t in universe if canonical_ticker(t))
    open_rows = _load_open_outcomes(store, page_size=page_size, max_rows=max_rows)
    pending = [r for r in open_rows if canonical_ticker(r.get("ticker")) in names]

    price_cache: dict[str, pd.DataFrame] = {}
    for ticker in sorted({canonical_ticker(r.get("ticker")) for r in pending if canonical_ticker(r.get("ticker"))}):
        try:
            price_cache[ticker] = price_loader(ticker)
        except Exception:
            price_cache[ticker] = pd.DataFrame()

    updates = []
    complete = 0
    excluded = 0
    for row in pending:
        ticker = canonical_ticker(row.get("ticker"))
        as_of = row.get("as_of_date")
        outcome = compute_signal_outcome(price_cache.get(ticker, pd.DataFrame()), as_of)
        current_status = str(row.get("evaluation_status") or "PENDING")
        current_through = str(row.get("evaluated_through") or "")
        if outcome.evaluation_status == current_status and str(outcome.evaluated_through or "") == current_through:
            continue
        payload = {
            "run_id": row["run_id"],
            "ticker": ticker,
            "entry_close": _finite_or_none(outcome.entry_close),
            "return_5d": _finite_or_none(outcome.return_5d),
            "return_20d": _finite_or_none(outcome.return_20d),
            "return_60d": _finite_or_none(outcome.return_60d),
            "mfe_20d": _finite_or_none(outcome.mfe_20d),
            "mae_20d": _finite_or_none(outcome.mae_20d),
            "evaluated_through": outcome.evaluated_through,
            "evaluation_status": outcome.evaluation_status,
            "evaluation_note": outcome.evaluation_note,
            "evaluated_at": datetime.now(timezone.utc).isoformat() if outcome.evaluation_status != "PENDING" else None,
        }
        updates.append(payload)
        complete += int(outcome.evaluation_status == "COMPLETE")
        excluded += int(outcome.evaluation_status == "EXCLUDED")
    for i in range(0, len(updates), 500):
        store.client.table("flow_signal_outcomes").upsert(updates[i:i + 500], on_conflict="run_id,ticker").execute()
    return {"checked": len(pending), "updated": len(updates), "complete": complete, "excluded": excluded, "mode": "PYTHON_FALLBACK"}


def refresh_pending_outcomes(
    store: Any,
    universe: Iterable[str],
    price_loader: Callable[[str], pd.DataFrame],
    *,
    max_rows: int = 30000,
    page_size: int = 1000,
) -> dict[str, object]:
    """Advance historical outcomes using persisted OHLCV, database-first.

    Production prefers one PostgreSQL RPC so tens of thousands of open 60D
    outcomes do not cause hundreds of Streamlit/PostgREST reads. The Python path
    remains as a compatibility fallback and keeps the same exact-date baseline
    and corporate-action exclusion semantics. Neither path feeds future outcomes
    into current signal generation.
    """
    if store is None:
        return {"checked": 0, "updated": 0, "complete": 0, "excluded": 0, "mode": "SKIPPED"}

    try:
        response = store.client.rpc(
            "flow_refresh_signal_outcomes",
            {"p_limit": max(1, int(max_rows))},
        ).execute()
        raw = response.data
        if isinstance(raw, list) and len(raw) == 1:
            raw = raw[0]
        updated = int(raw or 0)
        return {"checked": updated, "updated": updated, "complete": 0, "excluded": 0, "mode": "DATABASE_RPC"}
    except Exception:
        return _refresh_pending_outcomes_python(
            store,
            universe,
            price_loader,
            max_rows=max_rows,
            page_size=page_size,
        )
