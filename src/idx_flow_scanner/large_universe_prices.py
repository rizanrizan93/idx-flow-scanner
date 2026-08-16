from __future__ import annotations

from pathlib import Path
from typing import Callable

import pandas as pd

from .data import canonical_ticker, fetch_yfinance_prices_batch, normalize_price_frame
from .database_first import load_bundled_price_seed, prepare_database_first_prices as _legacy_prepare
from .storage import SupabaseStore


LARGE_UNIVERSE_THRESHOLD = 100
DB_CHUNK_SIZE = 8
DB_ROW_LIMIT = 120
MAX_CONSECUTIVE_EMPTY_DB_CHUNKS = 2


def _bounded_db_prices(
    store: SupabaseStore,
    names: list[str],
    *,
    min_rows: int,
    status: Callable[[str], None] | None = None,
) -> tuple[dict[str, pd.DataFrame], int, str]:
    """Read the preferred per-ticker RPC with a hard failure/empty-response budget.

    Large managed scans must never cascade from a failed bulk RPC into hundreds of
    single-ticker PostgREST requests. A cache is acceleration only; once the bounded
    transport is unhealthy we fail over to the bundled seed in-process.
    """
    out: dict[str, pd.DataFrame] = {}
    errors = 0
    consecutive_empty = 0
    state = "PER_TICKER_JSON_RPC_BOUNDED"

    for start in range(0, len(names), DB_CHUNK_SIZE):
        chunk = names[start:start + DB_CHUNK_SIZE]
        try:
            response = store.client.rpc(
                "flow_load_price_cache_by_ticker",
                {"p_tickers": chunk, "p_limit": DB_ROW_LIMIT},
            ).execute()
        except Exception:
            errors += 1
            state = "DB_RPC_FAILED_FAST_TO_SEED"
            break

        rows = response.data or []
        if isinstance(rows, dict):
            rows = [rows]
        chunk_hits = 0
        for item in rows if isinstance(rows, list) else []:
            if not isinstance(item, dict):
                continue
            ticker = canonical_ticker(item.get("ticker"))
            payload = item.get("payload")
            if not ticker or not isinstance(payload, list) or not payload:
                continue
            try:
                frame = normalize_price_frame(
                    pd.DataFrame(payload).rename(columns={"trade_date": "date"}),
                    ticker,
                )
            except Exception:
                continue
            if len(frame) >= int(min_rows):
                out[ticker] = frame.tail(DB_ROW_LIMIT).reset_index(drop=True)
                chunk_hits += 1

        if chunk_hits == 0:
            consecutive_empty += 1
        else:
            consecutive_empty = 0

        if status:
            status(
                f"Checking bounded Supabase OHLCV • {min(start + len(chunk), len(names))}/{len(names)} • hits {len(out)}"
            )

        if consecutive_empty >= MAX_CONSECUTIVE_EMPTY_DB_CHUNKS:
            state = "DB_EMPTY_FAST_TO_SEED"
            break

    return out, errors, state


def prepare_large_universe_prices(
    universe: list[str],
    store: SupabaseStore | None,
    period: str = "1y",
    *,
    min_rows: int = 80,
    status: Callable[[str], None] | None = None,
    seed_path: Path | None = None,
):
    """Production-safe price preparation for the bundled 400-ticker run.

    For small/ad-hoc universes the existing loader is retained. For large managed
    universes, only the preferred bounded Supabase RPC is attempted. Any RPC error
    or repeated empty response immediately falls back to the verified bundled
    OHLCV seed, avoiding the former 400 x single-request timeout cascade.
    PRICE_PROXY semantics are unchanged: neither cache nor seed can become broker
    evidence.
    """
    names = list(dict.fromkeys(canonical_ticker(t) for t in universe if canonical_ticker(t)))
    if len(names) < LARGE_UNIVERSE_THRESHOLD:
        return _legacy_prepare(
            universe,
            store,
            period=period,
            min_rows=min_rows,
            status=status,
            seed_path=seed_path,
        )

    frames: dict[str, pd.DataFrame] = {}
    db_errors = 0
    transport = "NO_DATABASE"
    if store is not None:
        frames, db_errors, transport = _bounded_db_prices(
            store,
            names,
            min_rows=min_rows,
            status=status,
        )

    cache_hits = len(frames)
    missing_after_db = [ticker for ticker in names if ticker not in frames]

    seed_hits = 0
    if missing_after_db and str(period).lower() in {"6mo", "1y"}:
        seed_map = load_bundled_price_seed(seed_path, min_rows=min_rows)
        for ticker in missing_after_db:
            frame = seed_map.get(ticker, pd.DataFrame())
            if len(frame) >= int(min_rows):
                frames[ticker] = frame
                seed_hits += 1
        if status:
            status(
                f"Bundled OHLCV failover • valid {seed_hits}/{len(missing_after_db)} • no per-ticker DB writeback"
            )

    missing = [ticker for ticker in names if ticker not in frames]
    fetched_valid = 0
    if missing:
        fresh_map = fetch_yfinance_prices_batch(missing, period=period)
        for ticker in missing:
            frame = fresh_map.get(ticker, pd.DataFrame())
            if len(frame) >= int(min_rows):
                frames[ticker] = frame
                fetched_valid += 1
        if status:
            status(
                f"Yahoo fallback • valid {fetched_valid}/{len(missing)} • unavailable {len(missing) - fetched_valid}"
            )

    failures = [ticker for ticker in names if ticker not in frames]

    def load(ticker: str) -> pd.DataFrame:
        return frames.get(canonical_ticker(ticker), pd.DataFrame())

    stats: dict[str, object] = {
        "universe": len(names),
        "cache_hits": cache_hits,
        "cache_misses": len(missing_after_db),
        "bulk_cache_used": bool(cache_hits),
        "bulk_cache_transport": transport,
        "seed_hits": seed_hits,
        "seed_persisted": 0,
        "fetched_valid": fetched_valid,
        "fetched_persisted": 0,
        "persisted_tickers": 0,
        "db_read_errors": db_errors,
        "persist_errors": 0,
        "unavailable": len(failures),
        "unavailable_tickers": failures,
        "large_universe_fast_fail": True,
    }
    return load, stats
