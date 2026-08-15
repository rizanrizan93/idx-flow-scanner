from __future__ import annotations

from dataclasses import dataclass
from datetime import date
from io import BytesIO
from typing import Iterable

import numpy as np
import pandas as pd


BROKER_REQUIRED = {
    "ticker", "trade_date", "broker_code", "buy_value", "sell_value",
    "buy_volume", "sell_volume", "buy_avg", "sell_avg",
}


def canonical_ticker(value: object) -> str:
    text = str(value or "").strip().upper()
    if text.endswith(".JK"):
        text = text[:-3]
    return text


def normalize_broker_summary(frame: pd.DataFrame) -> pd.DataFrame:
    if frame is None or frame.empty:
        return pd.DataFrame(columns=sorted(BROKER_REQUIRED | {"market_type", "source"}))
    out = frame.copy()
    out.columns = [str(c).strip().lower() for c in out.columns]
    missing = BROKER_REQUIRED - set(out.columns)
    if missing:
        raise ValueError(f"Broker summary missing required columns: {sorted(missing)}")
    out["ticker"] = out["ticker"].map(canonical_ticker)
    out["broker_code"] = out["broker_code"].astype(str).str.strip().str.upper()
    out["trade_date"] = pd.to_datetime(out["trade_date"], errors="coerce").dt.normalize()
    numeric = ["buy_value", "sell_value", "buy_volume", "sell_volume", "buy_avg", "sell_avg"]
    for col in numeric:
        out[col] = pd.to_numeric(out[col], errors="coerce")
    out = out.dropna(subset=["ticker", "trade_date", "broker_code"])
    out = out[out["ticker"].ne("") & out["broker_code"].ne("")]
    out["net_value"] = out["buy_value"].fillna(0) - out["sell_value"].fillna(0)
    out["net_volume"] = out["buy_volume"].fillna(0) - out["sell_volume"].fillna(0)
    out["gross_value"] = out["buy_value"].fillna(0) + out["sell_value"].fillna(0)
    out["market_type"] = out.get("market_type", "REGULAR").fillna("REGULAR") if "market_type" in out else "REGULAR"
    out["source"] = out.get("source", "USER_IMPORT").fillna("USER_IMPORT") if "source" in out else "USER_IMPORT"
    return out.sort_values(["ticker", "trade_date", "broker_code"], kind="stable").reset_index(drop=True)


def normalize_price_frame(frame: pd.DataFrame, ticker: str | None = None) -> pd.DataFrame:
    if frame is None or frame.empty:
        return pd.DataFrame(columns=["date", "open", "high", "low", "close", "volume"])
    out = frame.copy()
    if isinstance(out.columns, pd.MultiIndex):
        out.columns = [c[0] if isinstance(c, tuple) else c for c in out.columns]
    out = out.reset_index()
    out.columns = [str(c).strip().lower().replace(" ", "_") for c in out.columns]
    date_col = next((c for c in ("date", "datetime", "index") if c in out.columns), None)
    if date_col is None:
        raise ValueError("Price frame requires a date/datetime/index column")
    rename = {"adj_close": "close"}
    out = out.rename(columns=rename)
    for required in ("open", "high", "low", "close", "volume"):
        if required not in out.columns:
            if required == "volume":
                out[required] = np.nan
            else:
                raise ValueError(f"Price frame missing {required}")
    out["date"] = pd.to_datetime(out[date_col], errors="coerce").dt.normalize()
    for c in ("open", "high", "low", "close", "volume"):
        out[c] = pd.to_numeric(out[c], errors="coerce")
    out = out.dropna(subset=["date", "close"]).drop_duplicates("date", keep="last")
    if ticker:
        out["ticker"] = canonical_ticker(ticker)
    return out[[c for c in ["ticker", "date", "open", "high", "low", "close", "volume"] if c in out.columns]].sort_values("date").reset_index(drop=True)


def fetch_yfinance_prices(ticker: str, period: str = "1y") -> pd.DataFrame:
    import yfinance as yf

    symbol = canonical_ticker(ticker)
    raw = yf.download(
        f"{symbol}.JK",
        period=period,
        interval="1d",
        auto_adjust=False,
        progress=False,
        threads=False,
        timeout=15,
    )
    return normalize_price_frame(raw, symbol)


def parse_universe(frame: pd.DataFrame) -> list[str]:
    if frame is None or frame.empty:
        return []
    cols = {str(c).strip().lower(): c for c in frame.columns}
    key = cols.get("ticker") or next(iter(frame.columns), None)
    if key is None:
        return []
    return list(dict.fromkeys(t for t in frame[key].map(canonical_ticker) if t))
