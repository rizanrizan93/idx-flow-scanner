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
from idx_flow_scanner.providers.goapi import (
    GoApiQuotaExhausted,
    GoApiUnavailable,
    choose_goapi_backfill_jobs,
    fetch_goapi_broker_summary,
    load_bundled_goapi_broker_flows,
    merge_goapi_broker_frames,
    write_goapi_broker_cache,
)
from idx_flow_scanner.providers.indexalpha import (
    IndexAlphaQuotaExhausted,
    IndexAlphaUnavailable,
    choose_indexalpha_daily_jobs,
    fetch_indexalpha_broker_summary,
    load_bundled_indexalpha_broker_flows,
    load_indexalpha_targets,
    merge_indexalpha_broker_frames,
    write_indexalpha_broker_cache,
)
from idx_flow_scanner.providers.idx_official import (
    IdxOfficialAccessBlocked,
    fetch_idx_market_broker_summary,
    fetch_idx_official_flow_history,
    load_bundled_idx_official_flows,
    merge_official_flow_frames,
)
from idx_flow_scanner.providers.zapi import (
    ZapiQuotaExhausted,
    ZapiUnavailable,
    fetch_zapi_foreign_flow_history,
    load_bundled_zapi_foreign_flows,
    write_zapi_foreign_cache,
)

UNIVERSE_PATH = ROOT / "data" / "universe" / "idx_400_syariah.csv"
CACHE_DIR = ROOT / "data" / "cache"
DIRECT_IDX_CACHE = CACHE_DIR / "idx_official_flow_60d.csv.gz"
ZAPI_FOREIGN_CACHE = CACHE_DIR / "zapi_idx_foreign_60d.csv.gz"
GOAPI_BROKER_CACHE = CACHE_DIR / "goapi_broker_60d.csv.gz"
INDEX_ALPHA_BROKER_CACHE = CACHE_DIR / "indexalpha_broker_60d.csv.gz"
META_PATH = CACHE_DIR / "flow_evidence_meta.json"


def _latest_weekday() -> pd.Timestamp:
    day = pd.Timestamp.now(tz="Asia/Jakarta").normalize().tz_localize(None)
    while day.weekday() >= 5:
        day -= pd.Timedelta(days=1)
    return day


def _write_direct_idx_cache(frame: pd.DataFrame) -> None:
    if frame is None or frame.empty:
        return
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    frame.to_csv(DIRECT_IDX_CACHE, index=False, compression="gzip")


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


def _candidate_trade_dates(foreign_candidates: pd.DataFrame, end_date: pd.Timestamp, count: int = 20) -> list[str]:
    if foreign_candidates is not None and not foreign_candidates.empty:
        dates = pd.to_datetime(foreign_candidates["trade_date"], errors="coerce").dropna().dt.normalize().unique()
        if len(dates):
            return [str(pd.Timestamp(d).date()) for d in sorted(dates, reverse=True)[:count]]
    dates: list[str] = []
    cursor = end_date
    while len(dates) < count:
        if cursor.weekday() < 5:
            dates.append(str(cursor.date()))
        cursor -= pd.Timedelta(days=1)
    return dates


def main() -> int:
    universe = load_bundled_universe(UNIVERSE_PATH)
    end_date = _latest_weekday()
    meta: dict[str, object] = {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "universe_count": len(universe),
        "target_trade_date": str(end_date.date()),
        "direct_idx_foreign": {},
        "zapi_idx_foreign": {},
        "official_market_broker_health": {},
        "goapi_broker_direct": {},
        "indexalpha_broker_direct": {},
    }

    # Tier 1: direct public IDX TradingSummary. This remains the preferred source
    # but is allowed to fail closed when Cloudflare challenges cloud egress.
    existing_direct = load_bundled_idx_official_flows(universe, DIRECT_IDX_CACHE, lookback_calendar_days=120)
    direct_status = "UNCHANGED"
    try:
        fresh_direct = fetch_idx_official_flow_history(
            universe,
            end_date=end_date.date(),
            target_trading_days=int(os.getenv("IDX_FOREIGN_TARGET_DAYS", "20") or "20"),
            max_calendar_days=int(os.getenv("IDX_FOREIGN_MAX_CALENDAR_DAYS", "45") or "45"),
            request_delay_seconds=float(os.getenv("IDX_REQUEST_DELAY_SECONDS", "1.0") or "1.0"),
            raise_on_block=True,
        )
        merged_direct = merge_official_flow_frames(existing_direct, fresh_direct)
        if not merged_direct.empty:
            _write_direct_idx_cache(merged_direct)
            direct_status = "UPDATED" if not fresh_direct.empty else "PRESERVED"
        else:
            merged_direct = existing_direct
    except IdxOfficialAccessBlocked as exc:
        merged_direct = existing_direct
        direct_status = f"BLOCKED: {exc}"
    except Exception as exc:
        merged_direct = existing_direct
        direct_status = f"ERROR: {type(exc).__name__}: {exc}"
    meta["direct_idx_foreign"] = {"status": direct_status, **_stats(merged_direct)}

    # Tier 2: Zapi. Bootstrap the desired history once; after that only refresh
    # the newest trading day. This keeps the free-tier request budget sustainable
    # instead of downloading the same 20-day window on every scheduled run.
    existing_zapi = load_bundled_zapi_foreign_flows(universe, ZAPI_FOREIGN_CACHE, lookback_calendar_days=120)
    zapi_key_present = bool(str(os.getenv("ZAPI_KEY") or "").strip())
    zapi_target_days = max(1, int(os.getenv("ZAPI_FOREIGN_TARGET_DAYS", "20") or "20"))
    zapi_max_calendar_days = max(zapi_target_days, int(os.getenv("ZAPI_FOREIGN_MAX_CALENDAR_DAYS", "45") or "45"))
    zapi_status = "NO_TOKEN" if not zapi_key_present else "UNCHANGED"
    merged_zapi = existing_zapi
    if zapi_key_present:
        try:
            cached_dates = pd.to_datetime(existing_zapi.get("trade_date"), errors="coerce").dropna() if not existing_zapi.empty else pd.Series(dtype="datetime64[ns]")
            cached_days = int(cached_dates.dt.normalize().nunique()) if not cached_dates.empty else 0
            freshest_cached = cached_dates.max().normalize() if not cached_dates.empty else pd.NaT
            if cached_days >= zapi_target_days and pd.notna(freshest_cached) and freshest_cached >= end_date.normalize():
                fresh_zapi = pd.DataFrame()
                zapi_status = "PRESERVED"
            else:
                incremental = cached_days >= zapi_target_days
                fresh_zapi = fetch_zapi_foreign_flow_history(
                    universe,
                    end_date=end_date.date(),
                    target_trading_days=1 if incremental else zapi_target_days,
                    max_calendar_days=7 if incremental else zapi_max_calendar_days,
                )
                zapi_status = "UPDATED" if not fresh_zapi.empty else "NO_DATA"
            merged_zapi = merge_official_flow_frames(existing_zapi, fresh_zapi)
            if not merged_zapi.empty:
                write_zapi_foreign_cache(merged_zapi, ZAPI_FOREIGN_CACHE)
        except ZapiQuotaExhausted as exc:
            zapi_status = f"QUOTA_EXHAUSTED: {exc}"
        except ZapiUnavailable as exc:
            zapi_status = f"UNAVAILABLE: {exc}"
        except Exception as exc:
            zapi_status = f"ERROR: {type(exc).__name__}: {exc}"
    meta["zapi_idx_foreign"] = {
        "status": zapi_status,
        "token_present": zapi_key_present,
        "flow_unit": "SHARES",
        "target_history_days": zapi_target_days,
        "refresh_mode": "INCREMENTAL_AFTER_BOOTSTRAP",
        **_stats(merged_zapi),
    }

    # IDX GetBrokerSummary is market-wide only: useful source-health telemetry,
    # never stock-level direct evidence.
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

    # Stock-level broker path: GOAPI's documented per-symbol NET broker summary.
    # The request budget is deliberately repository-variable driven so a free
    # trial cannot accidentally be consumed like a paid production quota.
    existing_broker = load_bundled_goapi_broker_flows(universe, GOAPI_BROKER_CACHE, lookback_calendar_days=180)
    goapi_key_present = bool(str(os.getenv("GOAPI_KEY") or "").strip())
    goapi_budget = max(0, int(os.getenv("GOAPI_DAILY_BUDGET", "5") or "5"))
    foreign_candidates = merge_official_flow_frames(merged_direct, merged_zapi)
    trade_dates = _candidate_trade_dates(foreign_candidates, end_date, count=20)
    jobs = choose_goapi_backfill_jobs(
        universe,
        existing_broker,
        trade_dates,
        budget_requests=goapi_budget,
    ) if goapi_key_present else []
    goapi_status = "NO_TOKEN" if not goapi_key_present else "NO_BUDGET" if goapi_budget == 0 else "UNCHANGED"
    broker_parts: list[pd.DataFrame] = []
    attempted = 0
    for ticker, day in jobs:
        try:
            frame = fetch_goapi_broker_summary(ticker, day, investor="ALL")
            attempted += 1
            if not frame.empty:
                broker_parts.append(frame)
            goapi_status = "UPDATED"
        except GoApiQuotaExhausted as exc:
            goapi_status = f"QUOTA_EXHAUSTED: {exc}"
            break
        except GoApiUnavailable as exc:
            goapi_status = f"UNAVAILABLE: {exc}"
            break
        except Exception as exc:
            goapi_status = f"ERROR: {type(exc).__name__}: {exc}"
            break

    fresh_broker = pd.concat(broker_parts, ignore_index=True) if broker_parts else pd.DataFrame()
    merged_broker = merge_goapi_broker_frames(existing_broker, fresh_broker)
    if not merged_broker.empty:
        write_goapi_broker_cache(merged_broker, GOAPI_BROKER_CACHE)
    verified_tickers = 0
    if not merged_broker.empty and "source_verified" in merged_broker.columns:
        raw = merged_broker["source_verified"]
        verified = raw if pd.api.types.is_bool_dtype(raw) else raw.astype(str).str.lower().isin({"1", "true", "yes", "verified"})
        verified_tickers = int(merged_broker.loc[verified.fillna(False), "ticker"].nunique())
    meta["goapi_broker_direct"] = {
        "status": goapi_status,
        "provider": "GOAPI_BROKER_SUMMARY_NET",
        "token_present": goapi_key_present,
        "budget_requests": goapi_budget,
        "requests_attempted": attempted,
        "jobs_planned": len(jobs),
        "verified_tickers": verified_tickers,
        "target_history_days": len(trade_dates),
        **_stats(merged_broker),
    }

    # Free permanent stock-level broker path: Index Alpha. The public free plan
    # allows five requests/day, so we pin a five-ticker cohort and request one
    # exact trading day per ticker. A range aggregate is never expanded into
    # fabricated daily evidence. Existing direct-evidence gates remain unchanged.
    existing_indexalpha = load_bundled_indexalpha_broker_flows(
        universe, INDEX_ALPHA_BROKER_CACHE, lookback_calendar_days=180
    )
    indexalpha_targets = [t for t in load_indexalpha_targets() if t in set(universe)]
    indexalpha_key_present = bool(str(os.getenv("INDEX_ALPHA_KEY") or "").strip())
    indexalpha_budget = max(0, int(os.getenv("INDEX_ALPHA_DAILY_BUDGET", "5") or "5"))
    indexalpha_jobs = choose_indexalpha_daily_jobs(
        indexalpha_targets, existing_indexalpha, trade_dates, budget_requests=indexalpha_budget
    ) if indexalpha_key_present else []
    indexalpha_status = (
        "NO_TOKEN" if not indexalpha_key_present else
        "NO_BUDGET" if indexalpha_budget == 0 else "UNCHANGED"
    )
    indexalpha_parts: list[pd.DataFrame] = []
    indexalpha_attempted = 0
    for ticker, day in indexalpha_jobs:
        try:
            frame = fetch_indexalpha_broker_summary(
                ticker, day, investor="all", market="RG"
            )
            indexalpha_attempted += 1
            if not frame.empty:
                indexalpha_parts.append(frame)
            indexalpha_status = "UPDATED"
        except IndexAlphaQuotaExhausted as exc:
            indexalpha_status = f"QUOTA_EXHAUSTED: {exc}"
            break
        except IndexAlphaUnavailable as exc:
            indexalpha_status = f"UNAVAILABLE: {exc}"
            break
        except Exception as exc:
            indexalpha_status = f"ERROR: {type(exc).__name__}: {exc}"
            break

    fresh_indexalpha = pd.concat(indexalpha_parts, ignore_index=True) if indexalpha_parts else pd.DataFrame()
    merged_indexalpha = merge_indexalpha_broker_frames(existing_indexalpha, fresh_indexalpha)
    if not merged_indexalpha.empty:
        write_indexalpha_broker_cache(merged_indexalpha, INDEX_ALPHA_BROKER_CACHE)
    indexalpha_verified_tickers = 0
    if not merged_indexalpha.empty and "source_verified" in merged_indexalpha.columns:
        raw = merged_indexalpha["source_verified"]
        verified = raw if pd.api.types.is_bool_dtype(raw) else raw.astype(str).str.lower().isin({"1", "true", "yes", "verified"})
        indexalpha_verified_tickers = int(merged_indexalpha.loc[verified.fillna(False), "ticker"].nunique())
    meta["indexalpha_broker_direct"] = {
        "status": indexalpha_status,
        "provider": "INDEX_ALPHA_BROKER_SUMMARY",
        "contract": "STOCK_LEVEL_GROSS_BUY_SELL_EXACT_DAY_RG_ALL",
        "token_present": indexalpha_key_present,
        "budget_requests": indexalpha_budget,
        "requests_attempted": indexalpha_attempted,
        "jobs_planned": len(indexalpha_jobs),
        "targets": indexalpha_targets,
        "verified_tickers": indexalpha_verified_tickers,
        "target_history_days": len(trade_dates),
        **_stats(merged_indexalpha),
    }

    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    META_PATH.write_text(json.dumps(meta, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps(meta, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
