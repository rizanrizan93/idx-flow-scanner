from __future__ import annotations

import numpy as np
import pandas as pd


_COMMON_SPLIT_FACTORS = np.array([0.1, 0.2, 0.25, 1/3, 0.5, 2.0, 3.0, 4.0, 5.0, 10.0], dtype=float)


def _split_like_event(price: pd.DataFrame, lookback: int = 90) -> tuple[bool, str | None, float | None]:
    if price is None or len(price) < 3:
        return False, None, None
    px = price.sort_values("date").tail(max(3, int(lookback))).copy()
    close = pd.to_numeric(px["close"], errors="coerce")
    open_ = pd.to_numeric(px["open"], errors="coerce")
    prev = close.shift(1)
    ratio = open_ / prev.replace(0, np.nan)
    intraday = (close / open_.replace(0, np.nan) - 1.0).abs()
    for idx in range(1, len(px)):
        r = ratio.iloc[idx]
        move = intraday.iloc[idx]
        if not np.isfinite(r) or abs(float(r) - 1.0) < 0.35:
            continue
        nearest = float(_COMMON_SPLIT_FACTORS[np.argmin(np.abs(_COMMON_SPLIT_FACTORS - float(r)))])
        rel_error = abs(float(r) - nearest) / max(abs(nearest), 1e-9)
        # Require a gap very close to a common split/reverse-split factor and
        # a relatively normal intraday move so ordinary ARA/ARB events are less
        # likely to be misclassified as corporate actions.
        if rel_error <= 0.06 and (not np.isfinite(move) or float(move) <= 0.25):
            event_date = pd.to_datetime(px["date"].iloc[idx], errors="coerce")
            return True, event_date.date().isoformat() if pd.notna(event_date) else None, nearest
    return False, None, None


def compute_price_quality_features(price: pd.DataFrame, reference_date: str | pd.Timestamp | None = None) -> dict[str, object]:
    if price is None or price.empty:
        return {
            "price_data_quality_score": 0.0,
            "price_staleness_days": 999,
            "zero_volume_ratio_20d": 1.0,
            "unchanged_close_ratio_20d": 1.0,
            "ohlc_geometry_error_ratio": 1.0,
            "split_like_event_recent": False,
            "split_like_event_date": None,
            "split_like_factor": None,
        }
    px = price.sort_values("date").copy()
    dates = pd.to_datetime(px["date"], errors="coerce").dropna()
    latest = pd.Timestamp(dates.max()).normalize() if not dates.empty else pd.NaT
    ref = pd.Timestamp(reference_date).normalize() if reference_date is not None else latest
    staleness = int(max((ref - latest).days, 0)) if pd.notna(ref) and pd.notna(latest) else 999

    close = pd.to_numeric(px["close"], errors="coerce")
    volume = pd.to_numeric(px.get("volume"), errors="coerce").fillna(0.0)
    last20_close = close.tail(20)
    last20_volume = volume.tail(20)
    zero_volume = float((last20_volume <= 0).mean()) if len(last20_volume) else 1.0
    unchanged = float(last20_close.diff().eq(0).mean()) if len(last20_close) >= 2 else 1.0

    open_ = pd.to_numeric(px.get("open"), errors="coerce")
    high = pd.to_numeric(px.get("high"), errors="coerce")
    low = pd.to_numeric(px.get("low"), errors="coerce")
    geometry_bad = (
        high.lt(pd.concat([open_, close], axis=1).max(axis=1))
        | low.gt(pd.concat([open_, close], axis=1).min(axis=1))
        | high.lt(low)
        | close.le(0)
    )
    geometry_error = float(geometry_bad.tail(60).mean()) if len(geometry_bad) else 1.0
    split_like, split_date, split_factor = _split_like_event(px, lookback=90)

    score = 100.0
    if staleness > 0:
        score -= min(55.0, 10.0 * staleness)
    score -= max(0.0, zero_volume - 0.20) * 45.0
    score -= max(0.0, unchanged - 0.45) * 35.0
    score -= min(35.0, geometry_error * 100.0)
    if split_like:
        score -= 25.0
    score = float(np.clip(score, 0.0, 100.0))
    return {
        "price_data_quality_score": score,
        "price_staleness_days": staleness,
        "zero_volume_ratio_20d": zero_volume,
        "unchanged_close_ratio_20d": unchanged,
        "ohlc_geometry_error_ratio": geometry_error,
        "split_like_event_recent": bool(split_like),
        "split_like_event_date": split_date,
        "split_like_factor": split_factor,
    }
