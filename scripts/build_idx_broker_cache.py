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
    fetch_idx_universe_broker_history,
    load_bundled_idx_official_broker_flows,
)
from idx_flow_scanner.providers.public_idx_participant import load_cache as load_public_participant_cache

UNIVERSE = ROOT / "data" / "universe" / "idx_400_syariah.csv"
CACHE = ROOT / "data" / "cache" / "idx_official_broker_60d.csv.gz"
META = ROOT / "data" / "cache" / "idx_official_broker_meta.json"
PUBLIC_PARTICIPANT_CACHE = ROOT / "data" / "cache" / "idx_public_participant_30d.csv.gz"


def _participant_to_broker_rows(frame: pd.DataFrame) -> pd.DataFrame:
    """Convert official IDX public Trade Detail participant rows into broker-flow rows.

    Participant codes are preserved as broker_code. This is not beneficial-owner
    identity. Buy/sell values are already present in the official Trade Detail
    aggregation, so no synthetic buy/sell split is created.
    """
    if not isinstance(frame, pd.DataFrame) or frame.empty:
        return pd.DataFrame()
    required = {"ticker", "trade_date", "participant", "buy_value", "sell_value", "buy_volume", "sell_volume"}
    if not required.issubset(frame.columns):
        return pd.DataFrame()
    out = frame.copy()
    out["broker_code"] = out["participant"].astype(str).str.strip().str.upper()
    out["market_type"] = "RG"
    out["source"] = "IDX_OFFICIAL_PUBLIC_TRADE_DETAIL_PARTICIPANT_FLOW"
    out["source_verified"] = True
    out["source_url"] = "https://www.idxdata3.co.id/IDX%20Reporting%20PSPP/Revitalisasi/Trade-Detail-Publik_{date}.csv"
    out["provenance_state"] = "VERIFIED_IDX_PUBLIC_TRADE_DETAIL_PARTICIPANT_FLOW_NOT_BENEFICIAL_OWNER"
    out["buy_avg"] = pd.to_numeric(out["buy_value"], errors="coerce").div(pd.to_numeric(out["buy_volume"], errors="coerce").replace(0.0, pd.NA))
    out["sell_avg"] = pd.to_numeric(out["sell_value"], errors="coerce").div(pd.to_numeric(out["sell_volume"], errors="coerce").replace(0.0, pd.NA))
    keep = [
        "ticker", "trade_date", "broker_code", "market_type", "buy_value", "sell_value",
        "buy_volume", "sell_volume", "buy_avg", "sell_avg", "source", "source_verified",
        "source_url", "provenance_state",
    ]
    return out[keep].drop_duplicates(["ticker", "trade_date", "broker_code", "source"], keep="last")


def _load_public_participant_broker_history(universe: list[str]) -> pd.DataFrame:
    """Load official public Trade Detail participant cache as universe-wide broker evidence."""
    try:
        cached = load_public_participant_cache(
            universe,
            PUBLIC_PARTICIPANT_CACHE,
            lookback_calendar_days=120,
        )
    except Exception:
        cached = pd.DataFrame()
    if cached.empty:
        return pd.DataFrame()
    return _participant_to_broker_rows(cached)


def _merge_prefer_direct(summary: pd.DataFrame, public_participant: pd.DataFrame) -> pd.DataFrame:
    if summary is None or summary.empty:
        return public_participant.copy()
    if public_participant is None or public_participant.empty:
        return summary.copy()
    combined = pd.concat([summary, public_participant], ignore_index=True, sort=False)
    # Direct stock-level IDX broker summary wins on exact broker/date keys;
    # public participant Trade Detail fills the missing coverage around it.
    priority = combined["source"].astype(str).str.contains("IDX_OFFICIAL_BROKER_SUMMARY", na=False).astype(int)
    combined["_source_priority"] = priority
    combined = combined.sort_values(["ticker", "trade_date", "broker_code", "_source_priority"], ascending=[True, True, True, False], kind="stable")
    combined = combined.drop_duplicates(["ticker", "trade_date", "broker_code"], keep="first")
    return combined.drop(columns=["_source_priority"], errors="ignore").reset_index(drop=True)


def main() -> int:
    universe = load_bundled_universe(UNIVERSE)
    end_date = pd.Timestamp.now(tz="Asia/Jakarta").normalize().tz_localize(None)
    while end_date.weekday() >= 5:
        end_date -= pd.Timedelta(days=1)

    existing = load_bundled_idx_official_broker_flows(universe, CACHE, lookback_calendar_days=180)
    budget = max(0, int(os.getenv("IDX_BROKER_UNIVERSE_DAILY_BUDGET", "400") or "400"))
    workers = max(1, int(os.getenv("IDX_BROKER_WORKERS", "12") or "12"))
    target_days = max(1, int(os.getenv("IDX_BROKER_TARGET_DAYS", "20") or "20"))
    max_calendar = max(target_days, int(os.getenv("IDX_BROKER_MAX_CALENDAR_DAYS", "45") or "45"))

    try:
        refreshed, stats = fetch_idx_universe_broker_history(
            universe,
            end_date=end_date.date(),
            existing=existing,
            target_trading_days=target_days,
            max_calendar_days=max_calendar,
            budget_requests=budget,
            workers=workers,
        )
    except IdxOfficialAccessBlocked as exc:
        stats = {"status": f"BLOCKED: {exc}", "requests_attempted": 0}
        refreshed = existing
    except Exception as exc:
        stats = {"status": f"ERROR: {type(exc).__name__}: {exc}", "requests_attempted": 0}
        refreshed = existing

    public_participant = _load_public_participant_broker_history(universe)
    merged = _merge_prefer_direct(refreshed, public_participant)

    if merged is not None and not merged.empty:
        CACHE.parent.mkdir(parents=True, exist_ok=True)
        merged.to_csv(CACHE, index=False, compression="gzip")

    latest = pd.to_datetime(merged.get("trade_date"), errors="coerce").max() if isinstance(merged, pd.DataFrame) and not merged.empty else pd.NaT
    meta = {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "provider": "IDX_OFFICIAL_BROKER_SUMMARY_PLUS_PUBLIC_TRADE_DETAIL_PARTICIPANT_FLOW",
        "scope": "UNIVERSE_WIDE",
        "universe_count": len(universe),
        "target_trade_date": end_date.date().isoformat(),
        "budget_requests": budget,
        "workers": workers,
        "target_history_days": target_days,
        "max_calendar_days": max_calendar,
        "public_participant_cache_path": str(PUBLIC_PARTICIPANT_CACHE),
        "public_participant_rows": int(len(public_participant)),
        "public_participant_tickers": int(public_participant["ticker"].nunique()) if not public_participant.empty else 0,
        "public_participant_latest_trade_date": str(latest.date()) if pd.notna(latest) else None,
        **stats,
    }
    META.parent.mkdir(parents=True, exist_ok=True)
    META.write_text(json.dumps(meta, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps(meta, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())