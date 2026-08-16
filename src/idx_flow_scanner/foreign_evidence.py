from __future__ import annotations

from typing import Callable, Iterable

import pandas as pd

from .data import canonical_ticker


def _coverage(frame: pd.DataFrame, price: pd.DataFrame, lookback: int = 20) -> float:
    if frame is None or frame.empty or price is None or price.empty:
        return 0.0
    px_days = pd.DatetimeIndex(pd.to_datetime(price["date"], errors="coerce").dropna().unique())[-lookback:]
    flow_days = pd.DatetimeIndex(pd.to_datetime(frame["trade_date"], errors="coerce").dropna().unique())
    return 100.0 * len(px_days.intersection(flow_days)) / max(len(px_days), 1)


def _hydrate_vendor_turnover(frame: pd.DataFrame, price: pd.DataFrame) -> pd.DataFrame:
    """Use same-unit IDR turnover proxy for vendor foreign-value intensity.

    Index Alpha foreign flow is IDR value. Existing foreign scoring expects the
    denominator in ``volume``; for vendor rows we intentionally place daily
    close*volume IDR turnover there. Official IDX rows keep actual traded shares.
    The selector never mixes both units for the same ticker in one scoring frame.
    """
    out = frame.copy()
    px = price[["date", "close", "volume"]].copy()
    px["trade_date"] = pd.to_datetime(px["date"], errors="coerce").dt.normalize()
    px["turnover_proxy"] = pd.to_numeric(px["close"], errors="coerce") * pd.to_numeric(px["volume"], errors="coerce")
    out["trade_date"] = pd.to_datetime(out["trade_date"], errors="coerce").dt.normalize()
    out = out.drop(columns=["volume"], errors="ignore").merge(
        px[["trade_date", "turnover_proxy"]], on="trade_date", how="left"
    )
    out["volume"] = pd.to_numeric(out.pop("turnover_proxy"), errors="coerce").fillna(0.0)
    out["flow_unit"] = "IDR"
    return out


def prepare_foreign_evidence(
    universe: Iterable[str],
    official: pd.DataFrame,
    vendor: pd.DataFrame,
    price_loader: Callable[[str], pd.DataFrame],
    *,
    lookback: int = 20,
) -> tuple[pd.DataFrame, dict[str, object]]:
    """Choose one dimensionally consistent foreign source per ticker.

    Higher recent trading-day coverage wins. Exact ties prefer official IDX.
    This gives a lawful fallback without adding official share counts to vendor
    IDR values or mislabelling vendor evidence as official.
    """
    official = official.copy() if official is not None else pd.DataFrame()
    vendor = vendor.copy() if vendor is not None else pd.DataFrame()
    for frame in (official, vendor):
        if not frame.empty:
            frame["ticker"] = frame["ticker"].map(canonical_ticker)
            frame["trade_date"] = pd.to_datetime(frame["trade_date"], errors="coerce").dt.normalize()

    selected: list[pd.DataFrame] = []
    source_counts = {"IDX_OFFICIAL": 0, "VERIFIED_VENDOR": 0, "NONE": 0}
    coverage_values: list[float] = []
    for raw_ticker in universe:
        ticker = canonical_ticker(raw_ticker)
        price = price_loader(ticker)
        of = official[official["ticker"] == ticker].copy() if not official.empty else pd.DataFrame()
        vf = vendor[vendor["ticker"] == ticker].copy() if not vendor.empty else pd.DataFrame()
        official_cov = _coverage(of, price, lookback)
        vendor_cov = _coverage(vf, price, lookback)
        if official_cov <= 0 and vendor_cov <= 0:
            source_counts["NONE"] += 1
            coverage_values.append(0.0)
            continue
        if official_cov >= vendor_cov:
            chosen = of
            chosen["flow_unit"] = "SHARES"
            chosen["foreign_evidence_source"] = "IDX_OFFICIAL"
            source_counts["IDX_OFFICIAL"] += 1
            coverage_values.append(official_cov)
        else:
            chosen = _hydrate_vendor_turnover(vf, price)
            chosen["foreign_evidence_source"] = "VERIFIED_VENDOR"
            source_counts["VERIFIED_VENDOR"] += 1
            coverage_values.append(vendor_cov)
        selected.append(chosen)

    out = pd.concat(selected, ignore_index=True) if selected else pd.DataFrame()
    stats = {
        "idx_official_selected_tickers": source_counts["IDX_OFFICIAL"],
        "vendor_selected_tickers": source_counts["VERIFIED_VENDOR"],
        "foreign_unavailable_tickers": source_counts["NONE"],
        "median_selected_coverage_pct": float(pd.Series(coverage_values).median()) if coverage_values else 0.0,
    }
    return out, stats
