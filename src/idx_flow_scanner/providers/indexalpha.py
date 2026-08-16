from __future__ import annotations

import os
from pathlib import Path
from typing import Iterable

import numpy as np
import pandas as pd

from ..data import canonical_ticker, normalize_broker_summary

INDEXALPHA_BASE_URL = "https://api.indexalpha.id"
INDEXALPHA_BROKER_BATCH_URL = f"{INDEXALPHA_BASE_URL}/stocks/broker-summary/batch"
INDEXALPHA_BROKER_SINGLE_URL = f"{INDEXALPHA_BASE_URL}/stocks/broker-summary"


class IndexAlphaUnavailable(RuntimeError):
    pass


class IndexAlphaQuotaExhausted(IndexAlphaUnavailable):
    pass


def _root_path() -> Path:
    return Path(__file__).resolve().parents[3]


def _token(explicit: str | None = None) -> str | None:
    value = explicit or os.getenv("INDEXALPHA_KEY") or os.getenv("INDEXALPHA_TOKEN")
    value = str(value or "").strip()
    return value or None


def _broker_rows_for_ticker(ticker: str, trade_date: str, items: object, *, market: str) -> list[dict[str, object]]:
    if not isinstance(items, list):
        return []
    rows: list[dict[str, object]] = []
    for item in items:
        if not isinstance(item, dict):
            continue
        code = str(item.get("code") or "").strip().upper()
        if not code:
            continue

        def num(key: str) -> float:
            value = pd.to_numeric(item.get(key), errors="coerce")
            return float(value) if pd.notna(value) else 0.0

        rows.append({
            "ticker": canonical_ticker(ticker),
            "trade_date": trade_date,
            "broker_code": code,
            "buy_value": num("buy_value"),
            "sell_value": num("sell_value"),
            "buy_volume": num("buy_volume"),
            "sell_volume": num("sell_volume"),
            "buy_avg": num("buy_avg"),
            "sell_avg": num("sell_avg"),
            "market_type": "REGULAR" if str(market).upper() == "RG" else str(market).upper(),
            "source": "INDEXALPHA_API",
            "source_verified": True,
            "source_url": INDEXALPHA_BROKER_BATCH_URL,
            "provenance_state": "VERIFIED_VENDOR_API",
        })
    return rows


def fetch_indexalpha_broker_batch(
    tickers: Iterable[str],
    trade_date: str | pd.Timestamp,
    *,
    api_token: str | None = None,
    investor: str = "all",
    market: str = "RG",
    timeout: float = 30.0,
) -> pd.DataFrame:
    """Fetch stock-level broker buy/sell evidence from the authenticated vendor API.

    Index Alpha counts batch quota per ticker, not per HTTP request, so callers
    must explicitly bound the ticker list before calling this function.
    """
    token = _token(api_token)
    if not token:
        return pd.DataFrame()
    names = list(dict.fromkeys(canonical_ticker(t) for t in tickers if canonical_ticker(t)))[:50]
    if not names:
        return pd.DataFrame()
    day = pd.Timestamp(trade_date).date().isoformat()

    from curl_cffi import requests as curl_requests

    response = curl_requests.post(
        INDEXALPHA_BROKER_BATCH_URL,
        headers={
            "Accept": "application/json",
            "Content-Type": "application/json",
            "Authorization": f"Bearer {token}",
        },
        json={"tickers": names, "from": day, "to": day, "investor": investor, "market": market},
        impersonate="chrome",
        timeout=timeout,
    )
    if response.status_code == 403:
        remaining = response.headers.get("X-Monthly-Remaining")
        if str(remaining) == "0" or "limit" in str(response.text or "").lower():
            raise IndexAlphaQuotaExhausted("Index Alpha quota exhausted")
        raise IndexAlphaUnavailable("Index Alpha access denied")
    if response.status_code == 429:
        raise IndexAlphaUnavailable("Index Alpha rate limit reached")
    if response.status_code != 200:
        raise IndexAlphaUnavailable(f"Index Alpha HTTP {response.status_code}")

    payload = response.json()
    if not isinstance(payload, dict) or not payload.get("success"):
        raise IndexAlphaUnavailable(str((payload or {}).get("error") or "Index Alpha invalid response"))
    data = payload.get("data")
    if not isinstance(data, dict):
        return pd.DataFrame()
    rows: list[dict[str, object]] = []
    for ticker in names:
        rows.extend(_broker_rows_for_ticker(ticker, day, data.get(ticker, []), market=market))
    return normalize_broker_summary(pd.DataFrame(rows)) if rows else pd.DataFrame()


def load_bundled_indexalpha_broker_flows(
    universe: Iterable[str],
    path: Path | None = None,
    *,
    lookback_calendar_days: int = 120,
) -> pd.DataFrame:
    """Load an audited broker-evidence transport cache produced by GitHub Actions."""
    cache_path = path or (_root_path() / "data" / "cache" / "indexalpha_broker_60d.csv.gz")
    if not cache_path.exists():
        return pd.DataFrame()
    try:
        raw = pd.read_csv(cache_path)
    except Exception:
        return pd.DataFrame()
    try:
        out = normalize_broker_summary(raw)
    except Exception:
        return pd.DataFrame()
    names = set(canonical_ticker(t) for t in universe if canonical_ticker(t))
    cutoff = pd.Timestamp.today().normalize() - pd.Timedelta(days=int(lookback_calendar_days))
    out = out[out["ticker"].isin(names) & out["trade_date"].ge(cutoff)].copy()
    if "source_verified" not in out.columns:
        out["source_verified"] = False
    if "source_url" not in out.columns:
        out["source_url"] = None
    if "provenance_state" not in out.columns:
        out["provenance_state"] = None
    return out.sort_values(["ticker", "trade_date", "broker_code"], kind="stable").reset_index(drop=True)


def merge_broker_frames(*frames: pd.DataFrame) -> pd.DataFrame:
    valid = [f.copy() for f in frames if f is not None and not f.empty]
    if not valid:
        return pd.DataFrame()
    out = normalize_broker_summary(pd.concat(valid, ignore_index=True))
    keys = ["ticker", "trade_date", "broker_code", "market_type", "source"]
    return out.drop_duplicates(keys, keep="last").sort_values(
        ["ticker", "trade_date", "broker_code"], kind="stable"
    ).reset_index(drop=True)


def choose_broker_refresh_tickers(
    universe: Iterable[str],
    existing: pd.DataFrame,
    *,
    budget_units: int,
) -> list[str]:
    """Round-robin missing/stalest tickers so limited quotas are never wasted."""
    names = list(dict.fromkeys(canonical_ticker(t) for t in universe if canonical_ticker(t)))
    budget = max(0, int(budget_units))
    if budget == 0:
        return []
    if existing is None or existing.empty or "ticker" not in existing.columns:
        return names[:budget]
    work = existing.copy()
    work["ticker"] = work["ticker"].map(canonical_ticker)
    work["trade_date"] = pd.to_datetime(work["trade_date"], errors="coerce")
    freshest = work.groupby("ticker", observed=True)["trade_date"].max().to_dict()
    floor = pd.Timestamp("1900-01-01")
    names.sort(key=lambda ticker: (freshest.get(ticker, floor), ticker))
    return names[:budget]


def write_broker_cache(frame: pd.DataFrame, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    clean = frame.copy() if frame is not None else pd.DataFrame()
    if clean.empty:
        return
    clean = clean.replace({np.nan: None})
    clean.to_csv(path, index=False, compression="gzip")
