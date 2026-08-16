from __future__ import annotations

import os
from datetime import date, timedelta
from pathlib import Path
from typing import Iterable

import pandas as pd

from ..data import canonical_ticker

ZAPI_FOREIGN_FLOW_URL = "https://api.zpi.web.id/v1/finance:idx/foreign-flow"
ZAPI_STOCK_SUMMARY_URL = "https://api.zpi.web.id/v1/finance:idx/stock-summary"
ZAPI_FOREIGN_SOURCE = "ZAPI_IDX_FOREIGN_FLOW"
ZAPI_STOCK_SOURCE = "ZAPI_IDX_STOCK_SUMMARY"


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


def _unwrap_payload(payload: dict) -> dict:
    """Unwrap Zapi's live project envelope into the documented endpoint payload.

    The public endpoint reference shows the inner endpoint object directly, while
    authenticated live calls currently wrap that object as {data, project,
    timestamp}. Only unwrap when the outer ``data`` is itself an object; endpoint
    payloads whose ``data`` is already a row list are left untouched.
    """
    nested = payload.get("data")
    if isinstance(nested, dict) and any(
        key in nested for key in ("dataset", "provider", "recordsTotal", "total", "items")
    ):
        return nested
    return payload


def _get_json(url: str, params: dict[str, object], api_key: str, timeout: float) -> dict:
    from curl_cffi import requests as curl_requests

    response = curl_requests.get(
        url,
        params=params,
        headers={"Accept": "application/json", "x-api-key": api_key},
        impersonate="chrome",
        timeout=timeout,
    )
    if response.status_code == 401:
        raise ZapiUnavailable("Zapi API key invalid or missing")
    if response.status_code == 403:
        raise ZapiUnavailable("Zapi plan does not allow requested IDX endpoint")
    if response.status_code == 429:
        raise ZapiQuotaExhausted("Zapi rate/monthly quota exhausted")
    if response.status_code != 200:
        raise ZapiUnavailable(f"Zapi HTTP {response.status_code}")
    payload = response.json()
    if not isinstance(payload, dict):
        raise ZapiUnavailable("Zapi returned a non-object response")
    return _unwrap_payload(payload)


def _allowed_tickers(universe: Iterable[str] | None) -> set[str] | None:
    if universe is None:
        return None
    return {canonical_ticker(t) for t in universe if canonical_ticker(t)}


def normalize_zapi_foreign_payload(
    payload: dict,
    trade_date: date | str,
    universe: Iterable[str] | None = None,
) -> pd.DataFrame:
    """Normalize Zapi's documented /foreign-flow response in share units."""
    payload = _unwrap_payload(payload) if isinstance(payload, dict) else {}
    rows = payload.get("data")
    if not isinstance(rows, list):
        return pd.DataFrame()
    allowed = _allowed_tickers(universe)
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
            "source": ZAPI_FOREIGN_SOURCE,
        })
    return pd.DataFrame(normalized)


def normalize_zapi_stock_summary_payload(
    payload: dict,
    trade_date: date | str,
    universe: Iterable[str] | None = None,
) -> pd.DataFrame:
    """Normalize stock-summary ForeignBuy/ForeignSell as share-count fallback."""
    payload = _unwrap_payload(payload) if isinstance(payload, dict) else {}
    rows = payload.get("data")
    if not isinstance(rows, list):
        return pd.DataFrame()
    allowed = _allowed_tickers(universe)
    fallback = pd.Timestamp(trade_date).normalize()
    normalized: list[dict[str, object]] = []
    for item in rows:
        if not isinstance(item, dict):
            continue
        ticker = canonical_ticker(item.get("StockCode"))
        if not ticker or (allowed is not None and ticker not in allowed):
            continue
        item_date = pd.to_datetime(item.get("Date"), errors="coerce")
        day = item_date.normalize() if pd.notna(item_date) else fallback

        def num(key: str) -> float:
            value = pd.to_numeric(item.get(key), errors="coerce")
            return float(value) if pd.notna(value) else 0.0

        buy = num("ForeignBuy")
        sell = num("ForeignSell")
        normalized.append({
            "ticker": ticker,
            "trade_date": day,
            "foreign_buy": buy,
            "foreign_sell": sell,
            "foreign_net": buy - sell,
            "traded_value": num("Value"),
            "volume": num("Volume"),
            "frequency": num("Frequency"),
            "bid": num("Bid"),
            "offer": num("Offer"),
            "bid_volume": num("BidVolume"),
            "offer_volume": num("OfferVolume"),
            "listed_shares": num("ListedShares"),
            "tradable_shares": num("TradebleShares"),
            "source": ZAPI_STOCK_SOURCE,
        })
    return pd.DataFrame(normalized)


def _paginate(
    url: str,
    params: dict[str, object],
    key: str,
    timeout: float,
    *,
    page_size: int,
    normalizer,
    trade_date: str,
    universe: list[str],
) -> pd.DataFrame:
    parts: list[pd.DataFrame] = []
    start = 0
    total: int | None = None
    while total is None or start < total:
        page_params = {**params, "length": page_size, "start": start}
        payload = _get_json(url, page_params, key, timeout)
        raw_rows = payload.get("data") or []
        frame = normalizer(payload, trade_date, universe)
        if not frame.empty:
            parts.append(frame)
        candidates = [payload.get("total"), payload.get("recordsFiltered"), payload.get("recordsTotal")]
        numeric_totals = [pd.to_numeric(value, errors="coerce") for value in candidates]
        raw_total = next((value for value in numeric_totals if pd.notna(value)), None)
        returned = len(raw_rows) if isinstance(raw_rows, list) else 0
        total = int(raw_total) if raw_total is not None else start + returned
        if returned <= 0 or total <= start + returned:
            break
        start += returned
    if not parts:
        return pd.DataFrame()
    out = pd.concat(parts, ignore_index=True)
    out["trade_date"] = pd.to_datetime(out["trade_date"], errors="coerce").dt.normalize()
    return out.drop_duplicates(["ticker", "trade_date"], keep="first").sort_values(
        ["ticker", "trade_date"], kind="stable"
    ).reset_index(drop=True)


def fetch_zapi_stock_summary_day(
    universe: Iterable[str],
    trade_date: date | str,
    *,
    api_key: str | None = None,
    page_size: int = 1000,
    timeout: float = 30.0,
) -> pd.DataFrame:
    key = _key(api_key)
    if not key:
        return pd.DataFrame()
    names = list(dict.fromkeys(canonical_ticker(t) for t in universe if canonical_ticker(t)))
    if not names:
        return pd.DataFrame()
    size = max(1, min(int(page_size), 1000))
    day = pd.Timestamp(trade_date).date().isoformat()
    return _paginate(
        ZAPI_STOCK_SUMMARY_URL,
        {"date": day},
        key,
        timeout,
        page_size=size,
        normalizer=normalize_zapi_stock_summary_payload,
        trade_date=day,
        universe=names,
    )


def fetch_zapi_foreign_flow_day(
    universe: Iterable[str],
    trade_date: date | str,
    *,
    api_key: str | None = None,
    page_size: int = 200,
    timeout: float = 30.0,
) -> pd.DataFrame:
    """Fetch one Zapi IDX foreign-flow day, with stock-summary fallback."""
    key = _key(api_key)
    if not key:
        return pd.DataFrame()
    names = list(dict.fromkeys(canonical_ticker(t) for t in universe if canonical_ticker(t)))
    if not names:
        return pd.DataFrame()
    size = max(1, min(int(page_size), 200))
    day = pd.Timestamp(trade_date).date().isoformat()
    direct = _paginate(
        ZAPI_FOREIGN_FLOW_URL,
        {"date": day, "sort": "code"},
        key,
        timeout,
        page_size=size,
        normalizer=normalize_zapi_foreign_payload,
        trade_date=day,
        universe=names,
    )
    if not direct.empty:
        return direct
    return fetch_zapi_stock_summary_day(names, day, api_key=key, timeout=timeout)


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
    return out.drop_duplicates(["ticker", "trade_date"], keep="first").sort_values(
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
