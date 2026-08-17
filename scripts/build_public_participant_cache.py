from __future__ import annotations

import os
from datetime import datetime, timezone
from pathlib import Path
import json
import sys

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "src"
if str(SRC) not in sys.path:
    sys.path.insert(0, str(SRC))

from idx_flow_scanner.managed import load_bundled_universe
from idx_flow_scanner.providers.public_idx_participant import (
    collect_recent_days,
    load_cache,
    write_cache,
)

UNIVERSE_PATH = ROOT / "data" / "universe" / "idx_400_syariah.csv"
CACHE_PATH = ROOT / "data" / "cache" / "idx_public_participant_30d.csv.gz"
META_PATH = ROOT / "data" / "cache" / "public_participant_meta.json"


def _latest_weekday() -> object:
    import pandas as pd
    day = pd.Timestamp.now(tz="Asia/Jakarta").normalize().tz_localize(None)
    while day.weekday() >= 5:
        day -= pd.Timedelta(days=1)
    return day.date()


def main() -> int:
    universe = load_bundled_universe(UNIVERSE_PATH)
    end_date = _latest_weekday()
    existing = load_cache(universe, CACHE_PATH, lookback_calendar_days=90)
    target_days = max(1, int(os.getenv("IDX_PUBLIC_PARTICIPANT_TARGET_DAYS", "20") or "20"))
    max_days = max(target_days, int(os.getenv("IDX_PUBLIC_PARTICIPANT_MAX_CALENDAR_DAYS", "45") or "45"))

    # Bootstrap 20 trading days if the cache is absent/short; otherwise refresh only
    # the latest trading day to avoid repeated public-data downloads.
    existing_dates = set(existing["trade_date"].dropna().dt.date) if not existing.empty else set()
    incremental = len(existing_dates) >= target_days
    fresh, telemetry = collect_recent_days(
        universe,
        end_date=end_date,
        target_trading_days=1 if incremental else target_days,
        max_calendar_days=7 if incremental else max_days,
    )
    import pandas as pd
    merged = pd.concat([existing, fresh], ignore_index=True) if not existing.empty else fresh
    if not merged.empty:
        merged["trade_date"] = pd.to_datetime(merged["trade_date"], errors="coerce").dt.normalize()
        merged = merged.drop_duplicates(["ticker", "trade_date", "participant", "side", "flow_rank"], keep="last")
        cutoff = pd.Timestamp(end_date) - pd.Timedelta(days=45)
        merged = merged[merged["trade_date"].ge(cutoff)].sort_values(
            ["ticker", "trade_date", "side", "flow_rank", "participant"], kind="stable"
        ).reset_index(drop=True)
        write_cache(merged, CACHE_PATH)

    meta = {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "universe_count": len(universe),
        "target_trade_date": str(end_date),
        "cache_rows": int(len(merged)) if not merged.empty else 0,
        "cache_tickers": int(merged["ticker"].nunique()) if not merged.empty else 0,
        "cache_days": int(merged["trade_date"].nunique()) if not merged.empty else 0,
        "mode": "INCREMENTAL_1D" if incremental else "BOOTSTRAP",
        **telemetry,
    }
    META_PATH.parent.mkdir(parents=True, exist_ok=True)
    META_PATH.write_text(json.dumps(meta, indent=2, default=str) + "\n", encoding="utf-8")
    print(json.dumps(meta, indent=2, default=str))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
