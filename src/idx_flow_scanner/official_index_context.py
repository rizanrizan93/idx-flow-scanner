from __future__ import annotations

from datetime import date, timedelta
from typing import Any, Mapping

import math
import numpy as np
import pandas as pd

OFFICIAL_INDEX_SOURCE = "IDX_OFFICIAL_INDEX_SUMMARY"
OFFICIAL_INDEX_PROVENANCE = "VERIFIED_OFFICIAL_IDX_INDEX_SUMMARY"

SECTOR_INDEX_MAP = {
    "Basic Materials": "IDXBASIC",
    "Consumer Cyclicals": "IDXCYCLIC",
    "Consumer Non-Cyclicals": "IDXNONCYC",
    "Energy": "IDXENERGY",
    "Financials": "IDXFINANCE",
    "Healthcare": "IDXHEALTH",
    "Industrials": "IDXINDUST",
    "Infrastructures": "IDXINFRA",
    "Properties & Real Estate": "IDXPROPERT",
    "Technology": "IDXTECHNO",
    "Transportation & Logistic": "IDXTRANS",
}

_INDEX_CONTEXT: pd.DataFrame | None = None


def _sigmoid(value: float | None, scale: float) -> float:
    if value is None or not np.isfinite(value):
        return 50.0
    z = float(np.clip(float(value) / max(float(scale), 1e-9), -10.0, 10.0))
    return float(100.0 / (1.0 + math.exp(-z)))


def _label(score: float) -> str:
    if score >= 65.0:
        return "RISK_ON"
    if score >= 55.0:
        return "CONSTRUCTIVE"
    if score >= 45.0:
        return "NEUTRAL"
    if score >= 35.0:
        return "DEFENSIVE"
    return "RISK_OFF"


def load_official_index_summary(
    store: Any,
    *,
    lookback_calendar_days: int = 140,
) -> pd.DataFrame | None:
    """Load verified official IDX index-summary history.

    None means the store was unavailable. An empty frame means the read
    succeeded but no observations matched the requested window.
    """
    if store is None:
        return None
    since = (date.today() - timedelta(days=max(45, int(lookback_calendar_days)))).isoformat()
    try:
        response = (
            store.client.table("flow_official_index_summary")
            .select("*")
            .gte("trade_date", since)
            .eq("source", OFFICIAL_INDEX_SOURCE)
            .eq("source_verified", True)
            .order("trade_date")
            .execute()
        )
    except Exception:
        return None
    rows = response.data or []
    if not rows:
        return pd.DataFrame()
    out = pd.DataFrame(rows)
    out.columns = [str(c).strip().lower() for c in out.columns]
    required = {"trade_date", "index_code", "close", "source", "source_verified", "provenance_state"}
    if not required.issubset(out.columns):
        return None
    out["trade_date"] = pd.to_datetime(out["trade_date"], errors="coerce").dt.normalize()
    out["index_code"] = out["index_code"].fillna("").astype(str).str.strip().str.upper()
    for column in ("previous", "highest", "lowest", "close", "number_of_stock", "change", "volume", "traded_value", "frequency", "market_capital"):
        if column in out.columns:
            out[column] = pd.to_numeric(out[column], errors="coerce")
    verified = out["source_verified"]
    if not pd.api.types.is_bool_dtype(verified):
        verified = verified.fillna(False).astype(str).str.strip().str.lower().isin({"1", "true", "yes"})
    out = out[
        out["trade_date"].notna()
        & out["index_code"].ne("")
        & out["close"].gt(0)
        & verified.fillna(False)
        & out["source"].astype(str).eq(OFFICIAL_INDEX_SOURCE)
        & out["provenance_state"].astype(str).eq(OFFICIAL_INDEX_PROVENANCE)
    ].copy()
    return out.sort_values(["index_code", "trade_date"], kind="stable").reset_index(drop=True)


def set_official_index_context(frame: pd.DataFrame | None) -> None:
    global _INDEX_CONTEXT
    _INDEX_CONTEXT = None if frame is None else frame.copy()


def _returns(frame: pd.DataFrame, sessions: int) -> float | None:
    if frame is None or frame.empty:
        return None
    work = frame.sort_values("trade_date")
    close = pd.to_numeric(work["close"], errors="coerce").dropna()
    if len(close) <= sessions:
        return None
    first = float(close.iloc[-(sessions + 1)])
    last = float(close.iloc[-1])
    if not np.isfinite(first) or not np.isfinite(last) or first <= 0:
        return None
    return float(last / first - 1.0)


def _index_score(frame: pd.DataFrame) -> tuple[float, float | None, float | None]:
    r5 = _returns(frame, 5)
    r20 = _returns(frame, 20)
    score = 0.35 * _sigmoid(r5, 0.025) + 0.65 * _sigmoid(r20, 0.055)
    return float(np.clip(score, 0.0, 100.0)), r5, r20


def apply_official_index_overlay(
    ticker: str,
    base_features: Mapping[str, object],
    *,
    reference_date: str | pd.Timestamp | None = None,
    frame: pd.DataFrame | None = None,
) -> dict[str, object]:
    """Blend official IDX market/sector indices into existing market context.

    The existing universe breadth/relative-strength model remains intact. The
    official layer supplies an independent benchmark and can only replace part
    of the market-context factor, never bypass execution gates.
    """
    out = dict(base_features)
    source_frame = _INDEX_CONTEXT if frame is None else frame
    default = {
        "official_index_context_available": False,
        "official_index_source": OFFICIAL_INDEX_SOURCE,
        "official_market_index_code": "COMPOSITE",
        "official_sector_index_code": SECTOR_INDEX_MAP.get(str(out.get("sector") or "")),
        "official_index_latest_date": None,
        "official_market_regime_score": 50.0,
        "official_market_regime_label": "UNAVAILABLE",
        "official_market_return_5d_pct": None,
        "official_market_return_20d_pct": None,
        "official_sector_regime_score": 50.0,
        "official_sector_regime_label": "UNAVAILABLE",
        "official_sector_return_5d_pct": None,
        "official_sector_return_20d_pct": None,
        "official_sector_relative_strength_20d_pct": None,
        "official_market_sector_score": 50.0,
        "market_context_official_weight": 0.0,
    }
    out.update(default)
    if source_frame is None or source_frame.empty:
        return out

    work = source_frame.copy()
    work["trade_date"] = pd.to_datetime(work["trade_date"], errors="coerce").dt.normalize()
    work["index_code"] = work["index_code"].fillna("").astype(str).str.strip().str.upper()
    work["close"] = pd.to_numeric(work["close"], errors="coerce")
    work = work.dropna(subset=["trade_date", "close"])
    if reference_date is not None:
        ref = pd.to_datetime(reference_date, errors="coerce")
        if pd.notna(ref):
            work = work[work["trade_date"].le(pd.Timestamp(ref).normalize())].copy()
    if work.empty:
        return out

    market = work[work["index_code"].eq("COMPOSITE")].copy()
    if market.empty:
        return out
    latest = pd.Timestamp(market["trade_date"].max())
    if reference_date is not None:
        ref = pd.to_datetime(reference_date, errors="coerce")
        if pd.notna(ref) and (pd.Timestamp(ref).normalize() - latest).days > 5:
            return out

    market_score, m5, m20 = _index_score(market)
    sector = str(out.get("sector") or "")
    sector_code = SECTOR_INDEX_MAP.get(sector)
    sector_frame = work[work["index_code"].eq(sector_code)].copy() if sector_code else pd.DataFrame()

    if not sector_frame.empty:
        sector_score, s5, s20 = _index_score(sector_frame)
        rs20 = (s20 - m20) if s20 is not None and m20 is not None else None
        rs_score = _sigmoid(rs20, 0.045)
        official_combined = float(np.clip(0.30 * market_score + 0.40 * sector_score + 0.30 * rs_score, 0.0, 100.0))
        official_weight = 0.55
    else:
        sector_score, s5, s20, rs20 = 50.0, None, None, None
        official_combined = market_score
        official_weight = 0.30

    base_score = float(out.get("market_sector_score", 50.0) or 50.0)
    blended = (1.0 - official_weight) * base_score + official_weight * official_combined
    out.update(
        {
            "market_sector_score": float(np.clip(blended, 0.0, 100.0)),
            "official_index_context_available": True,
            "official_index_source": OFFICIAL_INDEX_SOURCE,
            "official_market_index_code": "COMPOSITE",
            "official_sector_index_code": sector_code,
            "official_index_latest_date": latest.date().isoformat(),
            "official_market_regime_score": market_score,
            "official_market_regime_label": _label(market_score),
            "official_market_return_5d_pct": m5 * 100.0 if m5 is not None else None,
            "official_market_return_20d_pct": m20 * 100.0 if m20 is not None else None,
            "official_sector_regime_score": sector_score,
            "official_sector_regime_label": _label(sector_score) if not sector_frame.empty else "UNAVAILABLE",
            "official_sector_return_5d_pct": s5 * 100.0 if s5 is not None else None,
            "official_sector_return_20d_pct": s20 * 100.0 if s20 is not None else None,
            "official_sector_relative_strength_20d_pct": rs20 * 100.0 if rs20 is not None else None,
            "official_market_sector_score": official_combined,
            "market_context_official_weight": official_weight,
            "market_context_basis": str(out.get("market_context_basis") or "") + "__OFFICIAL_IDX_INDEX_OVERLAY",
        }
    )
    return out


__all__ = [
    "OFFICIAL_INDEX_SOURCE",
    "OFFICIAL_INDEX_PROVENANCE",
    "SECTOR_INDEX_MAP",
    "load_official_index_summary",
    "set_official_index_context",
    "apply_official_index_overlay",
]
