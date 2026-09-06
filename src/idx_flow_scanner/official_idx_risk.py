from __future__ import annotations

from datetime import date, timedelta
from typing import Any, Callable

import numpy as np
import pandas as pd

from .config import ZapiFlowConfig
from .data import canonical_ticker

OFFICIAL_RISK_SOURCE = "IDX_OFFICIAL_RISK_EVENT"
OFFICIAL_RISK_PROVENANCE = "VERIFIED_OFFICIAL_IDX_MARKET_RISK_EVENT"

_RISK_CONTEXT: pd.DataFrame | None = None


def load_official_idx_risk_events(
    store: Any,
    universe: list[str] | tuple[str, ...] | None = None,
    *,
    lookback_calendar_days: int = 270,
) -> pd.DataFrame | None:
    """Load verified official IDX UMA/suspension events.

    None means the evidence store could not be read. An empty DataFrame means the
    store was read successfully but no matching events exist in the requested
    window. This distinction keeps missing transport fail-neutral.
    """
    if store is None:
        return None
    since = (date.today() - timedelta(days=max(30, int(lookback_calendar_days)))).isoformat()
    names = []
    if universe:
        names = list(dict.fromkeys(canonical_ticker(v) for v in universe if canonical_ticker(v)))
    rows: list[dict[str, object]] = []
    try:
        if names:
            for start in range(0, len(names), 40):
                resp = (
                    store.client.table("flow_official_risk_events")
                    .select("*")
                    .in_("ticker", names[start:start + 40])
                    .gte("event_date", since)
                    .eq("source", OFFICIAL_RISK_SOURCE)
                    .eq("source_verified", True)
                    .order("event_date")
                    .execute()
                )
                rows.extend(resp.data or [])
        else:
            resp = (
                store.client.table("flow_official_risk_events")
                .select("*")
                .gte("event_date", since)
                .eq("source", OFFICIAL_RISK_SOURCE)
                .eq("source_verified", True)
                .order("event_date")
                .execute()
            )
            rows.extend(resp.data or [])
    except Exception:
        return None
    if not rows:
        return pd.DataFrame()
    out = pd.DataFrame(rows)
    out.columns = [str(c).strip().lower() for c in out.columns]
    required = {"ticker", "event_date", "event_type", "source", "source_verified", "provenance_state"}
    if not required.issubset(out.columns):
        return None
    out["ticker"] = out["ticker"].map(canonical_ticker)
    out["event_date"] = pd.to_datetime(out["event_date"], errors="coerce").dt.normalize()
    out["event_type"] = out["event_type"].fillna("").astype(str).str.strip().str.upper()
    verified = out["source_verified"]
    if not pd.api.types.is_bool_dtype(verified):
        verified = verified.fillna(False).astype(str).str.strip().str.lower().isin({"1", "true", "yes"})
    out = out[
        out["ticker"].ne("")
        & out["event_date"].notna()
        & out["event_type"].isin({"UMA", "SUSPEND", "UNSUSPEND"})
        & verified.fillna(False)
        & out["source"].astype(str).eq(OFFICIAL_RISK_SOURCE)
        & out["provenance_state"].astype(str).eq(OFFICIAL_RISK_PROVENANCE)
    ].copy()
    return out.sort_values(["ticker", "event_date", "event_type"], kind="stable").reset_index(drop=True)


def set_official_risk_context(frame: pd.DataFrame | None) -> None:
    global _RISK_CONTEXT
    _RISK_CONTEXT = None if frame is None else frame.copy()


def _session_age(price: pd.DataFrame, event_date: pd.Timestamp) -> int | None:
    if price is None or price.empty or "date" not in price.columns:
        return None
    dates = pd.DatetimeIndex(pd.to_datetime(price["date"], errors="coerce").dropna().dt.normalize().unique()).sort_values()
    if not len(dates):
        return None
    as_of = pd.Timestamp(dates[-1])
    if event_date > as_of:
        return None
    return int((dates > event_date).sum())


def compute_official_risk_features(
    ticker: str,
    price: pd.DataFrame,
    events: pd.DataFrame | None,
) -> dict[str, object]:
    default = {
        "official_risk_feed_available": events is not None,
        "official_risk_event_available": False,
        "official_risk_source": OFFICIAL_RISK_SOURCE,
        "official_risk_active_suspension": False,
        "official_risk_latest_suspension_event": None,
        "official_risk_latest_suspension_date": None,
        "official_risk_latest_uma_date": None,
        "official_risk_uma_age_sessions": None,
        "official_risk_recent_uma": False,
        "official_risk_uma_guard": False,
        "official_risk_hard_block": False,
        "official_risk_penalty_points": 0.0,
        "official_risk_event_count": 0,
    }
    if events is None:
        return default
    symbol = canonical_ticker(ticker)
    if events.empty:
        return default
    work = events.copy()
    if "ticker" not in work.columns:
        return default
    work["ticker"] = work["ticker"].map(canonical_ticker)
    work = work[work["ticker"].eq(symbol)].copy()
    if work.empty:
        return default
    work["event_date"] = pd.to_datetime(work["event_date"], errors="coerce").dt.normalize()
    work["event_type"] = work["event_type"].fillna("").astype(str).str.strip().str.upper()
    work = work.dropna(subset=["event_date"])
    if work.empty:
        return default
    as_of = pd.to_datetime(price["date"], errors="coerce").max() if price is not None and not price.empty and "date" in price.columns else pd.NaT
    if pd.notna(as_of):
        work = work[work["event_date"].le(pd.Timestamp(as_of).normalize())].copy()
    if work.empty:
        return default

    suspension = work[work["event_type"].isin({"SUSPEND", "UNSUSPEND"})].copy()
    latest_susp_type = None
    latest_susp_date = None
    active_suspension = False
    if not suspension.empty:
        # Same-day reopening wins over suspension when both announcements exist.
        suspension["_order"] = suspension["event_type"].map({"SUSPEND": 0, "UNSUSPEND": 1}).fillna(0)
        suspension = suspension.sort_values(["event_date", "_order"], kind="stable")
        last = suspension.iloc[-1]
        latest_susp_type = str(last["event_type"])
        latest_susp_date = pd.Timestamp(last["event_date"])
        active_suspension = latest_susp_type == "SUSPEND"

    uma = work[work["event_type"].eq("UMA")].copy()
    latest_uma = pd.Timestamp(uma["event_date"].max()) if not uma.empty else None
    uma_age = _session_age(price, latest_uma) if latest_uma is not None else None
    recent_uma = uma_age is not None and uma_age <= 10
    uma_guard = uma_age is not None and uma_age <= 3

    penalty = 0.0
    if active_suspension:
        penalty = 25.0
    elif uma_age is not None:
        if uma_age <= 3:
            penalty = 6.0
        elif uma_age <= 10:
            penalty = 2.5

    return {
        **default,
        "official_risk_feed_available": True,
        "official_risk_event_available": True,
        "official_risk_active_suspension": active_suspension,
        "official_risk_latest_suspension_event": latest_susp_type,
        "official_risk_latest_suspension_date": latest_susp_date.date().isoformat() if latest_susp_date is not None else None,
        "official_risk_latest_uma_date": latest_uma.date().isoformat() if latest_uma is not None else None,
        "official_risk_uma_age_sessions": uma_age,
        "official_risk_recent_uma": bool(recent_uma),
        "official_risk_uma_guard": bool(uma_guard),
        "official_risk_hard_block": bool(active_suspension),
        "official_risk_penalty_points": float(penalty),
        "official_risk_event_count": int(len(work)),
    }


def apply_official_risk_overlay(
    scan_one: Callable[..., Any],
    ticker: str,
    price: pd.DataFrame,
    **kwargs: object,
):
    """Apply official IDX risk evidence after normal scoring.

    Suspension is a hard authorization block. UMA is a warning, not a trading
    halt: it applies a bounded score penalty and a short three-session execution
    guard. The overlay never creates positive alpha.
    """
    result = scan_one(ticker, price, **kwargs)
    events = _RISK_CONTEXT
    risk = compute_official_risk_features(ticker, price, events)
    diagnostics = dict(getattr(result, "diagnostics", {}) or {})
    diagnostics.update(risk)
    result.diagnostics = diagnostics

    penalty = float(risk.get("official_risk_penalty_points", 0.0) or 0.0)
    result.final_score = round(float(np.clip(float(result.final_score) - penalty, 0.0, 100.0)), 2)

    reasons: list[str] = []
    existing = str(getattr(result, "guardrail_reason", "") or "").strip()
    if existing:
        reasons.append(existing)

    blocked = bool(risk.get("official_risk_hard_block", False))
    uma_guard = bool(risk.get("official_risk_uma_guard", False))
    if blocked:
        reasons.append("official IDX unresolved suspension")
        result.production_authorized = False
        result.real_money_state = "GUARDED"
        result.action = "REDUCE_AVOID"
    elif uma_guard:
        age = risk.get("official_risk_uma_age_sessions")
        reasons.append(f"recent official IDX UMA ({age} trading sessions)")
        result.production_authorized = False
        result.real_money_state = "GUARDED"
        if result.action not in {"REDUCE_AVOID", "RESEARCH_ONLY"}:
            result.action = "WATCHLIST"

    config = kwargs.get("config")
    config = config if isinstance(config, ZapiFlowConfig) else ZapiFlowConfig()
    if bool(getattr(result, "production_authorized", False)) and float(result.final_score) < float(config.decision_score_floor):
        reasons.append(f"risk-adjusted score {result.final_score:.1f} below {config.decision_score_floor:.0f}")
        result.production_authorized = False
        result.real_money_state = "GUARDED"
        if result.action not in {"REDUCE_AVOID", "RESEARCH_ONLY"}:
            result.action = "WATCHLIST"

    if reasons:
        result.guardrail_reason = "; ".join(dict.fromkeys(reasons))
    return result


__all__ = [
    "OFFICIAL_RISK_SOURCE",
    "OFFICIAL_RISK_PROVENANCE",
    "load_official_idx_risk_events",
    "set_official_risk_context",
    "compute_official_risk_features",
    "apply_official_risk_overlay",
]
