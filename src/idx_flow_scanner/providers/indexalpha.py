from __future__ import annotations

import json
import os
from pathlib import Path
from typing import Iterable

import pandas as pd

from ..data import canonical_ticker, normalize_broker_summary

INDEX_ALPHA_BASE_URL = "https://api.indexalpha.id"
INDEX_ALPHA_BROKER_URL = f"{INDEX_ALPHA_BASE_URL}/stocks/broker-summary"
INDEX_ALPHA_SOURCE = "INDEX_ALPHA_BROKER_SUMMARY"
DEFAULT_TARGETS_PATH = Path(__file__).resolve().parents[3] / "data" / "config" / "indexalpha_targets.json"


class IndexAlphaUnavailable(RuntimeError):
    pass


class IndexAlphaQuotaExhausted(IndexAlphaUnavailable):
    pass


def _root_path() -> Path:
    return Path(__file__).resolve().parents[3]


def _key(explicit: str | None = None) -> str | None:
    value = explicit or os.getenv("INDEX_ALPHA_KEY")
    value = str(value or "").strip()
    return value or None


def normalize_indexalpha_broker_payload(
    payload: dict,
    ticker: str,
    trade_date: str | pd.Timestamp,
    *,
    investor: str = "all",
    market: str = "RG",
) -> pd.DataFrame:
    """Normalize one exact-day Index Alpha stock-level broker summary.

    The provider endpoint accepts a date range but returns broker rows aggregated
    over that range without a row-level date. To preserve daily evidence integrity,
    the production fetcher deliberately calls it with ``from == to`` only. We never
    split a multi-day aggregate into fabricated daily rows.
    """
    if not isinstance(payload, dict) or payload.get("success") is not True:
        return pd.DataFrame()
    rows = payload.get("data")
    if not isinstance(rows, list):
        return pd.DataFrame()
    symbol = canonical_ticker(ticker)
    day = pd.Timestamp(trade_date).date().isoformat()
    normalized: list[dict[str, object]] = []
    for item in rows:
        if not isinstance(item, dict):
            continue
        code = str(item.get("code") or "").strip().upper()
        if not code:
            continue

        def num(name: str) -> float:
            value = pd.to_numeric(item.get(name), errors="coerce")
            return float(value) if pd.notna(value) else 0.0

        buy_value = max(num("buy_value"), 0.0)
        sell_value = max(num("sell_value"), 0.0)
        buy_volume = max(num("buy_volume"), 0.0)
        sell_volume = max(num("sell_volume"), 0.0)
        buy_avg = max(num("buy_avg"), 0.0)
        sell_avg = max(num("sell_avg"), 0.0)
        # Empty broker rows carry no usable evidence and are ignored.
        if buy_value <= 0 and sell_value <= 0 and buy_volume <= 0 and sell_volume <= 0:
            continue
        normalized.append({
            "ticker": symbol,
            "trade_date": day,
            "broker_code": code,
            "buy_value": buy_value,
            "sell_value": sell_value,
            "buy_volume": buy_volume,
            "sell_volume": sell_volume,
            "buy_avg": buy_avg,
            "sell_avg": sell_avg,
            "market_type": str(market).upper(),
            "source": INDEX_ALPHA_SOURCE,
            "source_verified": True,
            "source_url": INDEX_ALPHA_BROKER_URL,
            "provenance_state": (
                f"VERIFIED_VENDOR_API_EXACT_DAY_{str(investor).upper()}_{str(market).upper()}_"
                "VOLUME_UNIT_PROVIDER_NATIVE"
            ),
        })
    if not normalized:
        return pd.DataFrame()
    return normalize_broker_summary(pd.DataFrame(normalized))


def fetch_indexalpha_broker_summary(
    ticker: str,
    trade_date: str | pd.Timestamp,
    *,
    api_key: str | None = None,
    investor: str = "all",
    market: str = "RG",
    timeout: float = 30.0,
) -> pd.DataFrame:
    """Fetch exactly one ticker-day to preserve true daily broker history."""
    key = _key(api_key)
    if not key:
        return pd.DataFrame()
    symbol = canonical_ticker(ticker)
    if not symbol:
        return pd.DataFrame()
    day = pd.Timestamp(trade_date).date().isoformat()
    investor_key = str(investor).strip().lower()
    market_key = str(market).strip().upper()
    if investor_key not in {"all", "f", "d", "or"}:
        raise ValueError("Index Alpha investor must be all/f/d/or")
    if market_key not in {"RG", "NG", "ALL"}:
        raise ValueError("Index Alpha market must be RG/NG/ALL")

    from curl_cffi import requests as curl_requests

    response = curl_requests.get(
        INDEX_ALPHA_BROKER_URL,
        params={
            "ticker": symbol,
            "from": day,
            "to": day,
            "investor": investor_key,
            "market": market_key,
        },
        headers={"Accept": "application/json", "Authorization": f"Bearer {key}"},
        impersonate="chrome",
        timeout=timeout,
    )
    if response.status_code == 401:
        raise IndexAlphaUnavailable("Index Alpha API key invalid or missing")
    if response.status_code in {402, 403}:
        raise IndexAlphaUnavailable("Index Alpha plan does not allow broker summary")
    if response.status_code == 429:
        raise IndexAlphaQuotaExhausted("Index Alpha daily/rate quota exhausted")
    if response.status_code == 204:
        return pd.DataFrame()
    if response.status_code != 200:
        raise IndexAlphaUnavailable(f"Index Alpha HTTP {response.status_code}")
    payload = response.json()
    if not isinstance(payload, dict):
        raise IndexAlphaUnavailable("Index Alpha returned a non-object response")
    if payload.get("success") is not True:
        raise IndexAlphaUnavailable(str(payload.get("error") or "Index Alpha invalid response"))
    return normalize_indexalpha_broker_payload(
        payload, symbol, day, investor=investor_key, market=market_key
    )


def load_indexalpha_targets(path: Path | None = None) -> list[str]:
    target_path = path or DEFAULT_TARGETS_PATH
    if not target_path.exists():
        return []
    try:
        payload = json.loads(target_path.read_text(encoding="utf-8"))
    except Exception:
        return []
    raw = payload.get("tickers") if isinstance(payload, dict) else None
    if not isinstance(raw, list):
        return []
    return list(dict.fromkeys(canonical_ticker(v) for v in raw if canonical_ticker(v)))


def load_bundled_indexalpha_broker_flows(
    universe: Iterable[str],
    path: Path | None = None,
    *,
    lookback_calendar_days: int = 180,
) -> pd.DataFrame:
    cache_path = path or (_root_path() / "data" / "cache" / "indexalpha_broker_60d.csv.gz")
    if not cache_path.exists():
        return pd.DataFrame()
    try:
        out = normalize_broker_summary(pd.read_csv(cache_path))
    except Exception:
        return pd.DataFrame()
    names = {canonical_ticker(t) for t in universe if canonical_ticker(t)}
    cutoff = pd.Timestamp.today().normalize() - pd.Timedelta(days=int(lookback_calendar_days))
    out = out[
        out["ticker"].isin(names)
        & out["trade_date"].ge(cutoff)
        & out["source"].eq(INDEX_ALPHA_SOURCE)
    ].copy()
    for col, default in (("source_verified", False), ("source_url", None), ("provenance_state", None)):
        if col not in out.columns:
            out[col] = default
    return out.sort_values(["ticker", "trade_date", "broker_code"], kind="stable").reset_index(drop=True)


def merge_indexalpha_broker_frames(*frames: pd.DataFrame) -> pd.DataFrame:
    valid = [f.copy() for f in frames if f is not None and not f.empty]
    if not valid:
        return pd.DataFrame()
    out = normalize_broker_summary(pd.concat(valid, ignore_index=True))
    keys = ["ticker", "trade_date", "broker_code", "market_type", "source"]
    return out.drop_duplicates(keys, keep="last").sort_values(
        ["ticker", "trade_date", "broker_code", "source"], kind="stable"
    ).reset_index(drop=True)


def choose_indexalpha_daily_jobs(
    targets: Iterable[str],
    existing: pd.DataFrame,
    trade_dates: Iterable[str | pd.Timestamp],
    *,
    budget_requests: int = 5,
) -> list[tuple[str, str]]:
    """Use scarce free requests to build real daily history for a pinned cohort.

    Date-major round-robin keeps all five active targets aligned on the newest
    session. On weekends/holidays, once the newest session is already cached the
    same budget naturally backfills older missing sessions. Nothing is synthesized.
    """
    names = list(dict.fromkeys(canonical_ticker(t) for t in targets if canonical_ticker(t)))
    dates = sorted({pd.Timestamp(d).date().isoformat() for d in trade_dates}, reverse=True)
    budget = max(0, int(budget_requests))
    if not names or not dates or budget <= 0:
        return []
    present: set[tuple[str, str]] = set()
    if existing is not None and not existing.empty:
        work = existing[["ticker", "trade_date"]].copy()
        work["ticker"] = work["ticker"].map(canonical_ticker)
        work["trade_date"] = pd.to_datetime(work["trade_date"], errors="coerce").dt.date.astype("string")
        present = set((str(t), str(d)) for t, d in work.dropna().itertuples(index=False, name=None))
    jobs: list[tuple[str, str]] = []
    for day in dates:
        for ticker in names:
            if (ticker, day) in present:
                continue
            jobs.append((ticker, day))
            if len(jobs) >= budget:
                return jobs
    return jobs


def write_indexalpha_broker_cache(frame: pd.DataFrame, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if frame is not None and not frame.empty:
        frame.to_csv(path, index=False, compression="gzip")
