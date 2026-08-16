from __future__ import annotations

import random
import time
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
    date_col = next((c for c in ("date", "datetime", "index", "timestamp") if c in out.columns), None)
    if date_col is None:
        raise ValueError("Price frame requires a date/datetime/index column")
    out = out.rename(columns={"adj_close": "close"})
    for required in ("open", "high", "low", "close", "volume"):
        if required not in out.columns:
            if required == "volume":
                out[required] = np.nan
            else:
                raise ValueError(f"Price frame missing {required}")
    out["date"] = pd.to_datetime(out[date_col], errors="coerce", utc=True).dt.tz_convert(None).dt.normalize()
    for c in ("open", "high", "low", "close", "volume"):
        out[c] = pd.to_numeric(out[c], errors="coerce")
    out = out.dropna(subset=["date", "close"]).drop_duplicates("date", keep="last")
    if ticker:
        out["ticker"] = canonical_ticker(ticker)
    cols = [c for c in ["ticker", "date", "open", "high", "low", "close", "volume"] if c in out.columns]
    return out[cols].sort_values("date").reset_index(drop=True)


def _extract_yfinance_symbol(raw: pd.DataFrame, yahoo_symbol: str, ticker: str) -> pd.DataFrame:
    if raw is None or raw.empty:
        return pd.DataFrame()
    frame = raw
    if isinstance(raw.columns, pd.MultiIndex):
        level0 = [str(v).upper() for v in raw.columns.get_level_values(0)]
        level1 = [str(v).upper() for v in raw.columns.get_level_values(1)]
        symbol = yahoo_symbol.upper()
        if symbol in level0:
            frame = raw.xs(yahoo_symbol, axis=1, level=0, drop_level=True)
        elif symbol in level1:
            frame = raw.xs(yahoo_symbol, axis=1, level=1, drop_level=True)
        else:
            return pd.DataFrame()
    try:
        return normalize_price_frame(frame, ticker)
    except Exception:
        return pd.DataFrame()


def _period_to_range(period: str) -> str:
    value = str(period or "1y").strip().lower()
    return value if value in {"1mo", "3mo", "6mo", "1y", "2y", "5y", "10y", "max"} else "1y"


def parse_yahoo_chart_payload(payload: dict, ticker: str) -> pd.DataFrame:
    """Convert Yahoo chart JSON into our normalized price contract."""
    try:
        result = payload["chart"]["result"][0]
        timestamps = result.get("timestamp") or []
        quote = (result.get("indicators") or {}).get("quote", [{}])[0] or {}
    except (KeyError, IndexError, TypeError):
        return pd.DataFrame()
    if not timestamps:
        return pd.DataFrame()
    n = len(timestamps)
    frame = pd.DataFrame({
        "timestamp": pd.to_datetime(timestamps, unit="s", utc=True),
        "open": list(quote.get("open") or [None] * n)[:n],
        "high": list(quote.get("high") or [None] * n)[:n],
        "low": list(quote.get("low") or [None] * n)[:n],
        "close": list(quote.get("close") or [None] * n)[:n],
        "volume": list(quote.get("volume") or [None] * n)[:n],
    })
    return normalize_price_frame(frame, ticker)


def fetch_yahoo_chart_price(
    ticker: str,
    period: str = "1y",
    *,
    retries: int = 2,
    timeout: float = 20.0,
) -> pd.DataFrame:
    """Second Yahoo retrieval path used only for symbols missed by yfinance batching."""
    from curl_cffi import requests as curl_requests

    symbol = canonical_ticker(ticker)
    yahoo_symbol = f"{symbol}.JK"
    hosts = ("query2.finance.yahoo.com", "query1.finance.yahoo.com")
    range_value = _period_to_range(period)
    for attempt in range(max(1, int(retries))):
        host = hosts[attempt % len(hosts)]
        url = f"https://{host}/v8/finance/chart/{yahoo_symbol}"
        try:
            response = curl_requests.get(
                url,
                params={"range": range_value, "interval": "1d", "events": "div,splits", "includeAdjustedClose": "true"},
                impersonate="chrome",
                timeout=timeout,
                headers={"Accept": "application/json,text/plain,*/*", "Accept-Language": "en-US,en;q=0.9"},
            )
            if response.status_code == 200:
                frame = parse_yahoo_chart_payload(response.json(), symbol)
                if not frame.empty:
                    return frame
            if response.status_code in {401, 403, 429}:
                time.sleep((3.0 * (2 ** attempt)) + random.uniform(0.2, 0.8))
            else:
                time.sleep(1.0 + random.uniform(0.1, 0.4))
        except Exception:
            time.sleep((2.0 * (2 ** attempt)) + random.uniform(0.1, 0.5))
    return pd.DataFrame()


def fetch_yfinance_prices_batch(
    tickers: Iterable[str],
    period: str = "1y",
    *,
    chunk_size: int = 40,
    retries: int = 2,
    inter_chunk_delay_seconds: float = 2.0,
    retry_backoff_seconds: float = 8.0,
    fallback_limit: int | None = None,
) -> dict[str, pd.DataFrame]:
    """Fetch OHLCV with bounded request pressure plus a chart-endpoint fallback."""
    import yfinance as yf

    names = list(dict.fromkeys(canonical_ticker(t) for t in tickers if canonical_ticker(t)))
    results: dict[str, pd.DataFrame] = {}
    pending = names[:]
    chunk_size = max(1, int(chunk_size))
    retries = max(1, int(retries))

    for attempt in range(retries):
        if not pending:
            break
        attempt_names = pending[:]
        for start in range(0, len(attempt_names), chunk_size):
            chunk = attempt_names[start:start + chunk_size]
            yahoo_symbols = [f"{t}.JK" for t in chunk]
            try:
                raw = yf.download(
                    yahoo_symbols,
                    period=period,
                    interval="1d",
                    auto_adjust=False,
                    progress=False,
                    group_by="ticker",
                    threads=2 if len(chunk) > 1 else False,
                    timeout=30,
                )
            except Exception:
                raw = pd.DataFrame()

            for ticker, yahoo_symbol in zip(chunk, yahoo_symbols):
                frame = _extract_yfinance_symbol(raw, yahoo_symbol, ticker)
                if not frame.empty:
                    results[ticker] = frame

            if inter_chunk_delay_seconds > 0 and start + chunk_size < len(attempt_names):
                time.sleep(float(inter_chunk_delay_seconds) + random.uniform(0.0, 0.5))

        pending = [t for t in names if t not in results]
        if pending and attempt + 1 < retries:
            time.sleep(float(retry_backoff_seconds) * (2 ** attempt) + random.uniform(0.5, 1.5))

    pending = [t for t in names if t not in results]
    if fallback_limit is not None:
        pending = pending[:max(0, int(fallback_limit))]
    for index, ticker in enumerate(pending, 1):
        frame = fetch_yahoo_chart_price(ticker, period=period, retries=2)
        if not frame.empty:
            results[ticker] = frame
        if index < len(pending):
            time.sleep(0.35 + random.uniform(0.0, 0.35))

    return results


def fetch_yfinance_prices(ticker: str, period: str = "1y") -> pd.DataFrame:
    symbol = canonical_ticker(ticker)
    result = fetch_yfinance_prices_batch(
        [symbol],
        period=period,
        chunk_size=1,
        retries=1,
        inter_chunk_delay_seconds=0.0,
        retry_backoff_seconds=2.0,
    )
    return result.get(symbol, pd.DataFrame())


def parse_universe(frame: pd.DataFrame) -> list[str]:
    if frame is None or frame.empty:
        return []
    cols = {str(c).strip().lower(): c for c in frame.columns}
    key = cols.get("ticker") or next(iter(frame.columns), None)
    if key is None:
        return []
    return list(dict.fromkeys(t for t in frame[key].map(canonical_ticker) if t))
