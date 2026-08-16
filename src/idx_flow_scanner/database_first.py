from __future__ import annotations

from dataclasses import dataclass
from typing import Callable

import pandas as pd

from .data import canonical_ticker, fetch_yfinance_prices, fetch_yfinance_prices_batch
from .storage import SupabaseStore


@dataclass(frozen=True)
class DataLoadState:
    ticker: str
    price_source: str
    price_rows: int
    broker_rows: int
    broker_days: int


def prepare_database_first_prices(
    universe: list[str],
    store: SupabaseStore | None,
    period: str = "1y",
    *,
    min_rows: int = 80,
    status: Callable[[str], None] | None = None,
) -> tuple[Callable[[str], pd.DataFrame], dict[str, object]]:
    """Build one in-memory price map before scoring.

    Cold-start behaviour matters on Streamlit: a per-ticker Yahoo fallback turns a
    400-name scan into a burst of 400 external requests. We first reuse Supabase,
    then fetch only missing names through the throttled batch adapter, persist valid
    frames, and finally scan from memory. Missing data remains an explicit failure.
    """
    names = list(dict.fromkeys(canonical_ticker(t) for t in universe if canonical_ticker(t)))
    frames: dict[str, pd.DataFrame] = {}
    cache_hits = 0
    db_read_errors = 0

    if store is not None:
        for i, ticker in enumerate(names, 1):
            try:
                cached = store.load_prices(ticker, min_rows=min_rows)
            except Exception:
                cached = pd.DataFrame()
                db_read_errors += 1
            if len(cached) >= min_rows:
                frames[ticker] = cached
                cache_hits += 1
            if status and (i == 1 or i % 25 == 0 or i == len(names)):
                status(f"Checking Supabase OHLCV cache • {i}/{len(names)} • hits {cache_hits}")

    missing = [t for t in names if t not in frames]
    if status:
        status(f"OHLCV cache ready • {cache_hits}/{len(names)} hit • fetching {len(missing)} missing")

    fetched_valid = 0
    persisted = 0
    persist_errors = 0
    if missing:
        fresh_map = fetch_yfinance_prices_batch(missing, period=period)
        for ticker in missing:
            frame = fresh_map.get(ticker, pd.DataFrame())
            if len(frame) < min_rows:
                continue
            frames[ticker] = frame
            fetched_valid += 1
            if store is not None:
                try:
                    persisted += int(store.upsert_prices(ticker, frame, source="YFINANCE_BATCH") > 0)
                except Exception:
                    persist_errors += 1
        if status:
            status(
                f"Yahoo batch completed • valid {fetched_valid}/{len(missing)} • "
                f"persisted {persisted} • unavailable {len(missing) - fetched_valid}"
            )

    failures = [t for t in names if t not in frames]

    def load(ticker: str) -> pd.DataFrame:
        return frames.get(canonical_ticker(ticker), pd.DataFrame())

    stats: dict[str, object] = {
        "universe": len(names),
        "cache_hits": cache_hits,
        "cache_misses": len(missing),
        "fetched_valid": fetched_valid,
        "persisted_tickers": persisted,
        "db_read_errors": db_read_errors,
        "persist_errors": persist_errors,
        "unavailable": len(failures),
        "unavailable_tickers": failures,
    }
    return load, stats


def database_first_price_loader(store: SupabaseStore | None, period: str = "1y") -> Callable[[str], pd.DataFrame]:
    """Single-ticker compatibility loader; large scans should use prepare_database_first_prices."""
    def load(ticker: str) -> pd.DataFrame:
        if store is not None:
            try:
                cached = store.load_prices(ticker, min_rows=80)
                if len(cached) >= 80:
                    return cached
            except Exception:
                pass
        fresh = fetch_yfinance_prices(ticker, period=period)
        if store is not None and not fresh.empty:
            try:
                store.upsert_prices(ticker, fresh)
            except Exception:
                pass
        return fresh
    return load


def broker_database_coverage(universe: list[str], broker: pd.DataFrame, lookback_days: int = 20) -> pd.DataFrame:
    rows = []
    if broker is None or broker.empty:
        return pd.DataFrame({"ticker": universe, "broker_days": 0, "broker_ready": False})
    for ticker in universe:
        b = broker[broker["ticker"] == ticker]
        days = int(b["trade_date"].nunique()) if not b.empty else 0
        rows.append({"ticker": ticker, "broker_days": days, "broker_ready": days >= lookback_days})
    return pd.DataFrame(rows)
