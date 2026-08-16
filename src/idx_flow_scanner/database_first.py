from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Callable

import pandas as pd

from .data import canonical_ticker, fetch_yfinance_prices, fetch_yfinance_prices_batch, normalize_price_frame
from .storage import SupabaseStore


@dataclass(frozen=True)
class DataLoadState:
    ticker: str
    price_source: str
    price_rows: int
    broker_rows: int
    broker_days: int


def _default_seed_path() -> Path:
    return Path(__file__).resolve().parents[2] / "data" / "cache" / "idx_400_ohlcv_1y.csv.gz"


def load_bundled_price_seed(
    path: Path | None = None,
    *,
    min_rows: int = 80,
) -> dict[str, pd.DataFrame]:
    """Load the verified GitHub-built OHLCV seed, if present.

    The seed is only a cold-start transport cache. It does not change the
    evidence tier and never creates broker/direct evidence.
    """
    seed_path = path or _default_seed_path()
    if not seed_path.exists():
        return {}
    try:
        raw = pd.read_csv(seed_path)
    except Exception:
        return {}
    required = {"ticker", "date", "open", "high", "low", "close", "volume"}
    if not required.issubset({str(c).strip().lower() for c in raw.columns}):
        return {}
    raw.columns = [str(c).strip().lower() for c in raw.columns]
    out: dict[str, pd.DataFrame] = {}
    for ticker, group in raw.groupby(raw["ticker"].map(canonical_ticker), sort=False):
        try:
            frame = normalize_price_frame(group.drop(columns=["ticker"], errors="ignore"), ticker)
        except Exception:
            continue
        if len(frame) >= int(min_rows):
            out[canonical_ticker(ticker)] = frame
    return out


def _load_prices_bulk_json(
    store: SupabaseStore,
    names: list[str],
    *,
    min_rows: int,
    limit: int = 450,
    chunk_size: int = 20,
    status: Callable[[str], None] | None = None,
) -> dict[str, pd.DataFrame]:
    """Load multi-ticker OHLCV through a single-row JSON RPC per chunk.

    PostgREST applies its row cap to set-returning RPC results. The prior bulk
    RPC could therefore truncate a 20-ticker response near 1,000 rows and make
    healthy cached tickers look missing. The JSON projection returns one row
    containing the per-ticker payload, so the Data API row cap cannot silently
    truncate the cache cohort.
    """
    out: dict[str, pd.DataFrame] = {}
    step = max(1, min(int(chunk_size), 40))
    for start in range(0, len(names), step):
        chunk = names[start:start + step]
        response = store.client.rpc(
            "flow_load_price_cache_json",
            {"p_tickers": chunk, "p_limit": int(limit)},
        ).execute()
        data = response.data or []
        payload = []
        if isinstance(data, list) and data:
            first = data[0]
            payload = first.get("payload", []) if isinstance(first, dict) else []
        elif isinstance(data, dict):
            payload = data.get("payload", [])
        frame = pd.DataFrame(payload or [])
        if not frame.empty:
            for ticker, group in frame.groupby("ticker", sort=False):
                t = canonical_ticker(ticker)
                normalized = normalize_price_frame(group.rename(columns={"trade_date": "date"}), t)
                if len(normalized) >= int(min_rows):
                    out[t] = normalized.tail(int(limit)).reset_index(drop=True)
        if status:
            status(f"Checking Supabase OHLCV cache • {min(start + len(chunk), len(names))}/{len(names)} • hits {len(out)}")
    return out


def prepare_database_first_prices(
    universe: list[str],
    store: SupabaseStore | None,
    period: str = "1y",
    *,
    min_rows: int = 80,
    status: Callable[[str], None] | None = None,
    seed_path: Path | None = None,
) -> tuple[Callable[[str], pd.DataFrame], dict[str, object]]:
    """Build one in-memory price map before scoring.

    Order of precedence: dedicated Supabase cache -> verified bundled GitHub
    seed -> throttled Yahoo fetch. Supabase is read in bounded multi-ticker RPC
    calls when available; the previous one-query-per-ticker path remains only as
    a compatibility fallback for stores that do not expose the JSON bulk RPC.
    """
    names = list(dict.fromkeys(canonical_ticker(t) for t in universe if canonical_ticker(t)))
    frames: dict[str, pd.DataFrame] = {}
    cache_hits = 0
    db_read_errors = 0
    bulk_cache_used = False
    bulk_cache_transport = "NONE"

    if store is not None:
        try:
            bulk = _load_prices_bulk_json(
                store,
                names,
                min_rows=min_rows,
                limit=450,
                chunk_size=20,
                status=status,
            )
            for ticker, frame in (bulk or {}).items():
                if len(frame) >= min_rows:
                    frames[canonical_ticker(ticker)] = frame
            cache_hits = len(frames)
            bulk_cache_used = True
            bulk_cache_transport = "JSON_RPC"
        except Exception:
            db_read_errors += 1

    if store is not None and not bulk_cache_used and hasattr(store, "load_prices_bulk"):
        try:
            def bulk_progress(done: int, total: int, hits: int) -> None:
                if status:
                    status(f"Checking Supabase OHLCV cache fallback • {done}/{total} • hits {hits}")

            bulk = store.load_prices_bulk(
                names,
                min_rows=min_rows,
                limit=450,
                chunk_size=4,
                progress=bulk_progress,
            )
            for ticker, frame in (bulk or {}).items():
                if len(frame) >= min_rows:
                    frames[canonical_ticker(ticker)] = frame
            cache_hits = len(frames)
            bulk_cache_used = True
            bulk_cache_transport = "ROWSET_RPC_FALLBACK"
        except Exception:
            db_read_errors += 1

    if store is not None and not bulk_cache_used:
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

    missing_after_db = [t for t in names if t not in frames]
    seed_hits = 0
    seed_persisted = 0
    persist_errors = 0

    if missing_after_db and str(period).lower() in {"6mo", "1y"}:
        seed_map = load_bundled_price_seed(seed_path, min_rows=min_rows)
        for ticker in missing_after_db:
            frame = seed_map.get(ticker, pd.DataFrame())
            if len(frame) < min_rows:
                continue
            frames[ticker] = frame
            seed_hits += 1
            if store is not None:
                try:
                    seed_persisted += int(store.upsert_prices(ticker, frame, source="BUNDLED_GITHUB_SEED") > 0)
                except Exception:
                    persist_errors += 1
        if status and seed_hits:
            status(
                f"Bundled OHLCV seed • valid {seed_hits}/{len(missing_after_db)} • "
                f"persisted {seed_persisted}"
            )

    missing = [t for t in names if t not in frames]
    if status:
        status(
            f"OHLCV local sources ready • DB {cache_hits} • seed {seed_hits} • "
            f"fetching {len(missing)} missing"
        )

    fetched_valid = 0
    fetched_persisted = 0
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
                    fetched_persisted += int(store.upsert_prices(ticker, frame, source="YFINANCE_BATCH") > 0)
                except Exception:
                    persist_errors += 1
        if status:
            status(
                f"Yahoo fetch completed • valid {fetched_valid}/{len(missing)} • "
                f"persisted {fetched_persisted} • unavailable {len(missing) - fetched_valid}"
            )

    failures = [t for t in names if t not in frames]

    def load(ticker: str) -> pd.DataFrame:
        return frames.get(canonical_ticker(ticker), pd.DataFrame())

    stats: dict[str, object] = {
        "universe": len(names),
        "cache_hits": cache_hits,
        "cache_misses": len(missing_after_db),
        "bulk_cache_used": bulk_cache_used,
        "bulk_cache_transport": bulk_cache_transport,
        "seed_hits": seed_hits,
        "seed_persisted": seed_persisted,
        "fetched_valid": fetched_valid,
        "fetched_persisted": fetched_persisted,
        "persisted_tickers": seed_persisted + fetched_persisted,
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