from __future__ import annotations

import numpy as np
import pandas as pd

from .data import canonical_ticker
from .idx_trading_calendar import trading_session_age
from .provider_semantics import ProviderStatus, aggregate_provenance

BROKER_FRESH = "FRESH"
BROKER_STALE = "STALE"
BROKER_UNKNOWN = "UNKNOWN"
BROKER_MISSING = "MISSING"


def evaluate_broker_freshness(
    broker: pd.DataFrame | None,
    price: pd.DataFrame | None,
    ticker: str,
    *,
    max_age_days: int,
) -> dict[str, object]:
    """Return fail-closed, row-local broker validity and latest-age metadata.

    Existing thresholds are preserved, but age is measured in completed IDX
    sessions so weekends and exchange closures do not manufacture staleness.
    """
    frame = broker.copy() if broker is not None else pd.DataFrame()
    if frame.empty:
        return {
            "broker_latest_observation": None,
            "broker_latest_age_days": None,
            "broker_latest_age_sessions": None,
            "broker_freshness_state": BROKER_MISSING,
            "broker_data_available": False,
            "broker_data_valid": False,
            "broker_provider": None,
            "broker_provenance": [],
            "broker_provider_result_status": ProviderStatus.MISSING.value,
            "broker_canonical_provenance": "MISSING",
        }

    providers = (
        sorted(frame["source"].dropna().astype(str).str.strip().unique().tolist())
        if "source" in frame.columns
        else []
    )
    provenance = (
        sorted(frame["provenance_state"].dropna().astype(str).str.strip().unique().tolist())
        if "provenance_state" in frame.columns
        else []
    )
    base = {
        "broker_latest_observation": None,
        "broker_latest_age_days": None,
        "broker_latest_age_sessions": None,
        "broker_freshness_state": BROKER_UNKNOWN,
        "broker_data_available": True,
        "broker_data_valid": False,
        "broker_provider": ",".join(providers) if providers else "UNKNOWN",
        "broker_provenance": provenance,
        "broker_provider_result_status": ProviderStatus.INVALID.value,
        "broker_canonical_provenance": aggregate_provenance(*provenance).value,
    }
    required = {"ticker", "trade_date", "broker_code", "buy_value", "sell_value"}
    if not required.issubset(frame.columns):
        return base

    symbol = canonical_ticker(ticker)
    parsed_tickers = frame["ticker"].map(canonical_ticker)
    dates = pd.to_datetime(frame["trade_date"], errors="coerce").dt.normalize()
    broker_codes = frame["broker_code"].fillna("").astype(str).str.strip()
    numeric_valid = pd.Series(True, index=frame.index)
    for column in ("buy_value", "sell_value"):
        values = pd.to_numeric(frame[column], errors="coerce")
        numeric_valid &= values.notna() & np.isfinite(values) & values.ge(0)
    valid = bool(
        parsed_tickers.eq(symbol).all()
        and dates.notna().all()
        and broker_codes.ne("").all()
        and numeric_valid.all()
    )
    latest = dates.max() if dates.notna().any() else pd.NaT
    base["broker_data_valid"] = valid
    base["broker_latest_observation"] = (
        pd.Timestamp(latest).date().isoformat() if pd.notna(latest) else None
    )

    price_as_of = pd.NaT
    if price is not None and not price.empty and "date" in price.columns:
        price_as_of = pd.to_datetime(price["date"], errors="coerce").max()
    if not valid or pd.isna(latest) or pd.isna(price_as_of):
        return base

    age_days = trading_session_age(latest, price_as_of)
    if age_days is None:
        return base
    age_days = int(age_days)
    base["broker_latest_age_days"] = age_days
    base["broker_latest_age_sessions"] = age_days
    if age_days < 0:
        base["broker_data_valid"] = False
        return base
    base["broker_freshness_state"] = (
        BROKER_FRESH if age_days <= max(0, int(max_age_days)) else BROKER_STALE
    )
    base["broker_provider_result_status"] = (
        ProviderStatus.SUCCESS.value
        if base["broker_freshness_state"] == BROKER_FRESH
        else ProviderStatus.STALE.value
    )
    return base
