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


def _structural_resistance_levels(frame: pd.DataFrame, *, above: float, lookback: int = 80) -> list[float]:
    """Return distinct observed swing-high resistance levels above execution price."""
    if frame is None or frame.empty or not np.isfinite(above):
        return []
    high = pd.to_numeric(frame["high"], errors="coerce").tail(max(10, int(lookback))).reset_index(drop=True)
    levels: list[float] = []
    for i in range(2, max(2, len(high) - 2)):
        value = float(high.iloc[i]) if np.isfinite(high.iloc[i]) else np.nan
        if not np.isfinite(value) or value <= above:
            continue
        window = high.iloc[i-2:i+3]
        if np.isfinite(window).all() and value >= float(window.max()):
            levels.append(round_idx_price(value, "up"))
    # Prior-window highs are observed resistance even when they are not strict local pivots.
    for n in (20, 55, 80):
        hist = high.iloc[:-1].tail(n)
        if len(hist):
            value = float(hist.max())
            if np.isfinite(value) and value > above:
                levels.append(round_idx_price(value, "up"))
    return sorted({float(v) for v in levels if np.isfinite(v) and v > above})


def compute_smc_features(price: pd.DataFrame) -> dict[str, object]:
    if price is None or len(price) < 30:
        return {
            "smc_execution_score": 25.0, "bos": False, "choch": False,
            "liquidity_sweep": False, "fvg_low": None, "fvg_high": None,
            "entry_low": None, "entry_high": None, "invalidation": None,
            "tp1": None, "tp2": None, "execution_geometry_valid": False,
            "execution_rr1": None, "execution_rr2": None,
            "stop_basis": "STRUCTURE_UNAVAILABLE",
            "target_basis": "STRUCTURE_UNAVAILABLE",
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

    atr = float(last["atr"]) if np.isfinite(last["atr"]) else np.nan
    close = float(last["close"])
    score = 35.0 + 20.0 * trend_now + 20.0 * liquidity_sweep + 15.0 * choch + 10.0 * bos
    if fvg_low is not None:
        score += 5.0
    score = float(np.clip(score, 0, 100))

    if not np.isfinite(atr) or atr <= 0:
        return {
            "smc_execution_score": min(score, 25.0), "bos": bos, "choch": choch,
            "liquidity_sweep": liquidity_sweep, "fvg_low": fvg_low, "fvg_high": fvg_high,
            "entry_low": None, "entry_high": None, "invalidation": None, "tp1": None, "tp2": None,
            "ema20": float(last["ema20"]), "ema50": float(last["ema50"]),
            "execution_geometry_valid": False, "execution_levels_tradeable": False,
            "entry_within_next_session_price_band": False,
            "execution_entry_policy": "NEXT_COMPLETED_SESSION_OR_LATER",
            "execution_rr1": None, "execution_rr2": None,
            "stop_basis": "ATR_UNAVAILABLE", "target_basis": "STRUCTURE_UNAVAILABLE",
        }

    if fvg_low is not None and fvg_high is not None:
        entry_low, entry_high = min(fvg_low, fvg_high), max(fvg_low, fvg_high)
        entry_basis = "RECENT_FVG_RETEST_ZONE"
        if entry_high > close * 1.08 or entry_low < close * 0.75:
            entry_low, entry_high = close - 0.35*atr, close + 0.15*atr
            entry_basis = "EOD_RETEST_ZONE_PROXY"
    else:
        entry_low, entry_high = close - 0.35*atr, close + 0.15*atr
        entry_basis = "EOD_RETEST_ZONE_PROXY"

    entry_low = round_idx_price(entry_low, "down")
    entry_high = round_idx_price(entry_high, "up")

    # Stop must be tied to an observed swing/support. No ATR/R-multiple synthetic
    # stop is permitted to authorize execution.
    support_candidates = [v for v in (prev5_low, prev20_low) if np.isfinite(v) and v < entry_low]
    if support_candidates:
        support = max(support_candidates)
        invalidation = round_idx_price(support - idx_tick_size(support), "down")
        stop_basis = "OBSERVED_SWING_SUPPORT"
    else:
        invalidation = np.nan
        stop_basis = "STRUCTURE_UNAVAILABLE"

    # Targets must be observed resistance, never manufactured R multiples.
    resistance = _structural_resistance_levels(p.iloc[:-1], above=entry_high, lookback=80)
    tp1 = resistance[0] if len(resistance) >= 1 else np.nan
    tp2 = resistance[1] if len(resistance) >= 2 else np.nan
    target_basis = "OBSERVED_SWING_RESISTANCE" if len(resistance) >= 2 else "STRUCTURE_UNAVAILABLE"

    lower_band, upper_band = idx_daily_price_band(close)
    entry_band_valid = bool(lower_band <= entry_low <= upper_band and lower_band <= entry_high <= upper_band)
    level_values = (entry_low, entry_high, invalidation, tp1, tp2)
    levels_tradeable = bool(all(np.isfinite(v) and is_valid_idx_price(float(v)) for v in level_values))
    execution_price = float(entry_high)
    risk = execution_price - float(invalidation) if np.isfinite(invalidation) else np.nan
    rr1 = (float(tp1) - execution_price) / risk if np.isfinite(tp1) and np.isfinite(risk) and risk > 0 else np.nan
    rr2 = (float(tp2) - execution_price) / risk if np.isfinite(tp2) and np.isfinite(risk) and risk > 0 else np.nan
    rr_valid = bool(np.isfinite(rr1) and np.isfinite(rr2) and rr1 >= 1.5 and rr2 >= 2.0)

    execution_geometry_valid = bool(
        levels_tradeable
        and entry_band_valid
        and np.isfinite(risk) and risk > 0.0
        and invalidation < entry_low < entry_high < tp1 < tp2
        and rr_valid
        and stop_basis == "OBSERVED_SWING_SUPPORT"
        and target_basis == "OBSERVED_SWING_RESISTANCE"
    )
    if not execution_geometry_valid:
        entry_low = entry_high = invalidation = tp1 = tp2 = None
        score = min(score, 25.0)

    return {
        "smc_execution_score": score,
        "bos": bos, "choch": choch, "liquidity_sweep": liquidity_sweep,
        "fvg_low": fvg_low, "fvg_high": fvg_high,
        "entry_low": float(entry_low) if entry_low is not None else None,
        "entry_high": float(entry_high) if entry_high is not None else None,
        "invalidation": float(invalidation) if invalidation is not None else None,
        "tp1": float(tp1) if tp1 is not None else None,
        "tp2": float(tp2) if tp2 is not None else None,
        "ema20": float(last["ema20"]), "ema50": float(last["ema50"]),
        "execution_geometry_valid": execution_geometry_valid,
        "execution_levels_tradeable": bool(levels_tradeable),
        "entry_within_next_session_price_band": bool(entry_band_valid),
        "execution_entry_policy": "NEXT_COMPLETED_SESSION_OR_LATER",
        "entry_basis": entry_basis,
        "stop_basis": stop_basis,
        "target_basis": target_basis,
        "execution_rr1": round(float(rr1), 2) if np.isfinite(rr1) else None,
        "execution_rr2": round(float(rr2), 2) if np.isfinite(rr2) else None,
        "execution_rr_floor_pass": rr_valid,
        "target_candidate_count": len(resistance),
    }
