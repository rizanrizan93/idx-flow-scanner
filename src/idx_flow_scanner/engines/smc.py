from __future__ import annotations

import numpy as np
import pandas as pd


def idx_tick_size(price: float) -> int:
    if not np.isfinite(price) or price <= 0:
        return 1
    if price < 200:
        return 1
    if price < 500:
        return 2
    if price < 2000:
        return 5
    if price < 5000:
        return 10
    return 25


def round_idx_price(price: float, mode: str = "nearest") -> float:
    if not np.isfinite(price) or price <= 0:
        return np.nan
    tick = idx_tick_size(float(price))
    scaled = float(price) / tick
    if mode == "up":
        value = np.ceil(scaled - 1e-12) * tick
    elif mode == "down":
        value = np.floor(scaled + 1e-12) * tick
    else:
        value = np.round(scaled) * tick
    # Re-evaluate at a price-band boundary where the legal tick may change.
    tick2 = idx_tick_size(float(value))
    scaled2 = float(value) / tick2
    if mode == "up":
        value = np.ceil(scaled2 - 1e-12) * tick2
    elif mode == "down":
        value = np.floor(scaled2 + 1e-12) * tick2
    else:
        value = np.round(scaled2) * tick2
    return float(max(1.0, value))


def is_valid_idx_price(price: float | None) -> bool:
    if price is None:
        return False
    value = float(price)
    if not np.isfinite(value) or value < 50:
        return False
    tick = idx_tick_size(value)
    return bool(abs(value / tick - round(value / tick)) <= 1e-9)


def idx_daily_price_band(reference_price: float) -> tuple[float, float]:
    ara = 0.35 if reference_price <= 200 else 0.25 if reference_price <= 5000 else 0.20
    arb = 0.15
    return (
        round_idx_price(reference_price * (1.0 - arb), "up"),
        round_idx_price(reference_price * (1.0 + ara), "down"),
    )


def _atr(frame: pd.DataFrame, n: int = 14) -> pd.Series:
    h, l, c = frame["high"], frame["low"], frame["close"]
    prev = c.shift(1)
    tr = pd.concat([(h-l).abs(), (h-prev).abs(), (l-prev).abs()], axis=1).max(axis=1)
    return tr.rolling(n, min_periods=max(3, n//2)).mean()


def compute_smc_features(price: pd.DataFrame) -> dict[str, object]:
    if price is None or len(price) < 30:
        return {
            "smc_execution_score": 25.0, "bos": False, "choch": False,
            "liquidity_sweep": False, "fvg_low": None, "fvg_high": None,
            "entry_low": None, "entry_high": None, "invalidation": None,
            "tp1": None, "tp2": None, "execution_geometry_valid": False,
        }
    p = price.sort_values("date").copy().reset_index(drop=True)
    p["atr"] = _atr(p)
    p["ema20"] = p["close"].ewm(span=20, adjust=False).mean()
    p["ema50"] = p["close"].ewm(span=50, adjust=False).mean()

    last = p.iloc[-1]
    prev20_high = float(p["high"].iloc[-21:-1].max())
    prev20_low = float(p["low"].iloc[-21:-1].min())
    prev5_low = float(p["low"].iloc[-6:-1].min())
    bos = bool(last["close"] > prev20_high)
    liquidity_sweep = bool(last["low"] < prev5_low and last["close"] > prev5_low)
    trend_now = bool(last["ema20"] >= last["ema50"])
    trend_prev = bool(p["ema20"].iloc[-6] >= p["ema50"].iloc[-6])
    choch = bool(trend_now and not trend_prev)

    fvg_low = fvg_high = None
    for i in range(max(2, len(p)-15), len(p)):
        if i >= 2 and float(p.loc[i, "low"]) > float(p.loc[i-2, "high"]):
            fvg_low = float(p.loc[i-2, "high"])
            fvg_high = float(p.loc[i, "low"])

    atr = float(last["atr"]) if np.isfinite(last["atr"]) else float(last["close"] * 0.03)
    close = float(last["close"])
    score = 35.0 + 20.0 * trend_now + 20.0 * liquidity_sweep + 15.0 * choch + 10.0 * bos
    if fvg_low is not None:
        score += 5.0
    score = float(np.clip(score, 0, 100))

    if fvg_low is not None and fvg_high is not None:
        entry_low, entry_high = min(fvg_low, fvg_high), max(fvg_low, fvg_high)
        if entry_high > close * 1.08 or entry_low < close * 0.75:
            entry_low, entry_high = close - 0.35*atr, close + 0.15*atr
    else:
        entry_low, entry_high = close - 0.35*atr, close + 0.15*atr
    invalidation = min(prev5_low, entry_low - 0.8*atr)

    # Convert every actionable level to a legal IDX regular-market price fraction.
    entry_low = round_idx_price(entry_low, "down")
    entry_high = round_idx_price(entry_high, "up")
    invalidation = round_idx_price(invalidation, "down")
    mid = (entry_low + entry_high) / 2.0
    risk = max(mid - invalidation, atr * 0.5)
    tp1 = round_idx_price(mid + 2.0 * risk, "up")
    tp2 = round_idx_price(mid + 3.2 * risk, "up")

    lower_band, upper_band = idx_daily_price_band(close)
    entry_band_valid = bool(lower_band <= entry_low <= upper_band and lower_band <= entry_high <= upper_band)
    levels_tradeable = all(is_valid_idx_price(v) for v in (entry_low, entry_high, invalidation, tp1, tp2))

    geometry = np.array([entry_low, entry_high, invalidation, tp1, tp2, risk], dtype=float)
    execution_geometry_valid = bool(
        np.isfinite(geometry).all()
        and risk > 0.0
        and entry_high > entry_low
        and invalidation < entry_low
        and tp1 > entry_high
        and tp2 > tp1
        and levels_tradeable
        and entry_band_valid
    )
    if not execution_geometry_valid:
        entry_low = entry_high = invalidation = tp1 = tp2 = None
        score = min(score, 25.0)

    return {
        "smc_execution_score": score,
        "bos": bos,
        "choch": choch,
        "liquidity_sweep": liquidity_sweep,
        "fvg_low": fvg_low,
        "fvg_high": fvg_high,
        "entry_low": float(entry_low) if entry_low is not None else None,
        "entry_high": float(entry_high) if entry_high is not None else None,
        "invalidation": float(invalidation) if invalidation is not None else None,
        "tp1": float(tp1) if tp1 is not None else None,
        "tp2": float(tp2) if tp2 is not None else None,
        "ema20": float(last["ema20"]),
        "ema50": float(last["ema50"]),
        "execution_geometry_valid": execution_geometry_valid,
        "execution_levels_tradeable": bool(levels_tradeable),
        "entry_within_next_session_price_band": bool(entry_band_valid),
        "execution_entry_policy": "NEXT_COMPLETED_SESSION_OR_LATER",
        "target_basis": "R_MULTIPLE_RESEARCH_TARGETS_NOT_STRUCTURAL_RESISTANCE",
    }
