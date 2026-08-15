from __future__ import annotations

import numpy as np
import pandas as pd


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
            "tp1": None, "tp2": None,
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
    risk = max((entry_low + entry_high)/2 - invalidation, atr*0.5)
    mid = (entry_low + entry_high)/2
    tp1, tp2 = mid + 2.0*risk, mid + 3.2*risk

    return {
        "smc_execution_score": score,
        "bos": bos,
        "choch": choch,
        "liquidity_sweep": liquidity_sweep,
        "fvg_low": fvg_low,
        "fvg_high": fvg_high,
        "entry_low": float(entry_low),
        "entry_high": float(entry_high),
        "invalidation": float(invalidation),
        "tp1": float(tp1),
        "tp2": float(tp2),
        "ema20": float(last["ema20"]),
        "ema50": float(last["ema50"]),
    }
