from __future__ import annotations

import json
import os
import sys
from pathlib import Path

import pandas as pd

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "src"
if str(SRC) not in sys.path:
    sys.path.insert(0, str(SRC))
if str(Path(__file__).resolve().parent) not in sys.path:
    sys.path.insert(0, str(Path(__file__).resolve().parent))

import build_flow_evidence_cache as flow_cache
from idx_flow_scanner.evidence_700 import write_evidence_coverage_report
from idx_flow_scanner.managed import load_bundled_universe
from idx_flow_scanner.providers.zapi import (
    ZapiQuotaExhausted,
    ZapiUnavailable,
    fetch_zapi_stock_summary_day,
)

UNIVERSE_PATH = ROOT / "data" / "universe" / "idx_700_all.csv"
TARGET_DAYS = 20
MAX_CALENDAR_DAYS = 55


def main() -> int:
    universe = load_bundled_universe(UNIVERSE_PATH)
    if len(universe) < 700:
        raise RuntimeError(f"expected 700-ticker universe, got {len(universe)}")
    if not str(os.getenv("ZAPI_KEY") or "").strip():
        raise RuntimeError("ZAPI_KEY unavailable")

    target = flow_cache._latest_completed_idx_weekday()
    parts: list[pd.DataFrame] = []
    valid_days = 0
    latest_snapshot = pd.DataFrame()
    latest_date = None

    for offset in range(MAX_CALENDAR_DAYS):
        day = target - pd.Timedelta(days=offset)
        if day.weekday() >= 5:
            continue
        try:
            frame = fetch_zapi_stock_summary_day(universe, day.date(), page_size=1000)
        except ZapiQuotaExhausted:
            raise
        except ZapiUnavailable:
            continue
        if frame is None or frame.empty:
            continue
        frame = frame.copy()
        if latest_snapshot.empty:
            latest_snapshot = frame.copy()
            latest_date = str(day.date())
        parts.append(frame)
        valid_days += 1
        print(json.dumps({
            "session": str(day.date()),
            "rows": int(len(frame)),
            "tickers": int(frame["ticker"].nunique()),
            "valid_days": valid_days,
        }, sort_keys=True))
        if valid_days >= TARGET_DAYS:
            break

    if valid_days < TARGET_DAYS:
        raise RuntimeError(f"only {valid_days}/{TARGET_DAYS} valid stock-summary sessions fetched")

    fresh = pd.concat(parts, ignore_index=True)
    fresh["trade_date"] = pd.to_datetime(fresh["trade_date"], errors="coerce").dt.normalize()
    fresh = fresh.dropna(subset=["ticker", "trade_date"])
    fresh = fresh.drop_duplicates(["ticker", "trade_date", "source"], keep="last")

    existing = flow_cache.load_bundled_zapi_foreign_flows(
        universe,
        flow_cache.ZAPI_FOREIGN_CACHE,
        lookback_calendar_days=120,
    )
    merged = flow_cache._merge_foreign(existing, fresh)
    flow_cache.write_zapi_foreign_cache(merged, flow_cache.ZAPI_FOREIGN_CACHE)
    flow_cache._write_json_foreign(merged)

    if not latest_snapshot.empty:
        flow_cache.write_zapi_stock_summary_cache(latest_snapshot, flow_cache.ZAPI_STOCK_SUMMARY_CACHE)

    coverage = write_evidence_coverage_report(UNIVERSE_PATH)
    counts = (
        merged.groupby("ticker", observed=True)["trade_date"].nunique()
        if not merged.empty else pd.Series(dtype=int)
    )
    complete = sum(int(counts.get(ticker, 0)) >= TARGET_DAYS for ticker in universe)
    result = {
        "status": "SUCCESS",
        "source": "ZAPI_IDX_STOCK_SUMMARY",
        "measurement": "DAILY_FOREIGN_BUY_SELL_SHARES",
        "latest_snapshot_date": latest_date,
        "latest_snapshot_tickers": int(latest_snapshot["ticker"].nunique()) if not latest_snapshot.empty else 0,
        "history_days": valid_days,
        "foreign_rows_after": int(len(merged)),
        "foreign_tickers_after": int(merged["ticker"].nunique()) if not merged.empty else 0,
        "tickers_with_20_sessions": int(complete),
        "coverage": coverage.get("coverage", {}),
        "no_fabricated_evidence": True,
    }
    print(json.dumps(result, indent=2, sort_keys=True, default=str))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
