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


def _regime_score(r20: pd.Series, r60: pd.Series) -> tuple[float, float, float, float, float]:
    valid20 = pd.to_numeric(r20, errors="coerce").dropna()
    valid60 = pd.to_numeric(r60, errors="coerce").dropna()
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
    return float(np.clip(score, 0.0, 100.0)), breadth20, breadth60, med20, med60


def _label(score: float) -> str:
    if score >= 65:
        return "RISK_ON"
    if score >= 55:
        return "CONSTRUCTIVE"
    if score >= 45:
        return "NEUTRAL"
    if score >= 35:
        return "DEFENSIVE"
    return "RISK_OFF"


def compute_market_context(
    price_map: Mapping[str, pd.DataFrame],
    sector_map: Mapping[str, str] | None = None,
) -> dict[str, object]:
    """Build market + sector regime from the managed universe.

    With no sector map this preserves the historical cross-sectional behaviour.
    When sector metadata is supplied, each ticker is also compared with its own
    IDX sector using sector breadth and sector-relative strength.
    """
    sector_map = {str(k): str(v) for k, v in dict(sector_map or {}).items()}
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
            rows.append(
                {
                    "ticker": ticker,
                    "sector": sector_map.get(ticker, "UNKNOWN"),
                    "r20": r20,
                    "r60": r60,
                }
            )

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
            "sector_context": {},
        }

    market_score, breadth20, breadth60, med20, med60 = _regime_score(frame["r20"], frame["r60"])
    ticker_returns = {
        str(row.ticker): {
            "sector": str(row.sector),
            "r20": float(row.r20) if pd.notna(row.r20) else None,
            "r60": float(row.r60) if pd.notna(row.r60) else None,
        }
        for row in frame.itertuples(index=False)
    }

    sector_context: dict[str, dict[str, object]] = {}
    if sector_map:
        for sector, group in frame[frame["sector"].ne("UNKNOWN")].groupby("sector", observed=True):
            if len(group) < 3:
                continue
            score, b20, b60, s20, s60 = _regime_score(group["r20"], group["r60"])
            sector_context[str(sector)] = {
                "score": score,
                "label": _label(score),
                "breadth_20d": b20,
                "breadth_60d": b60,
                "median_return_20d": s20,
                "median_return_60d": s60,
                "coverage_count": int(max(group["r20"].notna().sum(), group["r60"].notna().sum())),
            }

    return {
        "market_regime_score": market_score,
        "market_regime_label": _label(market_score),
        "breadth_20d": breadth20,
        "breadth_60d": breadth60,
        "median_return_20d": med20,
        "median_return_60d": med60,
        "reference_date": max(latest_dates).date().isoformat() if latest_dates else None,
        "ticker_returns": ticker_returns,
        "coverage_count": int(max(frame["r20"].notna().sum(), frame["r60"].notna().sum())),
        "sector_context": sector_context,
    }


def ticker_market_features(ticker: str, context: Mapping[str, object]) -> dict[str, object]:
    market = float(context.get("market_regime_score", 50.0) or 50.0)
    med20 = float(context.get("median_return_20d", 0.0) or 0.0)
    med60 = float(context.get("median_return_60d", 0.0) or 0.0)
    returns = context.get("ticker_returns", {}) or {}
    item = returns.get(ticker, {}) if isinstance(returns, dict) else {}
    r20 = item.get("r20") if isinstance(item, dict) else None
    r60 = item.get("r60") if isinstance(item, dict) else None
    sector = str(item.get("sector") or "UNKNOWN") if isinstance(item, dict) else "UNKNOWN"

    rel20 = float(r20 - med20) if r20 is not None else 0.0
    rel60 = float(r60 - med60) if r60 is not None else 0.0
    market_rs = 0.70 * _sigmoid_score(rel20, 0.06) + 0.30 * _sigmoid_score(rel60, 0.12)

    sectors = context.get("sector_context", {}) or {}
    sector_data = sectors.get(sector, {}) if isinstance(sectors, dict) else {}
    sector_score = float(sector_data.get("score", market) or market)
    sector_med20 = float(sector_data.get("median_return_20d", med20) or 0.0)
    sector_med60 = float(sector_data.get("median_return_60d", med60) or 0.0)
    sector_rel20 = float(r20 - sector_med20) if r20 is not None else 0.0
    sector_rel60 = float(r60 - sector_med60) if r60 is not None else 0.0
    sector_rs = 0.70 * _sigmoid_score(sector_rel20, 0.05) + 0.30 * _sigmoid_score(sector_rel60, 0.10)

    # Market regime 30% + sector regime 30% + sector RS 25% + market RS 15%.
    combined = float(np.clip(
        0.30 * market + 0.30 * sector_score + 0.25 * sector_rs + 0.15 * market_rs,
        0.0,
        100.0,
    ))
    basis = "MARKET_30__SECTOR_30__SECTOR_RS_25__MARKET_RS_15" if sector_data else "UNIVERSE_BREADTH_RELATIVE_STRENGTH"

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
        "sector": sector,
        "sector_regime_score": sector_score,
        "sector_regime_label": str(sector_data.get("label", "UNKNOWN")),
        "sector_breadth_20d": float(sector_data.get("breadth_20d", 0.5) or 0.5),
        "sector_breadth_60d": float(sector_data.get("breadth_60d", 0.5) or 0.5),
        "sector_relative_strength_20d_pct": sector_rel20 * 100.0,
        "sector_relative_strength_60d_pct": sector_rel60 * 100.0,
        "market_context_basis": basis,
        "market_context_coverage": int(context.get("coverage_count", 0) or 0),
        "sector_context_coverage": int(sector_data.get("coverage_count", 0) or 0),
        "market_reference_date": context.get("reference_date"),
    }
