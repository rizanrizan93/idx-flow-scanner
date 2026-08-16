from __future__ import annotations

import math
from typing import Mapping

import numpy as np
import pandas as pd


def _sigmoid_score(value: float, scale: float) -> float:
    if not np.isfinite(value):
        return 50.0
    z = float(np.clip(value / max(scale, 1e-9), -12.0, 12.0))
    return float(100.0 / (1.0 + math.exp(-z)))


def _return_n(price: pd.DataFrame, sessions: int) -> float | None:
    if price is None or price.empty or len(price) <= sessions:
        return None
    close = pd.to_numeric(price["close"], errors="coerce").dropna()
    if len(close) <= sessions:
        return None
    first = float(close.iloc[-(sessions + 1)])
    last = float(close.iloc[-1])
    if not np.isfinite(first) or not np.isfinite(last) or first <= 0:
        return None
    return float(last / first - 1.0)


def compute_market_context(price_map: Mapping[str, pd.DataFrame]) -> dict[str, object]:
    """Build a free market-regime proxy from the scanner universe itself.

    This deliberately avoids paid sector/index feeds. It is a cross-sectional
    breadth/median-return context, not a claim about an official IDX sector index.
    """
    rows: list[dict[str, object]] = []
    latest_dates: list[pd.Timestamp] = []
    for ticker, price in price_map.items():
        if price is None or price.empty:
            continue
        dates = pd.to_datetime(price.get("date"), errors="coerce").dropna()
        if not dates.empty:
            latest_dates.append(pd.Timestamp(dates.max()).normalize())
        r20 = _return_n(price, 20)
        r60 = _return_n(price, 60)
        if r20 is not None or r60 is not None:
            rows.append({"ticker": ticker, "r20": r20, "r60": r60})

    frame = pd.DataFrame(rows)
    if frame.empty:
        return {
            "market_regime_score": 50.0,
            "market_regime_label": "UNKNOWN",
            "breadth_20d": 0.5,
            "breadth_60d": 0.5,
            "median_return_20d": 0.0,
            "median_return_60d": 0.0,
            "reference_date": max(latest_dates).date().isoformat() if latest_dates else None,
            "ticker_returns": {},
            "coverage_count": 0,
        }

    r20 = pd.to_numeric(frame["r20"], errors="coerce")
    r60 = pd.to_numeric(frame["r60"], errors="coerce")
    valid20 = r20.dropna(); valid60 = r60.dropna()
    breadth20 = float((valid20 > 0).mean()) if len(valid20) else 0.5
    breadth60 = float((valid60 > 0).mean()) if len(valid60) else 0.5
    med20 = float(valid20.median()) if len(valid20) else 0.0
    med60 = float(valid60.median()) if len(valid60) else 0.0
    score = (
        0.35 * breadth20 * 100.0
        + 0.20 * breadth60 * 100.0
        + 0.27 * _sigmoid_score(med20, 0.055)
        + 0.18 * _sigmoid_score(med60, 0.11)
    )
    score = float(np.clip(score, 0.0, 100.0))
    if score >= 65:
        label = "RISK_ON"
    elif score >= 55:
        label = "CONSTRUCTIVE"
    elif score >= 45:
        label = "NEUTRAL"
    elif score >= 35:
        label = "DEFENSIVE"
    else:
        label = "RISK_OFF"

    ticker_returns = {
        str(row.ticker): {
            "r20": float(row.r20) if pd.notna(row.r20) else None,
            "r60": float(row.r60) if pd.notna(row.r60) else None,
        }
        for row in frame.itertuples(index=False)
    }
    return {
        "market_regime_score": score,
        "market_regime_label": label,
        "breadth_20d": breadth20,
        "breadth_60d": breadth60,
        "median_return_20d": med20,
        "median_return_60d": med60,
        "reference_date": max(latest_dates).date().isoformat() if latest_dates else None,
        "ticker_returns": ticker_returns,
        "coverage_count": int(max(len(valid20), len(valid60))),
    }


def ticker_market_features(ticker: str, context: Mapping[str, object]) -> dict[str, object]:
    market = float(context.get("market_regime_score", 50.0) or 50.0)
    med20 = float(context.get("median_return_20d", 0.0) or 0.0)
    med60 = float(context.get("median_return_60d", 0.0) or 0.0)
    returns = context.get("ticker_returns", {}) or {}
    item = returns.get(ticker, {}) if isinstance(returns, dict) else {}
    r20 = item.get("r20") if isinstance(item, dict) else None
    r60 = item.get("r60") if isinstance(item, dict) else None
    rel20 = float(r20 - med20) if r20 is not None else 0.0
    rel60 = float(r60 - med60) if r60 is not None else 0.0
    rs20 = _sigmoid_score(rel20, 0.06)
    rs60 = _sigmoid_score(rel60, 0.12)
    combined = float(np.clip(0.55 * market + 0.30 * rs20 + 0.15 * rs60, 0.0, 100.0))
    return {
        "market_sector_score": combined,
        "market_regime_score": market,
        "market_regime_label": str(context.get("market_regime_label", "UNKNOWN")),
        "market_breadth_20d": float(context.get("breadth_20d", 0.5) or 0.5),
        "market_breadth_60d": float(context.get("breadth_60d", 0.5) or 0.5),
        "universe_median_return_20d": med20 * 100.0,
        "universe_median_return_60d": med60 * 100.0,
        "relative_strength_20d_pct": rel20 * 100.0,
        "relative_strength_60d_pct": rel60 * 100.0,
        "market_context_basis": "UNIVERSE_BREADTH_RELATIVE_STRENGTH",
        "market_context_coverage": int(context.get("coverage_count", 0) or 0),
        "market_reference_date": context.get("reference_date"),
    }
