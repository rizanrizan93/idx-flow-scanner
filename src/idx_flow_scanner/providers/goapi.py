from __future__ import annotations

import os
from pathlib import Path
from typing import Iterable

import pandas as pd

from ..data import canonical_ticker, normalize_broker_summary

GOAPI_BASE_URL = "https://api.goapi.io"
GOAPI_SOURCE = "GOAPI_BROKER_SUMMARY_NET"


class GoApiUnavailable(RuntimeError):
    pass


class GoApiQuotaExhausted(GoApiUnavailable):
    pass


def _root_path() -> Path:
    return Path(__file__).resolve().parents[3]


def _key(explicit: str | None = None) -> str | None:
    value = explicit or os.getenv("GOAPI_KEY")
    value = str(value or "").strip()
    return value or None


def normalize_goapi_broker_payload(
    payload: dict,
    ticker: str,
    trade_date: str | pd.Timestamp,
    *,
    investor: str = "ALL",
) -> pd.DataFrame:
    """Normalize GOAPI's documented stock-level NET broker summary.

    GOAPI returns one row per broker with side BUY or SELL and volume in lots.
    We convert lots to shares. Because the contract is NET-side rather than raw
    gross executions, provenance says so explicitly and the existing closed-book
    balance/coverage gates still decide whether the evidence may become direct.
    """
    data = payload.get("data") if isinstance(payload, dict) else None
    results = data.get("results") if isinstance(data, dict) else None
    if not isinstance(results, list):
        return pd.DataFrame()
    symbol = canonical_ticker(ticker)
    fallback_day = pd.Timestamp(trade_date).date().isoformat()
    rows: list[dict[str, object]] = []
    for item in results:
        if not isinstance(item, dict):
            continue
        broker = item.get("broker") if isinstance(item.get("broker"), dict) else {}
        code = str(item.get("code") or broker.get("code") or "").strip().upper()
        side = str(item.get("side") or "").strip().upper()
        if not code or side not in {"BUY", "SELL"}:
            continue
        transaction_type = str(item.get("transaction_type") or "NET").strip().upper()
        if transaction_type != "NET":
            continue
        row_symbol = canonical_ticker(item.get("symbol") or symbol)
        if row_symbol != symbol:
            continue
        parsed_day = pd.to_datetime(item.get("date") or fallback_day, errors="coerce")
        day = parsed_day.date().isoformat() if pd.notna(parsed_day) else fallback_day
        lot = pd.to_numeric(item.get("lot"), errors="coerce")
        value = pd.to_numeric(item.get("value"), errors="coerce")
        avg = pd.to_numeric(item.get("avg"), errors="coerce")
        shares = float(lot) * 100.0 if pd.notna(lot) else 0.0
        amount = float(value) if pd.notna(value) else 0.0
        average = float(avg) if pd.notna(avg) else 0.0
        rows.append({
            "ticker": symbol,
            "trade_date": day,
            "broker_code": code,
            "buy_value": amount if side == "BUY" else 0.0,
            "sell_value": amount if side == "SELL" else 0.0,
            "buy_volume": shares if side == "BUY" else 0.0,
            "sell_volume": shares if side == "SELL" else 0.0,
            "buy_avg": average if side == "BUY" else 0.0,
            "sell_avg": average if side == "SELL" else 0.0,
            "market_type": "ALL",
            "source": GOAPI_SOURCE,
            "source_verified": True,
            "source_url": f"{GOAPI_BASE_URL}/stock/idx/{symbol}/broker_summary",
            "provenance_state": f"VERIFIED_VENDOR_API_NET_SIDE_{str(investor).upper()}",
        })
    if not rows:
        return pd.DataFrame()
    return normalize_broker_summary(pd.DataFrame(rows))


def fetch_goapi_broker_summary(
    ticker: str,
    trade_date: str | pd.Timestamp,
    *,
    api_key: str | None = None,
    investor: str = "ALL",
    timeout: float = 30.0,
) -> pd.DataFrame:
    key = _key(api_key)
    if not key:
        return pd.DataFrame()
    symbol = canonical_ticker(ticker)
    if not symbol:
        return pd.DataFrame()
    day = pd.Timestamp(trade_date).date().isoformat()

    from curl_cffi import requests as curl_requests

    response = curl_requests.get(
        f"{GOAPI_BASE_URL}/stock/idx/{symbol}/broker_summary",
        params={"date": day, "investor": str(investor).upper()},
        headers={"Accept": "application/json", "X-API-KEY": key},
        impersonate="chrome",
        timeout=timeout,
    )
    if response.status_code == 401:
        raise GoApiUnavailable("GOAPI key invalid or missing")
    if response.status_code in {402, 403}:
        raise GoApiUnavailable("GOAPI plan does not allow broker summary")
    if response.status_code == 429:
        raise GoApiQuotaExhausted("GOAPI quota/rate limit exhausted")
    if response.status_code == 204:
        return pd.DataFrame()
    if response.status_code != 200:
        raise GoApiUnavailable(f"GOAPI HTTP {response.status_code}")
    payload = response.json()
    if not isinstance(payload, dict) or str(payload.get("status") or "").lower() not in {"", "success"}:
        raise GoApiUnavailable(str((payload or {}).get("message") or "GOAPI invalid response"))
    return normalize_goapi_broker_payload(payload, symbol, day, investor=investor)


def load_bundled_goapi_broker_flows(
    universe: Iterable[str],
    path: Path | None = None,
    *,
    lookback_calendar_days: int = 150,
) -> pd.DataFrame:
    cache_path = path or (_root_path() / "data" / "cache" / "goapi_broker_60d.csv.gz")
    if not cache_path.exists():
        return pd.DataFrame()
    try:
        out = normalize_broker_summary(pd.read_csv(cache_path))
    except Exception:
        return pd.DataFrame()
    names = {canonical_ticker(t) for t in universe if canonical_ticker(t)}
    cutoff = pd.Timestamp.today().normalize() - pd.Timedelta(days=int(lookback_calendar_days))
    out = out[out["ticker"].isin(names) & out["trade_date"].ge(cutoff)].copy()
    for col, default in (("source_verified", False), ("source_url", None), ("provenance_state", None)):
        if col not in out.columns:
            out[col] = default
    return out.sort_values(["ticker", "trade_date", "broker_code"], kind="stable").reset_index(drop=True)


def merge_goapi_broker_frames(*frames: pd.DataFrame) -> pd.DataFrame:
    valid = [f.copy() for f in frames if f is not None and not f.empty]
    if not valid:
        return pd.DataFrame()
    out = normalize_broker_summary(pd.concat(valid, ignore_index=True))
    keys = ["ticker", "trade_date", "broker_code", "market_type", "source"]
    return out.drop_duplicates(keys, keep="last").sort_values(
        ["ticker", "trade_date", "broker_code"], kind="stable"
    ).reset_index(drop=True)


def choose_goapi_backfill_jobs(
    universe: Iterable[str],
    existing: pd.DataFrame,
    trade_dates: Iterable[str | pd.Timestamp],
    *,
    budget_requests: int,
) -> list[tuple[str, str]]:
    """Prioritize ticker/day holes so paid or trial quota creates usable history.

    The scheduler fills the latest missing dates round-robin across tickers, which
    avoids spending the entire quota repeatedly on the first alphabetic names.
    """
    names = list(dict.fromkeys(canonical_ticker(t) for t in universe if canonical_ticker(t)))
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
    # Date-major round robin makes all tickers gain the newest day before older
    # history, while repeated runs naturally backfill toward minimum history.
    for day in dates:
        for ticker in names:
            if (ticker, day) in present:
                continue
            jobs.append((ticker, day))
            if len(jobs) >= budget:
                return jobs
    return jobs


def write_goapi_broker_cache(frame: pd.DataFrame, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if frame is not None and not frame.empty:
        frame.to_csv(path, index=False, compression="gzip")
