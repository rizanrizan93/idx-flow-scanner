from __future__ import annotations

import random
import time
from datetime import date, timedelta
from typing import Iterable, Any

import numpy as np
import pandas as pd

from ..data import canonical_ticker

IDX_STOCK_SUMMARY_URL = "https://www.idx.co.id/primary/TradingSummary/GetStockSummary"


def normalize_idx_stock_summary_payload(payload: dict, trade_date: date | str) -> pd.DataFrame:
    """Normalize official IDX stock-summary data.

    ForeignBuy/ForeignSell is direct official foreign-flow evidence, but it is not
    broker-identity evidence and must never be promoted to BROKER_DIRECT.
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
        foreign_buy = num("ForeignBuy"); foreign_sell = num("ForeignSell")
        normalized.append({
            "ticker":ticker,"trade_date":day,"foreign_buy":foreign_buy,"foreign_sell":foreign_sell,
            "foreign_net":foreign_buy-foreign_sell,"traded_value":num("Value"),"volume":num("Volume"),
            "frequency":num("Frequency"),"bid":num("Bid"),"offer":num("Offer"),
            "bid_volume":num("BidVolume"),"offer_volume":num("OfferVolume"),
            "listed_shares":num("ListedShares"),"tradable_shares":num("TradebleShares"),
            "source":"IDX_OFFICIAL_STOCK_SUMMARY",
        })
    return pd.DataFrame(normalized)


def fetch_idx_stock_summary(trade_date: date | str, *, retries: int = 3, timeout: float = 25.0) -> pd.DataFrame:
    """Fetch one market-wide official IDX stock-summary day."""
    from curl_cffi import requests as curl_requests
    day = pd.Timestamp(trade_date).date()
    headers = {
        "Accept":"application/json,text/plain,*/*","Accept-Language":"en-US,en;q=0.9,id;q=0.8",
        "Referer":"https://www.idx.co.id/en/market-data/trading-summary/stock-summary",
    }
    for attempt in range(max(1, int(retries))):
        try:
            response = curl_requests.get(
                IDX_STOCK_SUMMARY_URL, params={"date":day.strftime("%Y%m%d")}, headers=headers,
                impersonate="chrome", timeout=timeout,
            )
            if response.status_code == 200:
                frame = normalize_idx_stock_summary_payload(response.json(), day)
                if not frame.empty:
                    return frame
            if response.status_code in {401,403,429}:
                time.sleep((2.5*(2**attempt))+random.uniform(0.2,0.8))
            else:
                time.sleep(0.8+random.uniform(0.1,0.4))
        except Exception:
            time.sleep((1.5*(2**attempt))+random.uniform(0.1,0.5))
    return pd.DataFrame()


def fetch_idx_official_flow_history(
    universe: Iterable[str], *, end_date: date | str, target_trading_days: int = 20,
    max_calendar_days: int = 38, request_delay_seconds: float = 0.45,
) -> pd.DataFrame:
    """Fetch N trading days in market-wide calls, not one call per stock."""
    names = set(canonical_ticker(t) for t in universe if canonical_ticker(t))
    if not names:
        return pd.DataFrame()
    end = pd.Timestamp(end_date).date(); collected=[]; valid_days=0
    for offset in range(max(1,int(max_calendar_days))):
        day = end - timedelta(days=offset)
        if day.weekday() >= 5:
            continue
        frame = fetch_idx_stock_summary(day)
        if frame.empty:
            continue
        frame = frame[frame["ticker"].isin(names)].copy()
        if frame.empty:
            continue
        collected.append(frame); valid_days += 1
        if valid_days >= int(target_trading_days):
            break
        if request_delay_seconds > 0:
            time.sleep(float(request_delay_seconds)+random.uniform(0.0,0.2))
    if not collected:
        return pd.DataFrame()
    out = pd.concat(collected, ignore_index=True)
    out["trade_date"] = pd.to_datetime(out["trade_date"], errors="coerce").dt.normalize()
    return out.dropna(subset=["trade_date","ticker"]).drop_duplicates(
        ["ticker","trade_date","source"], keep="last"
    ).sort_values(["ticker","trade_date"]).reset_index(drop=True)


def load_cached_idx_official_flows(store: Any, universe: Iterable[str], lookback_calendar_days: int = 50) -> pd.DataFrame:
    names = list(dict.fromkeys(canonical_ticker(t) for t in universe if canonical_ticker(t)))
    if not names or store is None:
        return pd.DataFrame()
    since = (date.today()-timedelta(days=int(lookback_calendar_days))).isoformat(); rows=[]
    for i in range(0,len(names),40):
        chunk=names[i:i+40]
        resp=(store.client.table("flow_official_stock_flows")
              .select("ticker,trade_date,foreign_buy,foreign_sell,foreign_net,traded_value,volume,frequency,bid,offer,bid_volume,offer_volume,listed_shares,tradable_shares,source")
              .in_("ticker",chunk).gte("trade_date",since).order("trade_date").execute())
        rows.extend(resp.data or [])
    if not rows:
        return pd.DataFrame()
    out=pd.DataFrame(rows); out["trade_date"]=pd.to_datetime(out["trade_date"],errors="coerce").dt.normalize()
    return out.dropna(subset=["ticker","trade_date"]).sort_values(["ticker","trade_date"]).reset_index(drop=True)


def upsert_idx_official_flows(store: Any, frame: pd.DataFrame) -> int:
    if store is None or frame is None or frame.empty:
        return 0
    cols=["ticker","trade_date","foreign_buy","foreign_sell","foreign_net","traded_value","volume","frequency","bid","offer","bid_volume","offer_volume","listed_shares","tradable_shares","source"]
    clean=frame.copy()
    for c in cols:
        if c not in clean.columns: clean[c]=None
    clean["ticker"]=clean["ticker"].map(canonical_ticker); clean["trade_date"]=pd.to_datetime(clean["trade_date"],errors="coerce").dt.date.astype("string")
    clean=clean.replace({np.nan:None}); rows=clean[cols].to_dict("records")
    for i in range(0,len(rows),500):
        store.client.table("flow_official_stock_flows").upsert(rows[i:i+500],on_conflict="ticker,trade_date,source").execute()
    return len(rows)
