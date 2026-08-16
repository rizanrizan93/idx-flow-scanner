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
    load_bundled_indexalpha_broker_flows,
    merge_broker_frames,
    write_broker_cache,
)

UNIVERSE_PATH = ROOT / "data" / "universe" / "idx_400_syariah.csv"
CACHE_DIR = ROOT / "data" / "cache"
OFFICIAL_CACHE = CACHE_DIR / "idx_official_flow_60d.csv.gz"
BROKER_CACHE = CACHE_DIR / "indexalpha_broker_60d.csv.gz"
META_PATH = CACHE_DIR / "flow_evidence_meta.json"


def _latest_weekday() -> pd.Timestamp:
    day = pd.Timestamp.now(tz="Asia/Jakarta").normalize().tz_localize(None)
    while day.weekday() >= 5:
        day -= pd.Timedelta(days=1)
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
    }

    existing_official = load_bundled_idx_official_flows(universe, OFFICIAL_CACHE, lookback_calendar_days=100)
    official_status = "UNCHANGED"
    try:
        fresh_official = fetch_idx_official_flow_history(
            universe,
            end_date=end_date.date(),
            target_trading_days=int(os.getenv("IDX_FOREIGN_TARGET_DAYS", "20")),
            max_calendar_days=int(os.getenv("IDX_FOREIGN_MAX_CALENDAR_DAYS", "45")),
            request_delay_seconds=float(os.getenv("IDX_REQUEST_DELAY_SECONDS", "1.0")),
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

    # IDX GetBrokerSummary is market-wide only. Probe it for source health, but
    # never write it into ticker-level broker evidence.
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
            "status": f"BLOCKED: {exc}",
            "rows": 0,
            "brokers": 0,
            "direct_evidence_eligible": False,
        }
    except Exception as exc:
        meta["official_market_broker_health"] = {
            "status": f"ERROR: {type(exc).__name__}: {exc}",
            "rows": 0,
            "brokers": 0,
            "direct_evidence_eligible": False,
        }

    existing_broker = load_bundled_indexalpha_broker_flows(universe, BROKER_CACHE, lookback_calendar_days=150)
    token_present = bool(str(os.getenv("INDEXALPHA_KEY") or os.getenv("INDEXALPHA_TOKEN") or "").strip())
    budget = max(0, int(os.getenv("INDEXALPHA_DAILY_BUDGET", "5")))
    selected = choose_broker_refresh_tickers(universe, existing_broker, budget_units=budget) if token_present else []
    broker_status = "NO_TOKEN" if not token_present else "NO_BUDGET" if budget == 0 else "UNCHANGED"
    fetched_parts: list[pd.DataFrame] = []
    consumed = 0
    if selected:
        for start in range(0, len(selected), 50):
            chunk = selected[start:start + 50]
            try:
                fresh = fetch_indexalpha_broker_batch(chunk, end_date.date())
                consumed += len(chunk)
                if not fresh.empty:
                    fetched_parts.append(fresh)
                broker_status = "UPDATED"
            except IndexAlphaQuotaExhausted as exc:
                broker_status = f"QUOTA_EXHAUSTED: {exc}"
                break
            except IndexAlphaUnavailable as exc:
                broker_status = f"UNAVAILABLE: {exc}"
                break
            except Exception as exc:
                broker_status = f"ERROR: {type(exc).__name__}: {exc}"
                break

    fresh_broker = pd.concat(fetched_parts, ignore_index=True) if fetched_parts else pd.DataFrame()
    merged_broker = merge_broker_frames(existing_broker, fresh_broker)
    if not merged_broker.empty:
        write_broker_cache(merged_broker, BROKER_CACHE)

    broker_stats = _stats(merged_broker)
    verified_tickers = 0
    if not merged_broker.empty and "source_verified" in merged_broker.columns:
        raw = merged_broker["source_verified"]
        verified = raw if pd.api.types.is_bool_dtype(raw) else raw.astype(str).str.lower().isin({"1", "true", "yes", "verified"})
        verified_tickers = int(merged_broker.loc[verified.fillna(False), "ticker"].nunique())
    meta["broker_direct_vendor"] = {
        "status": broker_status,
        "provider": "INDEXALPHA_API",
        "token_present": token_present,
        "budget_units": budget,
        "selected_tickers": selected,
        "quota_units_attempted": consumed,
        "verified_tickers": verified_tickers,
        **broker_stats,
    }

    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    META_PATH.write_text(json.dumps(meta, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps(meta, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
