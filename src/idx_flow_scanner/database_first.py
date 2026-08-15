from __future__ import annotations

from dataclasses import dataclass
from typing import Callable

import pandas as pd

from .data import fetch_yfinance_prices
from .storage import SupabaseStore


@dataclass(frozen=True)
class DataLoadState:
    ticker: str
    price_source: str
    price_rows: int
    broker_rows: int
    broker_days: int


def database_first_price_loader(store: SupabaseStore | None, period: str = "1y") -> Callable[[str], pd.DataFrame]:
    def load(ticker: str) -> pd.DataFrame:
        if store is not None:
            try:
                cached=store.load_prices(ticker,min_rows=80)
                if len(cached)>=80:
                    return cached
            except Exception:
                pass
        fresh=fetch_yfinance_prices(ticker,period=period)
        if store is not None and not fresh.empty:
            try: store.upsert_prices(ticker,fresh)
            except Exception: pass
        return fresh
    return load


def broker_database_coverage(universe: list[str], broker: pd.DataFrame, lookback_days: int = 20) -> pd.DataFrame:
    rows=[]
    if broker is None or broker.empty:
        return pd.DataFrame({"ticker":universe,"broker_days":0,"broker_ready":False})
    for ticker in universe:
        b=broker[broker["ticker"]==ticker]
        days=int(b["trade_date"].nunique()) if not b.empty else 0
        rows.append({"ticker":ticker,"broker_days":days,"broker_ready":days>=lookback_days})
    return pd.DataFrame(rows)
