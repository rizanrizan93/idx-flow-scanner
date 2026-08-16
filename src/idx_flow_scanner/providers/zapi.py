from __future__ import annotations

import os
from datetime import date, timedelta
from pathlib import Path
from typing import Iterable

import pandas as pd

from ..data import canonical_ticker

ZAPI_FOREIGN_FLOW_URL = "https://api.zpi.web.id/v1/finance:idx/foreign-flow"
ZAPI_SOURCE = "ZAPI_IDX_FOREIGN_FLOW"


class ZapiUnavailable(RuntimeError):
    pass


class ZapiQuotaExhausted(ZapiUnavailable):
    pass


def _root_path() -> Path:
    return Path(__file__).resolve().parents[3]


def _key(explicit: str | None = None) -> str | None:
    value = explicit or os.getenv("ZAPI_KEY")
    value = str(value or "").strip()
    return value or None


def _get_json(params: dict[str, object], api_key: str, timeout: float) -> dict:
    from curl_cffi import requests as curl_requests

    response = curl_requests.get(
        ZAPI_FOREIGN_FLOW_URL,
        params=params,
        headers={"Accept": "application/json", "x-api-key": api_key},
        impersonate="chrome",
        timeout=timeout,
    )
    if response.status_code == 401:
        raise ZapiUnavailable("Zapi API key invalid or missing")
    if response.status_code == 403:
        raise ZapiUnavailable("Zapi plan does not allow IDX foreign-flow endpoint")
    if response.status_code == 429:
        raise ZapiQuotaExhausted("Zapi rate/monthly quota exhausted")
    if response.status_code != 200:
        raise ZapiUnavailable(f"Zapi HTTP {response.status_code}")
    payload = response.json()
    if not isinstance(payload, dict):
        raise ZapiUnavailable("Zapi returned a non-object response")
    return payload


def normalize_zapi_foreign_payload(
    payload: dict,
    trade_date: date | str,
    universe: Iterable[str] | None = None,
) -> pd.DataFrame:
    """Normalize documented Zapi IDX foreign flow in share units.

    Zapi documents ``foreignBuyShares``, ``foreignSellShares`` and
    ``netForeignShares`` as LEMBAR SAHAM. This preserves the same dimensional
    contract used by the direct IDX Stock Summary provider.
    """
    rows = payload.get("data") if isinstance(payload, dict) else None
    if not isinstance(rows, list):
        return pd.DataFrame()
    allowed = None
    if universe is not None:
        allowed = {canonical_ticker(t) for t in universe if canonical_ticker(t)}
    response_date = pd.to_datetime(payload.get("date"), errors="coerce")
    fallback = pd.Timestamp(trade_date).normalize()
    day = response_date.normalize() if pd.notna(response_date) else fallback
    unit = str(payload.get("unit") or "shares").strip().lower()
    if unit not in {"share", "shares", "lembar", "lembar saham"}:
        raise ZapiUnavailable(f"Unexpected Zapi foreign-flow unit: {unit}")

    normalized: list[dict[str, object]] = []
    for item in rows:
        if not isinstance(item, dict):
            continue
        ticker = canonical_ticker(item.get("code"))
        if not ticker or (allowed is not None and ticker not in allowed):
            continue

        def num(key: str) -> float:
            value = pd.to_numeric(item.get(key), errors="coerce")
            return float(value) if pd.notna(value) else 0.0

        buy = num("foreignBuyShares")
        sell = num("foreignSellShares")
        raw_net = pd.to_numeric(item.get("netForeignShares"), errors="coerce")
        net = float(raw_net) if pd.notna(raw_net) else buy - sell
        normalized.append({
            "ticker": ticker,
            "trade_date": day,
            "foreign_buy": buy,
            "foreign_sell": sell,
            "foreign_net": net,
            "traded_value": num("value"),
            "volume": num("volume"),
            "frequency": None,
            "bid": None,
            "offer": None,
            "bid_volume": None,
            "offer_volume": None,
            "listed_shares": None,
            "tradable_shares": None,
            "source": ZAPI_SOURCE,
        })
    return pd.DataFrame(normalized)


def fetch_zapi_foreign_flow_day(
    universe: Iterable[str],
    trade_date: date | str,
    *,
    api_key: str | None = None,
    page_size: int = 200,
    timeout: float = 30.0,
) -> pd.DataFrame:
    """Fetch one market-wide Zapi IDX foreign-flow day with bounded pagination."""
    key = _key(api_key)
    if not key:
        return pd.DataFrame()
    names = list(dict.fromkeys(canonical_ticker(t) for t in universe if canonical_ticker(t)))
    if not names:
        return pd.DataFrame()
    size = max(1, min(int(page_size), 200))
    day = pd.Timestamp(trade_date).date().isoformat()
    parts: list[pd.DataFrame] = []
    start = 0
    total: int | None = None
    while total is None or start < total:
        payload = _get_json(
            {"date": day, "sort": "code", "length": size, "start": start},
            key,
            timeout,
        )
        frame = normalize_zapi_foreign_payload(payload, day, names)
        if not frame.empty:
            parts.append(frame)
        raw_total = pd.to_numeric(payload.get("total"), errors="coerce")
        total = int(raw_total) if pd.notna(raw_total) else start + len(payload.get("data") or [])
        returned = len(payload.get("data") or [])
        if returned <= 0 or total <= start + returned:
            break
        start += returned
    if not parts:
        return pd.DataFrame()
    out = pd.concat(parts, ignore_index=True)
    out["trade_date"] = pd.to_datetime(out["trade_date"], errors="coerce").dt.normalize()
    return out.drop_duplicates(["ticker", "trade_date", "source"], keep="last").sort_values(
        ["ticker", "trade_date"], kind="stable"
    ).reset_index(drop=True)


def fetch_zapi_foreign_flow_history(
    universe: Iterable[str],
    *,
    end_date: date | str,
    target_trading_days: int = 20,
    max_calendar_days: int = 45,
    api_key: str | None = None,
) -> pd.DataFrame:
    """Backfill documented share-unit foreign flow while respecting API quota."""
    key = _key(api_key)
    if not key:
        return pd.DataFrame()
    end = pd.Timestamp(end_date).date()
    parts: list[pd.DataFrame] = []
    valid_days = 0
    for offset in range(max(1, int(max_calendar_days))):
        day = end - timedelta(days=offset)
        if day.weekday() >= 5:
            continue
        frame = fetch_zapi_foreign_flow_day(universe, day, api_key=key)
        if frame.empty:
            continue
        parts.append(frame)
        valid_days += 1
        if valid_days >= int(target_trading_days):
            break
    if not parts:
        return pd.DataFrame()
    out = pd.concat(parts, ignore_index=True)
    return out.drop_duplicates(["ticker", "trade_date", "source"], keep="last").sort_values(
        ["ticker", "trade_date"], kind="stable"
    ).reset_index(drop=True)


def load_bundled_zapi_foreign_flows(
    universe: Iterable[str],
    path: Path | None = None,
    *,
    lookback_calendar_days: int = 120,
) -> pd.DataFrame:
    cache_path = path or (_root_path() / "data" / "cache" / "zapi_idx_foreign_60d.csv.gz")
    if not cache_path.exists():
        return pd.DataFrame()
    try:
        out = pd.read_csv(cache_path)
    except Exception:
        return pd.DataFrame()
    required = {"ticker", "trade_date", "foreign_buy", "foreign_sell", "foreign_net", "volume", "source"}
    if not required.issubset({str(c).strip().lower() for c in out.columns}):
        return pd.DataFrame()
    out.columns = [str(c).strip().lower() for c in out.columns]
    out["ticker"] = out["ticker"].map(canonical_ticker)
    out["trade_date"] = pd.to_datetime(out["trade_date"], errors="coerce").dt.normalize()
    names = {canonical_ticker(t) for t in universe if canonical_ticker(t)}
    cutoff = pd.Timestamp.today().normalize() - pd.Timedelta(days=int(lookback_calendar_days))
    return out[out["ticker"].isin(names) & out["trade_date"].ge(cutoff)].dropna(
        subset=["ticker", "trade_date"]
    ).sort_values(["ticker", "trade_date"], kind="stable").reset_index(drop=True)


def write_zapi_foreign_cache(frame: pd.DataFrame, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if frame is not None and not frame.empty:
        frame.to_csv(path, index=False, compression="gzip")
