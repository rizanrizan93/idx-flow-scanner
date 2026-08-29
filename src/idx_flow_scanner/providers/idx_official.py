from __future__ import annotations

import random
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
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
IDX_OFFICIAL_BROKER_SOURCE = "IDX_OFFICIAL_BROKER_SUMMARY"


class IdxOfficialAccessBlocked(RuntimeError):
    """Raised when IDX's edge layer blocks server-side official-data access."""


def _idx_headers(referer: str) -> dict[str, str]:
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


def _num(item: dict[str, object], *keys: str) -> float:
    for key in keys:
        value = pd.to_numeric(item.get(key), errors="coerce")
        if pd.notna(value):
            return float(value)
    return 0.0


def normalize_idx_broker_stock_summary_payload(
    payload: dict,
    ticker: str,
    trade_date: date | str,
) -> pd.DataFrame:
    """Normalize stock-level broker summary from IDX.

    Field aliases are intentionally broad because IDX's public TradingSummary
    payload has changed naming across frontend revisions. The row must still carry
    the requested ticker; mismatched stock rows are discarded fail-closed.
    """
    rows = payload.get("data") if isinstance(payload, dict) else None
    if isinstance(rows, dict):
        rows = rows.get("data") or rows.get("results") or rows.get("aaData")
    if not isinstance(rows, list):
        return pd.DataFrame()
    symbol = canonical_ticker(ticker)
    fallback_day = pd.Timestamp(trade_date).date().isoformat()
    normalized: list[dict[str, object]] = []
    for item in rows:
        if not isinstance(item, dict):
            continue
        row_symbol = canonical_ticker(
            item.get("StockCode") or item.get("stockCode") or item.get("Symbol") or item.get("symbol") or symbol
        )
        if row_symbol != symbol:
            continue
        code = str(
            item.get("IDFirm")
            or item.get("BrokerCode")
            or item.get("brokerCode")
            or item.get("Code")
            or item.get("code")
            or ""
        ).strip().upper()
        if not code:
            continue
        broker_name = str(item.get("FirmName") or item.get("BrokerName") or item.get("brokerName") or "").strip()
        day_raw = item.get("Date") or item.get("date") or fallback_day
        parsed_date = pd.to_datetime(day_raw, errors="coerce")
        day = parsed_date.date().isoformat() if pd.notna(parsed_date) else fallback_day
        buy_value = _num(item, "BuyValue", "buyValue", "Buy", "buy")
        sell_value = _num(item, "SellValue", "sellValue", "Sell", "sell")
        buy_volume = _num(item, "BuyVolume", "buyVolume", "BuyQty", "buyQty")
        sell_volume = _num(item, "SellVolume", "sellVolume", "SellQty", "sellQty")
        buy_avg = _num(item, "BuyAvg", "buyAvg", "BuyAverage", "buyAverage")
        sell_avg = _num(item, "SellAvg", "sellAvg", "SellAverage", "sellAverage")
        if buy_value == 0 and sell_value == 0 and buy_volume == 0 and sell_volume == 0:
            continue
        normalized.append({
            "ticker": symbol,
            "trade_date": day,
            "broker_code": code,
            "broker_name": broker_name,
            "buy_value": buy_value,
            "sell_value": sell_value,
            "buy_volume": buy_volume,
            "sell_volume": sell_volume,
            "buy_avg": buy_avg,
            "sell_avg": sell_avg,
            "market_type": "RG",
            "source": IDX_OFFICIAL_BROKER_SOURCE,
            "source_verified": True,
            "source_url": IDX_BROKER_SUMMARY_URL,
            "provenance_state": "VERIFIED_IDX_PUBLIC_TRADING_SUMMARY_STOCK_LEVEL",
        })
    if not normalized:
        return pd.DataFrame()
    return pd.DataFrame(normalized)


def normalize_idx_broker_summary_payload(payload: dict, trade_date: date | str) -> pd.DataFrame:
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
        out.append({
            "trade_date": day,
            "broker_code": code,
            "broker_name": str(item.get("FirmName") or "").strip(),
            "volume": _num(item, "Volume"),
            "value": _num(item, "Value"),
            "frequency": _num(item, "Frequency"),
            "source": "IDX_OFFICIAL_BROKER_SUMMARY_MARKET",
        })
    return pd.DataFrame(out)


def _fetch_idx_summary(url: str, referer: str, trade_date: date | str, *, extra_params: dict[str, object] | None = None, retries: int = 3, timeout: float = 25.0) -> dict:
    from curl_cffi import requests as curl_requests
    day = pd.Timestamp(trade_date).date()
    params = {"start": 0, "length": 9999, "date": day.strftime("%Y%m%d")}
    if extra_params:
        params.update(extra_params)
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
                raise IdxOfficialAccessBlocked(f"IDX official TradingSummary access blocked with HTTP {response.status_code}{suffix}")
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
    payload = _fetch_idx_summary(IDX_STOCK_SUMMARY_URL, IDX_STOCK_REFERER, trade_date, retries=retries, timeout=timeout)
    return normalize_idx_stock_summary_payload(payload, trade_date)


def fetch_idx_market_broker_summary(
    trade_date: date | str,
    *,
    retries: int = 2,
    timeout: float = 25.0,
) -> pd.DataFrame:
    """Fetch market-wide IDX broker summary for source-health telemetry only.

    This endpoint has no stock dimension and must never be promoted to
    stock-level BROKER_DIRECT evidence.
    """
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
    max_calendar_days: int = 45,
    request_delay_seconds: float = 1.0,
    retries: int = 2,
    timeout: float = 25.0,
    raise_on_block: bool = False,
) -> pd.DataFrame:
    """Collect date-major official foreign-flow history from IDX StockSummary.

    One StockSummary request covers the market for a trading day, so this function
    never issues one request per ticker.  Access blocks terminate immediately.
    Empty/holiday responses do not count toward the trading-day target.
    """
    names = {canonical_ticker(t) for t in universe if canonical_ticker(t)}
    if not names:
        return pd.DataFrame()

    cursor = pd.Timestamp(end_date).date()
    collected_days = 0
    calendar_scanned = 0
    parts: list[pd.DataFrame] = []

    while (
        collected_days < max(1, int(target_trading_days))
        and calendar_scanned < max(1, int(max_calendar_days))
    ):
        day = cursor
        cursor -= timedelta(days=1)
        calendar_scanned += 1
        if day.weekday() >= 5:
            continue
        try:
            frame = fetch_idx_stock_summary(day, retries=retries, timeout=timeout)
        except IdxOfficialAccessBlocked:
            if raise_on_block:
                raise
            break
        if frame is None or frame.empty:
            if request_delay_seconds > 0:
                time.sleep(float(request_delay_seconds))
            continue

        frame = frame.copy()
        frame["ticker"] = frame["ticker"].map(canonical_ticker)
        frame = frame.loc[frame["ticker"].isin(names)].copy()
        if not frame.empty:
            parts.append(frame)
            collected_days += 1
        if request_delay_seconds > 0 and collected_days < int(target_trading_days):
            time.sleep(float(request_delay_seconds))

    if not parts:
        return pd.DataFrame()
    out = pd.concat(parts, ignore_index=True)
    out["trade_date"] = pd.to_datetime(out["trade_date"], errors="coerce").dt.normalize()
    out = out.dropna(subset=["ticker", "trade_date"])
    return (
        out.drop_duplicates(["ticker", "trade_date", "source"], keep="last")
        .sort_values(["ticker", "trade_date"], kind="stable")
        .reset_index(drop=True)
    )


def fetch_idx_broker_stock_summary(ticker: str, trade_date: date | str, *, retries: int = 2, timeout: float = 25.0) -> pd.DataFrame:
    symbol = canonical_ticker(ticker)
    if not symbol:
        return pd.DataFrame()
    payload = _fetch_idx_summary(
        IDX_BROKER_SUMMARY_URL,
        IDX_BROKER_REFERER,
        trade_date,
        extra_params={"StockCode": symbol, "stockCode": symbol, "symbol": symbol},
        retries=retries,
        timeout=timeout,
    )
    return normalize_idx_broker_stock_summary_payload(payload, symbol, trade_date)


def fetch_idx_universe_broker_history(
    universe: Iterable[str],
    *,
    end_date: date | str,
    existing: pd.DataFrame | None = None,
    target_trading_days: int = 20,
    max_calendar_days: int = 45,
    budget_requests: int = 400,
    workers: int = 12,
) -> tuple[pd.DataFrame, dict[str, object]]:
    """Incrementally build universe-wide stock-level IDX broker evidence.

    The daily scheduler is date-major. Once a ticker/date exists in the cache it
    is never requested again. If IDX blocks cloud egress, the entire batch stops
    immediately and callers keep the persisted cache. No proxy data is synthesized.
    """
    names = list(dict.fromkeys(canonical_ticker(t) for t in universe if canonical_ticker(t)))
    existing = existing.copy() if existing is not None and not existing.empty else pd.DataFrame()
    if not names or budget_requests <= 0:
        return existing, {"status": "NO_BUDGET", "requests_attempted": 0, "rows": len(existing), "tickers": int(existing['ticker'].nunique()) if not existing.empty and 'ticker' in existing else 0}
    present: set[tuple[str, str]] = set()
    if not existing.empty and {"ticker", "trade_date"}.issubset(existing.columns):
        work = existing[["ticker", "trade_date"]].copy()
        work["ticker"] = work["ticker"].map(canonical_ticker)
        work["trade_date"] = pd.to_datetime(work["trade_date"], errors="coerce").dt.date.astype("string")
        present = set((str(t), str(d)) for t, d in work.dropna().itertuples(index=False, name=None))

    dates: list[str] = []
    cursor = pd.Timestamp(end_date).date()
    while len(dates) < max(1, int(target_trading_days)) and len(dates) < max(1, int(max_calendar_days)):
        if cursor.weekday() < 5:
            dates.append(cursor.isoformat())
        cursor -= timedelta(days=1)

    jobs: list[tuple[str, str]] = []
    for day in dates:
        for ticker in names:
            if (ticker, day) not in present:
                jobs.append((ticker, day))
                if len(jobs) >= int(budget_requests):
                    break
        if len(jobs) >= int(budget_requests):
            break
    attempted = 0
    parts: list[pd.DataFrame] = []
    status = "UNCHANGED"
    stop = False
    with ThreadPoolExecutor(max_workers=max(1, int(workers))) as executor:
        futures = {executor.submit(fetch_idx_broker_stock_summary, ticker, day): (ticker, day) for ticker, day in jobs}
        for future in as_completed(futures):
            attempted += 1
            try:
                frame = future.result()
                if frame is not None and not frame.empty:
                    parts.append(frame)
                    status = "UPDATED"
                elif status == "UNCHANGED":
                    status = "NO_DATA"
            except IdxOfficialAccessBlocked as exc:
                status = f"BLOCKED: {exc}"
                stop = True
                break
            except Exception as exc:
                status = f"ERROR: {type(exc).__name__}: {exc}"
                stop = True
                break
        if stop:
            for future in futures:
                future.cancel()

    fresh = pd.concat(parts, ignore_index=True) if parts else pd.DataFrame()
    if not existing.empty and not fresh.empty:
        merged = pd.concat([existing, fresh], ignore_index=True)
    else:
        merged = fresh if not fresh.empty else existing
    if merged.empty:
        stats = {"status": status, "requests_attempted": attempted, "rows": 0, "tickers": 0, "days": 0}
        return merged, stats
    merged["trade_date"] = pd.to_datetime(merged["trade_date"], errors="coerce").dt.normalize()
    merged = merged.dropna(subset=["ticker", "trade_date"]).drop_duplicates(
        ["ticker", "trade_date", "broker_code", "source"], keep="last"
    ).sort_values(["ticker", "trade_date", "broker_code"], kind="stable").reset_index(drop=True)
    stats = {
        "status": status,
        "requests_attempted": attempted,
        "rows": int(len(merged)),
        "tickers": int(merged["ticker"].nunique()),
        "days": int(merged["trade_date"].nunique()),
        "freshest": str(pd.to_datetime(merged["trade_date"]).max().date()),
    }
    return merged, stats


def _root_path() -> Path:
    return Path(__file__).resolve().parents[3]


def load_bundled_idx_official_flows(universe: Iterable[str], path: Path | None = None, *, lookback_calendar_days: int = 90) -> pd.DataFrame:
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


def load_bundled_idx_official_broker_flows(universe: Iterable[str], path: Path | None = None, *, lookback_calendar_days: int = 180) -> pd.DataFrame:
    cache_path = path or (_root_path() / "data" / "cache" / "idx_official_broker_60d.csv.gz")
    if not cache_path.exists():
        return pd.DataFrame()
    try:
        out = pd.read_csv(cache_path)
    except Exception:
        return pd.DataFrame()
    required = {"ticker", "trade_date", "broker_code", "buy_value", "sell_value", "source"}
    if not required.issubset({str(c).strip().lower() for c in out.columns}):
        return pd.DataFrame()
    out.columns = [str(c).strip().lower() for c in out.columns]
    names = {canonical_ticker(t) for t in universe if canonical_ticker(t)}
    out["ticker"] = out["ticker"].map(canonical_ticker)
    out["trade_date"] = pd.to_datetime(out["trade_date"], errors="coerce").dt.normalize()
    cutoff = pd.Timestamp.today().normalize() - pd.Timedelta(days=int(lookback_calendar_days))
    out = out.dropna(subset=["ticker", "trade_date"])
    out = out[out["ticker"].isin(names) & out["trade_date"].ge(cutoff)]
    if "source_verified" not in out.columns:
        out["source_verified"] = True
    return out.sort_values(["ticker", "trade_date", "broker_code"], kind="stable").reset_index(drop=True)


def merge_official_flow_frames(*frames: pd.DataFrame) -> pd.DataFrame:
    valid = [f.copy() for f in frames if f is not None and not f.empty]
    if not valid:
        return pd.DataFrame()
    out = pd.concat(valid, ignore_index=True)
    out["ticker"] = out["ticker"].map(canonical_ticker)
    out["trade_date"] = pd.to_datetime(out["trade_date"], errors="coerce").dt.normalize()
    return out.dropna(subset=["ticker", "trade_date"]).drop_duplicates(["ticker", "trade_date", "source"], keep="last").sort_values(["ticker", "trade_date"]).reset_index(drop=True)


def load_cached_idx_official_flows(store: Any, universe: Iterable[str], lookback_calendar_days: int = 50) -> pd.DataFrame:
    names = list(dict.fromkeys(canonical_ticker(t) for t in universe if canonical_ticker(t)))
    if not names or store is None:
        return pd.DataFrame()
    since = (date.today() - timedelta(days=int(lookback_calendar_days))).isoformat()
    rows: list[dict[str, object]] = []
    for i in range(0, len(names), 40):
        chunk = names[i:i + 40]
        resp = (store.client.table("flow_official_stock_flows").select("ticker,trade_date,foreign_buy,foreign_sell,foreign_net,traded_value,volume,frequency,bid,offer,bid_volume,offer_volume,listed_shares,tradable_shares,source").in_("ticker", chunk).gte("trade_date", since).order("trade_date").execute())
        rows.extend(resp.data or [])
    if not rows:
        return pd.DataFrame()
    out = pd.DataFrame(rows)
    out["trade_date"] = pd.to_datetime(out["trade_date"], errors="coerce").dt.normalize()
    return out.dropna(subset=["ticker", "trade_date"]).sort_values(["ticker", "trade_date"]).reset_index(drop=True)


def upsert_idx_official_flows(store: Any, frame: pd.DataFrame) -> int:
    if store is None or frame is None or frame.empty:
        return 0
    clean = frame.copy()
    if "source" not in clean.columns:
        return 0
    clean = clean[clean["source"].astype(str).eq("IDX_OFFICIAL_STOCK_SUMMARY")].copy()
    if clean.empty:
        return 0
    cols = ["ticker", "trade_date", "foreign_buy", "foreign_sell", "foreign_net", "traded_value", "volume", "frequency", "bid", "offer", "bid_volume", "offer_volume", "listed_shares", "tradable_shares", "source"]
    for c in cols:
        if c not in clean.columns:
            clean[c] = None
    clean["ticker"] = clean["ticker"].map(canonical_ticker)
    clean["trade_date"] = pd.to_datetime(clean["trade_date"], errors="coerce").dt.date.astype("string")
    clean = clean.replace({np.nan: None})
    rows = clean[cols].to_dict("records")
    for i in range(0, len(rows), 500):
        store.client.table("flow_official_stock_flows").upsert(rows[i:i + 500], on_conflict="ticker,trade_date,source").execute()
    return len(rows)
