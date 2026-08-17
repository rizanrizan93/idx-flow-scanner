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

UNIVERSE = ROOT / "data" / "universe" / "idx_400_syariah.csv"
CACHE = ROOT / "data" / "cache" / "idx_official_broker_60d.csv.gz"
META = ROOT / "data" / "cache" / "idx_official_broker_meta.json"


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
        merged, stats = fetch_idx_universe_broker_history(
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
        merged = existing
    except Exception as exc:
        stats = {"status": f"ERROR: {type(exc).__name__}: {exc}", "requests_attempted": 0}
        merged = existing

    if merged is not None and not merged.empty:
        CACHE.parent.mkdir(parents=True, exist_ok=True)
        merged.to_csv(CACHE, index=False, compression="gzip")

    meta = {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "provider": "IDX_OFFICIAL_BROKER_SUMMARY",
        "scope": "UNIVERSE_WIDE",
        "universe_count": len(universe),
        "target_trade_date": end_date.date().isoformat(),
        "budget_requests": budget,
        "workers": workers,
        "target_history_days": target_days,
        "max_calendar_days": max_calendar,
        **stats,
    }
    META.parent.mkdir(parents=True, exist_ok=True)
    META.write_text(json.dumps(meta, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps(meta, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
