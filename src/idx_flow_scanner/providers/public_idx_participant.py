from __future__ import annotations

from datetime import date, timedelta
from pathlib import Path
from typing import Iterable
import gzip
import os

import pandas as pd

from ..data import canonical_ticker

PUBLIC_TRADE_DETAIL_URL = "https://www.idxdata3.co.id/IDX%20Reporting%20PSPP/Revitalisasi/Trade-Detail-Publik_{date}.csv"
SOURCE_NAME = "IDX_OFFICIAL_PUBLIC_TRADE_DETAIL_PARTICIPANT_FLOW"
VERSION = "1.0.0"

REQUIRED_COLUMNS = {
    "tradingdate", "asset", "participant_buy", "participant_sell", "volume", "value"
}


def _root_path() -> Path:
    return Path(__file__).resolve().parents[3]


def _allowed_tickers(universe: Iterable[str]) -> set[str]:
    return {canonical_ticker(t) for t in universe if canonical_ticker(t)}


def _http_get(url: str, timeout: float = 45.0) -> bytes:
    try:
        from curl_cffi import requests as curl_requests
        response = curl_requests.get(
            url,
            impersonate="chrome",
            headers={"Accept": "text/csv,text/plain,*/*", "User-Agent": "Mozilla/5.0"},
            timeout=timeout,
        )
    except Exception:
        import requests
        response = requests.get(url, headers={"Accept": "text/csv,text/plain,*/*"}, timeout=timeout)
    response.raise_for_status()
    return response.content


def _read_pipe_csv(payload: bytes) -> pd.DataFrame:
    from io import BytesIO
    sample = payload[:5000]
    delimiter = "|" if b"|" in sample else ","
    frame = pd.read_csv(BytesIO(payload), sep=delimiter, low_memory=False)
    frame.columns = [str(c).strip().lower() for c in frame.columns]
    if not REQUIRED_COLUMNS.issubset(frame.columns):
        raise ValueError(f"PUBLIC_IDX_REQUIRED_COLUMNS_MISSING:{sorted(REQUIRED_COLUMNS - set(frame.columns))}")
    return frame


def download_trade_detail(trade_date: date | str, *, timeout: float = 45.0) -> tuple[pd.DataFrame, str]:
    day = pd.Timestamp(trade_date).date().isoformat()
    url = PUBLIC_TRADE_DETAIL_URL.format(date=day.replace("-", ""))
    payload = _http_get(url, timeout=timeout)
    frame = _read_pipe_csv(payload)
    frame["tradingdate"] = pd.to_datetime(frame["tradingdate"], errors="coerce").dt.normalize()
    return frame, url


def aggregate_trade_detail(
    frame: pd.DataFrame,
    trade_date: date | str,
    universe: Iterable[str],
) -> pd.DataFrame:
    if frame is None or frame.empty:
        return pd.DataFrame()
    work = frame.copy()
    work.columns = [str(c).strip().lower() for c in work.columns]
    required = REQUIRED_COLUMNS
    missing = required - set(work.columns)
    if missing:
        raise ValueError(f"PUBLIC_IDX_REQUIRED_COLUMNS_MISSING:{sorted(missing)}")
    allowed = _allowed_tickers(universe)
    work["ticker"] = work["asset"].map(canonical_ticker)
    work = work[work["ticker"].isin(allowed)].copy()
    if work.empty:
        return pd.DataFrame()
    work["trade_date"] = pd.to_datetime(work["tradingdate"], errors="coerce").dt.normalize()
    fallback = pd.Timestamp(trade_date).normalize()
    work["trade_date"] = work["trade_date"].fillna(fallback)
    work["participant_buy"] = work["participant_buy"].astype(str).str.strip().replace({"": "UNKNOWN"})
    work["participant_sell"] = work["participant_sell"].astype(str).str.strip().replace({"": "UNKNOWN"})
    work["volume"] = pd.to_numeric(work["volume"], errors="coerce").fillna(0.0)
    work["value"] = pd.to_numeric(work["value"], errors="coerce").fillna(0.0)

    buy = work.groupby(["ticker", "trade_date", "participant_buy"], as_index=False).agg(
        buy_volume=("volume", "sum"),
        buy_value=("value", "sum"),
    ).rename(columns={"participant_buy": "participant"})
    buy["sell_volume"] = 0.0
    buy["sell_value"] = 0.0
    sell = work.groupby(["ticker", "trade_date", "participant_sell"], as_index=False).agg(
        sell_volume=("volume", "sum"),
        sell_value=("value", "sum"),
    ).rename(columns={"participant_sell": "participant"})
    sell["buy_volume"] = 0.0
    sell["buy_value"] = 0.0
    merged = pd.concat([buy, sell], ignore_index=True).groupby(
        ["ticker", "trade_date", "participant"], as_index=False
    ).sum(numeric_only=True)
    merged["net_volume"] = merged["buy_volume"] - merged["sell_volume"]
    merged["net_value"] = merged["buy_value"] - merged["sell_value"]
    merged["buy_avg"] = merged["buy_value"].div(merged["buy_volume"].replace(0.0, pd.NA))
    merged["sell_avg"] = merged["sell_value"].div(merged["sell_volume"].replace(0.0, pd.NA))
    merged["participant_flow_source"] = SOURCE_NAME
    merged["participant_flow_version"] = VERSION
    return merged.sort_values(["ticker", "trade_date", "net_value"], ascending=[True, True, False], kind="stable").reset_index(drop=True)


def trim_top_participants(frame: pd.DataFrame, top_n: int = 10) -> pd.DataFrame:
    if frame is None or frame.empty:
        return pd.DataFrame()
    work = frame.copy()
    work["net_rank"] = work.groupby(["ticker", "trade_date"])["net_value"].rank(method="first", ascending=False)
    negative = work.copy()
    negative["abs_net_value"] = negative["net_value"].abs()
    negative["sell_rank"] = negative.groupby(["ticker", "trade_date"])["abs_net_value"].rank(method="first", ascending=False)
    buyers = work[work["net_value"] > 0].copy()
    buyers["side"] = "TOP_NET_BUYER"
    buyers["flow_rank"] = buyers.groupby(["ticker", "trade_date"])["net_value"].rank(method="first", ascending=False)
    sellers = negative[negative["net_value"] < 0].copy()
    sellers["side"] = "TOP_NET_SELLER"
    sellers["flow_rank"] = sellers.groupby(["ticker", "trade_date"])["abs_net_value"].rank(method="first", ascending=False)
    out = pd.concat([buyers[buyers["flow_rank"] <= top_n], sellers[sellers["flow_rank"] <= top_n]], ignore_index=True)
    return out.drop(columns=["abs_net_value"], errors="ignore").sort_values(["ticker", "trade_date", "side", "flow_rank"], kind="stable").reset_index(drop=True)


def load_cache(universe: Iterable[str], path: Path | None = None, *, lookback_calendar_days: int = 90) -> pd.DataFrame:
    cache_path = path or (_root_path() / "data" / "cache" / "idx_public_participant_30d.csv.gz")
    if not cache_path.exists():
        return pd.DataFrame()
    try:
        frame = pd.read_csv(cache_path, compression="gzip")
    except Exception:
        return pd.DataFrame()
    frame.columns = [str(c).strip().lower() for c in frame.columns]
    if "ticker" not in frame.columns or "trade_date" not in frame.columns:
        return pd.DataFrame()
    names = _allowed_tickers(universe)
    frame["ticker"] = frame["ticker"].map(canonical_ticker)
    frame["trade_date"] = pd.to_datetime(frame["trade_date"], errors="coerce").dt.normalize()
    cutoff = pd.Timestamp.now(tz="Asia/Jakarta").tz_localize(None).normalize() - pd.Timedelta(days=int(lookback_calendar_days))
    return frame[frame["ticker"].isin(names) & frame["trade_date"].ge(cutoff)].dropna(subset=["ticker", "trade_date"]).reset_index(drop=True)


def write_cache(frame: pd.DataFrame, path: Path | None = None) -> None:
    cache_path = path or (_root_path() / "data" / "cache" / "idx_public_participant_30d.csv.gz")
    cache_path.parent.mkdir(parents=True, exist_ok=True)
    if frame is None or frame.empty:
        return
    frame.to_csv(cache_path, index=False, compression="gzip")


def collect_recent_days(
    universe: Iterable[str],
    *,
    end_date: date | str,
    target_trading_days: int = 20,
    max_calendar_days: int = 45,
) -> tuple[pd.DataFrame, dict[str, object]]:
    names = list(dict.fromkeys(canonical_ticker(t) for t in universe if canonical_ticker(t)))
    end = pd.Timestamp(end_date).date()
    parts: list[pd.DataFrame] = []
    attempted = 0
    succeeded = 0
    source_urls: list[str] = []
    failure_counts: dict[str, int] = {}
    last_error = ""
    for offset in range(max(1, int(max_calendar_days))):
        day = end - timedelta(days=offset)
        if day.weekday() >= 5:
            continue
        attempted += 1
        try:
            raw, url = download_trade_detail(day)
            aggregated = trim_top_participants(aggregate_trade_detail(raw, day, names), top_n=10)
            if not aggregated.empty:
                parts.append(aggregated)
                succeeded += 1
                source_urls.append(url)
        except Exception as exc:
            key = type(exc).__name__
            failure_counts[key] = failure_counts.get(key, 0) + 1
            last_error = f"{key}: {str(exc)[:160]}"
            continue
        if succeeded >= int(target_trading_days):
            break
    frame = pd.concat(parts, ignore_index=True) if parts else pd.DataFrame()
    meta = {
        "status": "UPDATED" if not frame.empty else "NO_DATA_PROVIDER_ERRORS" if failure_counts else "NO_DATA",
        "attempted_days": attempted,
        "succeeded_days": succeeded,
        "rows": int(len(frame)),
        "tickers": int(frame["ticker"].nunique()) if not frame.empty else 0,
        "latest_trade_date": str(pd.to_datetime(frame["trade_date"], errors="coerce").max().date()) if not frame.empty else None,
        "source": SOURCE_NAME,
        "source_urls": source_urls[-5:],
        "failure_counts": failure_counts,
        "last_error": last_error,
        "provenance": "OFFICIAL_IDX_PUBLIC_EOD_TRADE_DETAIL_PARTICIPANT_FLOW_NOT_BENEFICIAL_OWNER",
        "version": VERSION,
    }
    return frame, meta


def score_participant_history(history: pd.DataFrame, universe: Iterable[str], lookback_days: int = 20) -> pd.DataFrame:
    names = sorted(_allowed_tickers(universe))
    frame = history.copy() if history is not None else pd.DataFrame()
    rows: list[dict[str, object]] = []
    for ticker in names:
        local = frame[frame.get("ticker", pd.Series(dtype=str)).eq(ticker)].copy() if not frame.empty else pd.DataFrame()
        if local.empty:
            rows.append({"ticker": ticker, "participant_flow_state": "NO_DATA", "participant_flow_coverage_pct": 0.0})
            continue
        local["trade_date"] = pd.to_datetime(local["trade_date"], errors="coerce").dt.normalize()
        dates = sorted(local["trade_date"].dropna().unique())[-lookback_days:]
        recent = local[local["trade_date"].isin(dates)].copy()
        buyers = recent[recent["side"].eq("TOP_NET_BUYER")].copy()
        sellers = recent[recent["side"].eq("TOP_NET_SELLER")].copy()
        top3 = buyers.sort_values(["trade_date", "flow_rank"]).groupby("trade_date").head(3)
        counts = top3["participant"].value_counts() if not top3.empty else pd.Series(dtype=float)
        persistent = str(counts.index[0]) if not counts.empty else ""
        persistence_days = float(counts.iloc[0]) if not counts.empty else 0.0
        broker_net = buyers.groupby("participant")["net_value"].sum().sort_values(ascending=False) if not buyers.empty else pd.Series(dtype=float)
        top_net = float(broker_net.iloc[0]) if len(broker_net) else float("nan")
        positive = float(buyers["net_value"].clip(lower=0).sum()) if not buyers.empty else 0.0
        negative = float(sellers["net_value"].abs().sum()) if not sellers.empty else 0.0
        concentration = 100.0 * top_net / positive if top_net > 0 and positive > 0 else float("nan")
        dominance = 50.0 + 15.0 * (positive / negative if negative > 0 else (5.0 if positive > 0 else 0.0))
        dominance = float(max(0.0, min(100.0, dominance)))
        days = len(dates)
        latest_date = max(dates) if dates else pd.NaT
        latest = recent[recent["trade_date"].eq(latest_date)] if pd.notna(latest_date) else pd.DataFrame()
        latest_buyers = latest[latest["side"].eq("TOP_NET_BUYER")].sort_values("flow_rank")
        latest_participant = str(latest_buyers.iloc[0]["participant"]) if not latest_buyers.empty else ""
        latest_avg = float(latest_buyers.iloc[0]["buy_avg"]) if not latest_buyers.empty and pd.notna(latest_buyers.iloc[0].get("buy_avg")) else float("nan")
        rows.append({
            "ticker": ticker,
            "participant_flow_observed_days": days,
            "participant_flow_latest_date": latest_date,
            "participant_top_buyer_code": persistent,
            "participant_latest_top_buyer_code": latest_participant,
            "participant_top3_buyer_persistence_20d_pct": 100.0 * persistence_days / max(1, days),
            "participant_top_buyer_net_value_20d": top_net,
            "participant_buyer_concentration_pct": concentration,
            "participant_buy_sell_dominance_score": dominance,
            "participant_latest_top_buyer_buy_avg": latest_avg,
            "participant_flow_coverage_pct": min(100.0, 100.0 * days / max(1, lookback_days)),
            "participant_flow_source": SOURCE_NAME,
            "participant_flow_provenance": "OFFICIAL_IDX_PUBLIC_EOD_TRADE_DETAIL_PARTICIPANT_FLOW_NOT_BENEFICIAL_OWNER",
        })
    out = pd.DataFrame(rows)
    values = pd.to_numeric(out["participant_top_buyer_net_value_20d"], errors="coerce")
    valid = values.notna()
    net_score = pd.Series(float("nan"), index=out.index, dtype=float)
    if int(valid.sum()) >= 3:
        net_score.loc[valid] = values.loc[valid].rank(pct=True) * 100.0
    elif int(valid.sum()) > 0:
        net_score.loc[valid] = 50.0
    out["participant_net_score"] = net_score
    persistence = pd.to_numeric(out["participant_top3_buyer_persistence_20d_pct"], errors="coerce").fillna(0).clip(0, 100)
    concentration = pd.to_numeric(out["participant_buyer_concentration_pct"], errors="coerce").fillna(0).clip(0, 100)
    dominance = pd.to_numeric(out["participant_buy_sell_dominance_score"], errors="coerce").fillna(50).clip(0, 100)
    out["participant_accumulation_score"] = (
        0.35 * out["participant_net_score"].fillna(50)
        + 0.25 * persistence
        + 0.20 * concentration
        + 0.20 * dominance
    ).clip(0, 100).round(1)
    out["participant_smart_money_confirmation_score"] = (
        0.70 * out["participant_accumulation_score"]
        + 0.30 * out["participant_net_score"].fillna(50)
    ).clip(0, 100).round(1)
    out["participant_accumulation_state"] = pd.Series(
        pd.NA, index=out.index, dtype="string"
    )
    out.loc[out["participant_flow_coverage_pct"] <= 0, "participant_accumulation_state"] = "NO_DATA"
    out.loc[(out["participant_flow_coverage_pct"] > 0) & (out["participant_accumulation_score"] >= 70), "participant_accumulation_state"] = "PARTICIPANT_ACCUMULATION"
    out.loc[(out["participant_flow_coverage_pct"] > 0) & (out["participant_accumulation_score"] <= 35), "participant_accumulation_state"] = "PARTICIPANT_DISTRIBUTION"
    out["participant_accumulation_state"] = out["participant_accumulation_state"].fillna("PARTICIPANT_MIXED")
    out["participant_flow_version"] = VERSION
    return out

__all__ = [
    "SOURCE_NAME", "download_trade_detail", "aggregate_trade_detail", "trim_top_participants",
    "load_cache", "write_cache", "collect_recent_days", "score_participant_history",
]
