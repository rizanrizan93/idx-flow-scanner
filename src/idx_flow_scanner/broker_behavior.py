from __future__ import annotations

from datetime import date, timedelta
from typing import Any

import numpy as np
import pandas as pd

from .data import canonical_ticker

OFFICIAL_IDX_BROKER_SOURCE = "IDX_OFFICIAL_BROKER_SUMMARY"
BROKER_BEHAVIOR_BASIS = (
    "MARKET_WIDE_IDX_BROKER_ACTIVITY_X_TICKER_FLOW_ALIGNMENT_NOT_PER_TICKER_BROKER_TRADES"
)


def _clip(value: float) -> float:
    if not np.isfinite(value):
        return 50.0
    return float(np.clip(value, 0.0, 100.0))


def _sigmoid_score(value: float, scale: float = 1.0) -> float:
    if not np.isfinite(value):
        return 50.0
    z = float(np.clip(value / max(scale, 1e-9), -10.0, 10.0))
    return float(100.0 / (1.0 + np.exp(-z)))


def _robust_z(latest: float, history: pd.Series) -> float:
    h = pd.to_numeric(history, errors="coerce").dropna().astype(float)
    if len(h) < 5:
        return 0.0
    median = float(h.median())
    mad = float((h - median).abs().median())
    scale = 1.4826 * mad
    if scale <= 1e-12:
        std = float(h.std(ddof=0))
        scale = std if std > 1e-12 else max(abs(median) * 0.05, 1.0)
    return float(np.clip((float(latest) - median) / scale, -8.0, 8.0))


def load_official_broker_activity(
    store: Any,
    *,
    lookback_calendar_days: int = 120,
) -> pd.DataFrame:
    if store is None:
        return pd.DataFrame()
    since = (date.today() - timedelta(days=int(lookback_calendar_days))).isoformat()
    try:
        response = (
            store.client.table("flow_official_broker_activity")
            .select(
                "trade_date,broker_code,broker_name,traded_value,volume,frequency,"
                "source,source_verified,source_url,provenance_state"
            )
            .eq("source", OFFICIAL_IDX_BROKER_SOURCE)
            .eq("source_verified", True)
            .gte("trade_date", since)
            .order("trade_date")
            .execute()
        )
    except Exception:
        return pd.DataFrame()
    rows = response.data or []
    if not rows:
        return pd.DataFrame()
    out = pd.DataFrame(rows)
    out["trade_date"] = pd.to_datetime(out["trade_date"], errors="coerce").dt.normalize()
    out["broker_code"] = out["broker_code"].fillna("").astype(str).str.strip().str.upper()
    for column in ("traded_value", "volume", "frequency"):
        out[column] = pd.to_numeric(out[column], errors="coerce")
    out = out.dropna(subset=["trade_date", "traded_value", "volume", "frequency"])
    out = out[out["broker_code"].ne("")].copy()
    return out.sort_values(["trade_date", "broker_code"], kind="stable").reset_index(drop=True)


def compute_broker_market_regime(
    activity: pd.DataFrame | None,
    *,
    reference_date: str | pd.Timestamp | None = None,
) -> dict[str, object]:
    default = {
        "broker_behavior_available": False,
        "broker_behavior_source": OFFICIAL_IDX_BROKER_SOURCE,
        "broker_behavior_basis": BROKER_BEHAVIOR_BASIS,
        "broker_market_regime_score": 50.0,
        "broker_market_regime_label": "UNAVAILABLE",
        "broker_activity_sessions": 0,
        "broker_latest_date": None,
        "broker_latest_count": 0,
        "broker_top10_value_share_pct": 0.0,
        "broker_value_hhi_10k": 0.0,
        "broker_activity_breadth_pct": 0.0,
        "broker_value_zscore": 0.0,
        "broker_volume_zscore": 0.0,
        "broker_frequency_zscore": 0.0,
    }
    if activity is None or activity.empty:
        return default

    frame = activity.copy()
    frame["trade_date"] = pd.to_datetime(frame["trade_date"], errors="coerce").dt.normalize()
    frame["broker_code"] = frame["broker_code"].fillna("").astype(str).str.strip().str.upper()
    for column in ("traded_value", "volume", "frequency"):
        frame[column] = pd.to_numeric(frame[column], errors="coerce")
    frame = frame.dropna(subset=["trade_date", "traded_value", "volume", "frequency"])
    frame = frame[frame["broker_code"].ne("")].copy()
    if "source" in frame.columns:
        frame = frame[frame["source"].astype(str).eq(OFFICIAL_IDX_BROKER_SOURCE)].copy()
    if "source_verified" in frame.columns:
        verified = frame["source_verified"]
        if not pd.api.types.is_bool_dtype(verified):
            verified = verified.fillna(False).astype(str).str.strip().str.lower().isin({"1", "true", "yes"})
        frame = frame.loc[verified.fillna(False)].copy()
    if frame.empty:
        return default

    if reference_date is not None:
        ref = pd.to_datetime(reference_date, errors="coerce")
        if pd.notna(ref):
            frame = frame[frame["trade_date"].le(pd.Timestamp(ref).normalize())].copy()
    if frame.empty:
        return default

    dates = pd.DatetimeIndex(frame["trade_date"].dropna().unique()).sort_values()
    latest_date = pd.Timestamp(dates[-1])
    latest = frame[frame["trade_date"].eq(latest_date)].copy()
    history_dates = dates[:-1][-20:]
    history = frame[frame["trade_date"].isin(history_dates)].copy()

    daily = frame.groupby("trade_date", observed=True).agg(
        total_value=("traded_value", "sum"),
        total_volume=("volume", "sum"),
        total_frequency=("frequency", "sum"),
        broker_count=("broker_code", "nunique"),
    ).sort_index()
    current = daily.loc[latest_date]
    hist_daily = daily.loc[daily.index.isin(history_dates)]

    total_value = max(float(current["total_value"]), 0.0)
    shares = latest["traded_value"].clip(lower=0.0) / max(total_value, 1.0)
    top10_share = float(shares.nlargest(10).sum())
    hhi_10k = float((shares.pow(2).sum()) * 10000.0)

    if not history.empty:
        baseline = history.groupby("broker_code", observed=True)["traded_value"].median()
        latest_values = latest.set_index("broker_code")["traded_value"]
        aligned = latest_values.to_frame("latest").join(baseline.rename("baseline"), how="left")
        eligible = aligned["baseline"].fillna(0.0).gt(0.0)
        ratios = aligned.loc[eligible, "latest"] / aligned.loc[eligible, "baseline"].clip(lower=1.0)
        breadth_pct = 100.0 * float(ratios.ge(1.25).mean()) if len(ratios) else 0.0
    else:
        breadth_pct = 0.0

    value_z = _robust_z(float(current["total_value"]), hist_daily.get("total_value", pd.Series(dtype=float)))
    volume_z = _robust_z(float(current["total_volume"]), hist_daily.get("total_volume", pd.Series(dtype=float)))
    frequency_z = _robust_z(float(current["total_frequency"]), hist_daily.get("total_frequency", pd.Series(dtype=float)))

    score = _clip(
        0.35 * _sigmoid_score(value_z, 1.25)
        + 0.20 * _sigmoid_score(volume_z, 1.25)
        + 0.20 * _sigmoid_score(frequency_z, 1.25)
        + 0.25 * breadth_pct
    )

    if score >= 68.0 and breadth_pct >= 45.0:
        label = "BROAD_ACTIVITY_EXPANSION"
    elif score >= 62.0 and top10_share >= 0.68:
        label = "CONCENTRATED_ACTIVITY"
    elif score <= 35.0:
        label = "LOW_PARTICIPATION"
    else:
        label = "NORMAL_ACTIVITY"

    return {
        **default,
        "broker_behavior_available": True,
        "broker_market_regime_score": score,
        "broker_market_regime_label": label,
        "broker_activity_sessions": int(len(dates)),
        "broker_latest_date": latest_date.date().isoformat(),
        "broker_latest_count": int(latest["broker_code"].nunique()),
        "broker_top10_value_share_pct": 100.0 * top10_share,
        "broker_value_hhi_10k": hhi_10k,
        "broker_activity_breadth_pct": breadth_pct,
        "broker_value_zscore": value_z,
        "broker_volume_zscore": volume_z,
        "broker_frequency_zscore": frequency_z,
    }


def compute_ticker_broker_consensus(
    ticker: str,
    price: pd.DataFrame,
    foreign_features: dict[str, object],
    price_features: dict[str, object],
    broker_regime: dict[str, object] | None,
) -> dict[str, object]:
    regime = broker_regime or {}
    available = bool(regime.get("broker_behavior_available", False))
    if not available:
        return {
            **regime,
            "broker_behavior_consensus_score": 50.0,
            "broker_behavior_alignment_score": 50.0,
            "broker_turnover_expansion_score": 50.0,
            "broker_behavior_ticker": canonical_ticker(ticker),
        }

    foreign = _clip(float(foreign_features.get("foreign_institutional_score", 50.0) or 50.0))
    accumulation = _clip(float(price_features.get("proxy_accumulation_score", 50.0) or 50.0))
    absorption = _clip(float(price_features.get("proxy_absorption_score", 50.0) or 50.0))

    turnover_score = 50.0
    if price is not None and len(price) >= 20:
        px = price.sort_values("date").copy()
        value = pd.to_numeric(px["close"], errors="coerce") * pd.to_numeric(px["volume"], errors="coerce").fillna(0.0)
        recent = float(value.tail(5).mean()) if len(value.tail(5)) else 0.0
        baseline_slice = value.iloc[-20:-5] if len(value) >= 20 else value.iloc[:-5]
        baseline = float(baseline_slice.mean()) if len(baseline_slice) else 0.0
        ratio = recent / max(baseline, 1.0)
        turnover_score = _sigmoid_score(float(np.log(max(ratio, 1e-6))), 0.35)

    alignment = _clip(
        0.35 * foreign
        + 0.30 * accumulation
        + 0.20 * absorption
        + 0.15 * turnover_score
    )
    market_activity = _clip(float(regime.get("broker_market_regime_score", 50.0) or 50.0))
    breadth = _clip(float(regime.get("broker_activity_breadth_pct", 0.0) or 0.0))
    activation = float(np.clip((market_activity - 30.0) / 55.0, 0.20, 1.0))
    breadth_gate = 0.70 + 0.30 * (breadth / 100.0)
    raw_consensus = 50.0 + activation * breadth_gate * (alignment - 50.0)
    sessions = int(regime.get("broker_activity_sessions", 0) or 0)
    confidence = float(np.clip(sessions / 20.0, 0.0, 1.0))
    consensus = _clip(50.0 + confidence * (raw_consensus - 50.0))

    return {
        **regime,
        "broker_behavior_consensus_score": consensus,
        "broker_behavior_alignment_score": alignment,
        "broker_turnover_expansion_score": turnover_score,
        "broker_behavior_ticker": canonical_ticker(ticker),
    }
