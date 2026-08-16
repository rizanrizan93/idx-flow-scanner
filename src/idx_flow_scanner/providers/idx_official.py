from __future__ import annotations

import random
import time
from datetime import date, timedelta
from pathlib import Path
from typing import Iterable, Any

import numpy as np
import pandas as pd

from ..data import canonical_ticker

IDX_STOCK_SUMMARY_URL = "https://www.idx.co.id/primary/TradingSummary/GetStockSummary"
IDX_BROKER_SUMMARY_URL = "https://www.idx.co.id/primary/TradingSummary/GetBrokerSummary"
IDX_STOCK_REFERER = "https://www.idx.co.id/en/market-data/trading-summary/stock-summary/"
IDX_BROKER_REFERER = "https://www.idx.co.id/en/market-data/trading-summary/broker-summary/"


class IdxOfficialAccessBlocked(RuntimeError):
    """Raised when IDX's edge layer blocks server-side official-data access."""


def _idx_headers(referer: str) -> dict[str, str]:
    """Browser-compatible headers used by IDX public TradingSummary endpoints.

    These are ordinary request headers, not a Cloudflare challenge bypass. If IDX
    still serves a challenge page, the caller fails closed and uses persisted data.
    """
    return {
        "Accept": "application/json,text/plain,*/*",
        "Accept-Language": "en-US,en;q=0.9,id;q=0.8",
        "User-Agent": (
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
            "AppleWebKit/537.36 (KHTML, like Gecko) "
            "Chrome/120.0.0.0 Safari/537.36"
        ),
        "Referer": referer,
        "sec-ch-ua": '\"Not_A Brand\";v=\"8\", \"Chromium\";v=\"120\", \"Google Chrome\";v=\"120\"',
        "sec-ch-ua-mobile": "?0",
        "sec-ch-ua-platform": '\"Windows\"',
    }


def normalize_idx_stock_summary_payload(payload: dict, trade_date: date | str) -> pd.DataFrame:
    """Normalize official IDX stock-summary data.

    ``ForeignBuy``/``ForeignSell`` are share counts, not IDR values. They stay in
    share units here so foreign intensity can be compared with daily traded volume
    in the same unit. Official foreign flow is never broker-identity evidence.
    """
    rows = payload.get("data") if isinstance(payload, dict) else None
    if not isinstance(rows, list):
        return pd.DataFrame()
    normalized: list[dict[str, object]] = []
    fallback_date = pd.Timestamp(trade_date).date().isoformat()
    for item in rows:
        if not isinstance(item, dict):
            continue
        ticker = canonical_ticker(item.get("StockCode"))
        if not ticker:
            continue
        raw_date = item.get("Date") or fallback_date
        parsed_date = pd.to_datetime(raw_date, errors="coerce")
        day = parsed_date.date().isoformat() if pd.notna(parsed_date) else fallback_date

        def num(key: str) -> float:
            value = pd.to_numeric(item.get(key), errors="coerce")
            return float(value) if pd.notna(value) else 0.0

        foreign_buy = num("ForeignBuy")
        foreign_sell = num("ForeignSell")
        normalized.append({
            "ticker": ticker,
            "trade_date": day,
            "foreign_buy": foreign_buy,
            "foreign_sell": foreign_sell,
            "foreign_net": foreign_buy - foreign_sell,
            "traded_value": num("Value"),
            "volume": num("Volume"),
            "frequency": num("Frequency"),
            "bid": num("Bid"),
            "offer": num("Offer"),
            "bid_volume": num("BidVolume"),
            "offer_volume": num("OfferVolume"),
            "listed_shares": num("ListedShares"),
            "tradable_shares": num("TradebleShares"),
            "source": "IDX_OFFICIAL_STOCK_SUMMARY",
        })
    return pd.DataFrame(normalized)


def normalize_idx_broker_summary_payload(payload: dict, trade_date: date | str) -> pd.DataFrame:
    """Normalize IDX market-wide broker totals.

    This endpoint has no stock code and no buy/sell split. It is useful for source
    health and market-level broker activity only; it must never populate
    ``flow_broker_flows`` or satisfy ``BROKER_DIRECT``.
    """
    rows = payload.get("data") if isinstance(payload, dict) else None
    if not isinstance(rows, list):
        return pd.DataFrame()
    fallback_date = pd.Timestamp(trade_date).date().isoformat()
    out: list[dict[str, object]] = []
    for item in rows:
        if not isinstance(item, dict):
            continue
        code = str(item.get("IDFirm") or "").strip().upper()
        if not code:
            continue
        parsed_date = pd.to_datetime(item.get("Date") or fallback_date, errors="coerce")
        day = parsed_date.date().isoformat() if pd.notna(parsed_date) else fallback_date

        def num(key: str) -> float:
            value = pd.to_numeric(item.get(key), errors="coerce")
            return float(value) if pd.notna(value) else 0.0

        out.append({
            "trade_date": day,
            "broker_code": code,
            "broker_name": str(item.get("FirmName") or "").strip(),
            "volume": num("Volume"),
            "value": num("Value"),
            "frequency": num("Frequency"),
            "source": "IDX_OFFICIAL_BROKER_SUMMARY_MARKET",
        })
    return pd.DataFrame(out)


def _fetch_idx_summary(
    url: str,
    referer: str,
    trade_date: date | str,
    *,
    retries: int = 3,
    timeout: float = 25.0,
) -> dict:
    from curl_cffi import requests as curl_requests

    day = pd.Timestamp(trade_date).date()
    params = {"start": 0, "length": 9999, "date": day.strftime("%Y%m%d")}
    for attempt in range(max(1, int(retries))):
        try:
            response = curl_requests.get(
                url,
                params=params,
                headers=_idx_headers(referer),
                impersonate="chrome",
                timeout=timeout,
            )
            if response.status_code == 200:
                payload = response.json()
                return payload if isinstance(payload, dict) else {}
            if response.status_code in {401, 403}:
                body = str(response.text or "")[:300].lower()
                challenge = "cloudflare" in body or "just a moment" in body
                suffix = " (Cloudflare challenge)" if challenge else ""
                raise IdxOfficialAccessBlocked(
                    f"IDX official TradingSummary access blocked with HTTP {response.status_code}{suffix}"
                )
            if response.status_code == 429:
                time.sleep((2.5 * (2 ** attempt)) + random.uniform(0.2, 0.8))
            else:
                time.sleep(0.8 + random.uniform(0.1, 0.4))
        except IdxOfficialAccessBlocked:
            raise
        except Exception:
            time.sleep((1.5 * (2 ** attempt)) + random.uniform(0.1, 0.5))
    return {}


def fetch_idx_stock_summary(trade_date: date | str, *, retries: int = 3, timeout: float = 25.0) -> pd.DataFrame:
    payload = _fetch_idx_summary(
        IDX_STOCK_SUMMARY_URL,
        IDX_STOCK_REFERER,
        trade_date,
        retries=retries,
        timeout=timeout,
    )
    return normalize_idx_stock_summary_payload(payload, trade_date)


def fetch_idx_market_broker_summary(trade_date: date | str, *, retries: int = 3, timeout: float = 25.0) -> pd.DataFrame:
    payload = _fetch_idx_summary(
        IDX_BROKER_SUMMARY_URL,
        IDX_BROKER_REFERER,
        trade_date,
        retries=retries,
        timeout=timeout,
    )
    return normalize_idx_broker_summary_payload(payload, trade_date)


def fetch_idx_official_flow_history(
    universe: Iterable[str],
    *,
    end_date: date | str,
    target_trading_days: int = 20,
    max_calendar_days: int = 38,
    request_delay_seconds: float = 0.45,
    raise_on_block: bool = False,
) -> pd.DataFrame:
    """Fetch N official stock-summary trading days in market-wide calls.

    If the cloud environment is challenged, stop immediately. Missing official
    evidence stays missing/guarded and is never synthesized from OHLCV. Schedulers
    can request ``raise_on_block`` so their audit metadata records the blockage.
    """
    names = set(canonical_ticker(t) for t in universe if canonical_ticker(t))
    if not names:
        return pd.DataFrame()
    end = pd.Timestamp(end_date).date()
    collected: list[pd.DataFrame] = []
    valid_days = 0
    for offset in range(max(1, int(max_calendar_days))):
        day = end - timedelta(days=offset)
        if day.weekday() >= 5:
            continue
        try:
            frame = fetch_idx_stock_summary(day)
        except IdxOfficialAccessBlocked:
            if raise_on_block:
                raise
            break
        if frame.empty:
            continue
        frame = frame[frame["ticker"].isin(names)].copy()
        if frame.empty:
            continue
        collected.append(frame)
        valid_days += 1
        if valid_days >= int(target_trading_days):
            break
        if request_delay_seconds > 0:
            time.sleep(float(request_delay_seconds) + random.uniform(0.0, 0.2))
    if not collected:
        return pd.DataFrame()
    out = pd.concat(collected, ignore_index=True)
    out["trade_date"] = pd.to_datetime(out["trade_date"], errors="coerce").dt.normalize()
    return out.dropna(subset=["trade_date", "ticker"]).drop_duplicates(
        ["ticker", "trade_date", "source"], keep="last"
    ).sort_values(["ticker", "trade_date"]).reset_index(drop=True)


def _root_path() -> Path:
    return Path(__file__).resolve().parents[3]


def load_bundled_idx_official_flows(
    universe: Iterable[str],
    path: Path | None = None,
    *,
    lookback_calendar_days: int = 90,
) -> pd.DataFrame:
    """Load the GitHub Actions-built official IDX foreign-flow transport cache."""
    cache_path = path or (_root_path() / "data" / "cache" / "idx_official_flow_60d.csv.gz")
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
    names = set(canonical_ticker(t) for t in universe if canonical_ticker(t))
    out["ticker"] = out["ticker"].map(canonical_ticker)
    out["trade_date"] = pd.to_datetime(out["trade_date"], errors="coerce").dt.normalize()
    cutoff = pd.Timestamp.today().normalize() - pd.Timedelta(days=int(lookback_calendar_days))
    out = out.dropna(subset=["ticker", "trade_date"])
    out = out[out["ticker"].isin(names) & out["trade_date"].ge(cutoff)]
    return out.drop_duplicates(["ticker", "trade_date", "source"], keep="last").sort_values(["ticker", "trade_date"]).reset_index(drop=True)


def merge_official_flow_frames(*frames: pd.DataFrame) -> pd.DataFrame:
    valid = [f.copy() for f in frames if f is not None and not f.empty]
    if not valid:
        return pd.DataFrame()
    out = pd.concat(valid, ignore_index=True)
    out["ticker"] = out["ticker"].map(canonical_ticker)
    out["trade_date"] = pd.to_datetime(out["trade_date"], errors="coerce").dt.normalize()
    return out.dropna(subset=["ticker", "trade_date"]).drop_duplicates(
        ["ticker", "trade_date", "source"], keep="last"
    ).sort_values(["ticker", "trade_date"]).reset_index(drop=True)


def load_cached_idx_official_flows(store: Any, universe: Iterable[str], lookback_calendar_days: int = 50) -> pd.DataFrame:
    names = list(dict.fromkeys(canonical_ticker(t) for t in universe if canonical_ticker(t)))
    if not names or store is None:
        return pd.DataFrame()
    since = (date.today() - timedelta(days=int(lookback_calendar_days))).isoformat()
    rows: list[dict[str, object]] = []
    for i in range(0, len(names), 40):
        chunk = names[i:i + 40]
        resp = (store.client.table("flow_official_stock_flows")
                .select("ticker,trade_date,foreign_buy,foreign_sell,foreign_net,traded_value,volume,frequency,bid,offer,bid_volume,offer_volume,listed_shares,tradable_shares,source")
                .in_("ticker", chunk).gte("trade_date", since).order("trade_date").execute())
        rows.extend(resp.data or [])
    if not rows:
        return pd.DataFrame()
    out = pd.DataFrame(rows)
    out["trade_date"] = pd.to_datetime(out["trade_date"], errors="coerce").dt.normalize()
    return out.dropna(subset=["ticker", "trade_date"]).sort_values(["ticker", "trade_date"]).reset_index(drop=True)


def upsert_idx_official_flows(store: Any, frame: pd.DataFrame) -> int:
    """Persist only direct IDX stock-summary rows in the official table.

    Vendor-derived foreign flow must never be written into
    ``flow_official_stock_flows``. The app may pass a merged transport frame, so
    this helper enforces provenance at the storage boundary and fails closed for
    every non-IDX source.
    """
    if store is None or frame is None or frame.empty:
        return 0
    clean = frame.copy()
    if "source" not in clean.columns:
        return 0
    clean = clean[clean["source"].astype(str).eq("IDX_OFFICIAL_STOCK_SUMMARY")].copy()
    if clean.empty:
        return 0
    cols = [
        "ticker", "trade_date", "foreign_buy", "foreign_sell", "foreign_net",
        "traded_value", "volume", "frequency", "bid", "offer", "bid_volume",
        "offer_volume", "listed_shares", "tradable_shares", "source",
    ]
    for c in cols:
        if c not in clean.columns:
            clean[c] = None
    clean["ticker"] = clean["ticker"].map(canonical_ticker)
    clean["trade_date"] = pd.to_datetime(clean["trade_date"], errors="coerce").dt.date.astype("string")
    clean = clean.replace({np.nan: None})
    rows = clean[cols].to_dict("records")
    for i in range(0, len(rows), 500):
        store.client.table("flow_official_stock_flows").upsert(
            rows[i:i + 500], on_conflict="ticker,trade_date,source"
        ).execute()
    return len(rows)
