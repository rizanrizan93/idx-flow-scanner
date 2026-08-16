from __future__ import annotations

import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path

import pandas as pd

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "src"
if str(SRC) not in sys.path:
    sys.path.insert(0, str(SRC))

from idx_flow_scanner.managed import load_bundled_universe
from idx_flow_scanner.providers.idx_official import (
    IdxOfficialAccessBlocked,
    fetch_idx_market_broker_summary,
    fetch_idx_official_flow_history,
    load_bundled_idx_official_flows,
    merge_official_flow_frames,
)
from idx_flow_scanner.providers.indexalpha import (
    IndexAlphaQuotaExhausted,
    IndexAlphaUnavailable,
    choose_broker_refresh_tickers,
    fetch_indexalpha_broker_batch,
    fetch_indexalpha_foreign_batch,
    load_bundled_indexalpha_broker_flows,
    load_bundled_indexalpha_foreign_flows,
    merge_broker_frames,
    merge_vendor_foreign_frames,
    write_broker_cache,
    write_foreign_cache,
)

UNIVERSE_PATH = ROOT / "data" / "universe" / "idx_400_syariah.csv"
CACHE_DIR = ROOT / "data" / "cache"
OFFICIAL_CACHE = CACHE_DIR / "idx_official_flow_60d.csv.gz"
BROKER_CACHE = CACHE_DIR / "indexalpha_broker_60d.csv.gz"
VENDOR_FOREIGN_CACHE = CACHE_DIR / "indexalpha_foreign_60d.csv.gz"
META_PATH = CACHE_DIR / "flow_evidence_meta.json"


def _latest_weekday() -> pd.Timestamp:
    day = pd.Timestamp.now(tz="Asia/Jakarta").normalize().tz_localize(None)
    while day.weekday() >= 5:
        day -= pd.Timedelta(1, unit="D")
    return day


def _write_official_cache(frame: pd.DataFrame) -> None:
    if frame is None or frame.empty:
        return
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    frame.to_csv(OFFICIAL_CACHE, index=False, compression="gzip")


def _stats(frame: pd.DataFrame) -> dict[str, object]:
    if frame is None or frame.empty:
        return {"rows": 0, "tickers": 0, "days": 0, "freshest": None}
    dates = pd.to_datetime(frame["trade_date"], errors="coerce") if "trade_date" in frame.columns else pd.Series(dtype="datetime64[ns]")
    return {
        "rows": int(len(frame)),
        "tickers": int(frame["ticker"].nunique()) if "ticker" in frame.columns else 0,
        "days": int(dates.nunique()) if not dates.empty else 0,
        "freshest": str(dates.max().date()) if not dates.empty and pd.notna(dates.max()) else None,
    }


def _fetch_in_chunks(selected: list[str], fetcher, trade_date) -> tuple[list[pd.DataFrame], int, str]:
    parts: list[pd.DataFrame] = []
    attempted = 0
    status = "UNCHANGED"
    for start in range(0, len(selected), 50):
        chunk = selected[start:start + 50]
        try:
            fresh = fetcher(chunk, trade_date)
            attempted += len(chunk)
            if not fresh.empty:
                parts.append(fresh)
            status = "UPDATED"
        except IndexAlphaQuotaExhausted as exc:
            status = f"QUOTA_EXHAUSTED: {exc}"
            break
        except IndexAlphaUnavailable as exc:
            status = f"UNAVAILABLE: {exc}"
            break
        except Exception as exc:
            status = f"ERROR: {type(exc).__name__}: {exc}"
            break
    return parts, attempted, status


def main() -> int:
    universe = load_bundled_universe(UNIVERSE_PATH)
    end_date = _latest_weekday()
    meta: dict[str, object] = {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "universe_count": len(universe),
        "target_trade_date": str(end_date.date()),
        "official_idx": {},
        "official_market_broker_health": {},
        "broker_direct_vendor": {},
        "foreign_vendor": {},
    }

    existing_official = load_bundled_idx_official_flows(universe, OFFICIAL_CACHE, lookback_calendar_days=100)
    official_status = "UNCHANGED"
    try:
        fresh_official = fetch_idx_official_flow_history(
            universe,
            end_date=end_date.date(),
            target_trading_days=int(os.getenv("IDX_FOREIGN_TARGET_DAYS", "20") or "20"),
            max_calendar_days=int(os.getenv("IDX_FOREIGN_MAX_CALENDAR_DAYS", "45") or "45"),
            request_delay_seconds=float(os.getenv("IDX_REQUEST_DELAY_SECONDS", "1.0") or "1.0"),
            raise_on_block=True,
        )
        merged_official = merge_official_flow_frames(existing_official, fresh_official)
        if not merged_official.empty:
            _write_official_cache(merged_official)
            official_status = "UPDATED" if not fresh_official.empty else "PRESERVED"
        else:
            merged_official = existing_official
    except IdxOfficialAccessBlocked as exc:
        merged_official = existing_official
        official_status = f"BLOCKED: {exc}"
    except Exception as exc:
        merged_official = existing_official
        official_status = f"ERROR: {type(exc).__name__}: {exc}"
    meta["official_idx"] = {"status": official_status, **_stats(merged_official)}

    try:
        market_broker = fetch_idx_market_broker_summary(end_date.date(), retries=1)
        meta["official_market_broker_health"] = {
            "status": "AVAILABLE" if not market_broker.empty else "NO_DATA",
            "rows": int(len(market_broker)),
            "brokers": int(market_broker["broker_code"].nunique()) if not market_broker.empty else 0,
            "direct_evidence_eligible": False,
        }
    except IdxOfficialAccessBlocked as exc:
        meta["official_market_broker_health"] = {
            "status": f"BLOCKED: {exc}", "rows": 0, "brokers": 0, "direct_evidence_eligible": False,
        }
    except Exception as exc:
        meta["official_market_broker_health"] = {
            "status": f"ERROR: {type(exc).__name__}: {exc}", "rows": 0, "brokers": 0, "direct_evidence_eligible": False,
        }

    token_present = bool(str(os.getenv("INDEXALPHA_KEY") or os.getenv("INDEXALPHA_TOKEN") or "").strip())
    total_budget = max(0, int(os.getenv("INDEXALPHA_DAILY_BUDGET", "5") or "5"))
    broker_budget = max(0, int(os.getenv("INDEXALPHA_BROKER_DAILY_BUDGET", str((total_budget + 1) // 2)) or "0"))
    foreign_budget = max(0, int(os.getenv("INDEXALPHA_FOREIGN_DAILY_BUDGET", str(total_budget // 2)) or "0"))

    existing_broker = load_bundled_indexalpha_broker_flows(universe, BROKER_CACHE, lookback_calendar_days=150)
    selected_broker = choose_broker_refresh_tickers(universe, existing_broker, budget_units=broker_budget) if token_present else []
    broker_status = "NO_TOKEN" if not token_present else "NO_BUDGET" if broker_budget == 0 else "UNCHANGED"
    broker_parts: list[pd.DataFrame] = []
    broker_attempted = 0
    if selected_broker:
        broker_parts, broker_attempted, broker_status = _fetch_in_chunks(
            selected_broker, fetch_indexalpha_broker_batch, end_date.date()
        )
    fresh_broker = pd.concat(broker_parts, ignore_index=True) if broker_parts else pd.DataFrame()
    merged_broker = merge_broker_frames(existing_broker, fresh_broker)
    if not merged_broker.empty:
        write_broker_cache(merged_broker, BROKER_CACHE)
    verified_tickers = 0
    if not merged_broker.empty and "source_verified" in merged_broker.columns:
        raw = merged_broker["source_verified"]
        verified = raw if pd.api.types.is_bool_dtype(raw) else raw.astype(str).str.lower().isin({"1", "true", "yes", "verified"})
        verified_tickers = int(merged_broker.loc[verified.fillna(False), "ticker"].nunique())
    meta["broker_direct_vendor"] = {
        "status": broker_status,
        "provider": "INDEXALPHA_API",
        "token_present": token_present,
        "budget_units": broker_budget,
        "selected_tickers": selected_broker,
        "quota_units_attempted": broker_attempted,
        "verified_tickers": verified_tickers,
        **_stats(merged_broker),
    }

    existing_vendor_foreign = load_bundled_indexalpha_foreign_flows(
        universe, VENDOR_FOREIGN_CACHE, lookback_calendar_days=150
    )
    selected_foreign = choose_broker_refresh_tickers(
        universe, existing_vendor_foreign, budget_units=foreign_budget
    ) if token_present else []
    foreign_status = "NO_TOKEN" if not token_present else "NO_BUDGET" if foreign_budget == 0 else "UNCHANGED"
    foreign_parts: list[pd.DataFrame] = []
    foreign_attempted = 0
    if selected_foreign:
        foreign_parts, foreign_attempted, foreign_status = _fetch_in_chunks(
            selected_foreign, fetch_indexalpha_foreign_batch, end_date.date()
        )
    fresh_vendor_foreign = pd.concat(foreign_parts, ignore_index=True) if foreign_parts else pd.DataFrame()
    merged_vendor_foreign = merge_vendor_foreign_frames(existing_vendor_foreign, fresh_vendor_foreign)
    if not merged_vendor_foreign.empty:
        write_foreign_cache(merged_vendor_foreign, VENDOR_FOREIGN_CACHE)
    meta["foreign_vendor"] = {
        "status": foreign_status,
        "provider": "INDEXALPHA_FOREIGN_FLOW",
        "flow_unit": "IDR",
        "token_present": token_present,
        "budget_units": foreign_budget,
        "selected_tickers": selected_foreign,
        "quota_units_attempted": foreign_attempted,
        **_stats(merged_vendor_foreign),
    }

    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    META_PATH.write_text(json.dumps(meta, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps(meta, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
