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

from idx_flow_scanner.evidence_700 import enrich_universe_sector_metadata
from idx_flow_scanner.universe_700 import materialize_universe_700

BASE_PATH = ROOT / "data" / "universe" / "idx_400_syariah.csv"
OUT_PATH = ROOT / "data" / "universe" / "idx_700_all.csv"
META_PATH = ROOT / "data" / "universe" / "idx_700_all.meta.json"


def main() -> int:
    previous = pd.read_csv(OUT_PATH) if OUT_PATH.exists() else pd.DataFrame()
    path = materialize_universe_700(
        BASE_PATH,
        api_key=os.getenv("ZAPI_KEY"),
        output_path=OUT_PATH,
        target_size=700,
        strict=True,
    )
    sector_meta = enrich_universe_sector_metadata(
        path,
        previous_frame=previous,
        max_web_requests=int(os.getenv("IDX700_SECTOR_WEB_FALLBACK_LIMIT", "350") or "350"),
        workers=int(os.getenv("IDX700_SECTOR_WORKERS", "8") or "8"),
    )
    frame = pd.read_csv(path)
    if len(frame) != 700 or frame["ticker"].astype(str).str.upper().nunique() != 700:
        raise RuntimeError("Materialized IDX universe must contain exactly 700 unique tickers")

    source_counts = (
        frame.get("universe_source", pd.Series(dtype=str))
        .fillna("UNKNOWN")
        .astype(str)
        .value_counts()
        .to_dict()
    )
    sector = frame.get("sector", pd.Series("UNKNOWN", index=frame.index)).fillna("UNKNOWN").astype(str)
    known_sector = int((~sector.str.upper().isin({"", "UNKNOWN", "NAN", "NONE", "NULL"})).sum())
    meta = {
        "schema_version": 4,
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "snapshot_date": str(pd.Timestamp.now(tz="Asia/Jakarta").date()),
        "target_universe_count": 700,
        "actual_universe_count": int(len(frame)),
        "unique_tickers": int(frame["ticker"].astype(str).str.upper().nunique()),
        "legacy_anchor_count": int(source_counts.get("LEGACY_400", 0)),
        "liquidity_addition_count": int(source_counts.get("IDX_ACTIVE_LIQUIDITY_ADD", 0)),
        "selection_policy": "LEGACY_400_PLUS_CURRENT_ACTIVE_IDX_RANKED_BY_TRADED_VALUE_FREQUENCY_VOLUME_AND_MARKET_RANK",
        "membership_state": "CURRENT_SNAPSHOT_ONLY_NOT_HISTORICAL_MEMBERSHIP",
        "point_in_time_historical_membership_verified": False,
        "membership_source_contract": "IDX_OFFICIAL_PRIMARY_ZAPI_SECONDARY_STOCKANALYSIS_ACTIVE_IDX_TERTIARY",
        "liquidity_source_contract": "ZAPI_STOCK_SUMMARY_IF_AVAILABLE_YAHOO_OHLCV_FALLBACK",
        "sector_enrichment_contract": "CARRY_FORWARD_VERIFIED_THEN_STOCKANALYSIS_ONLY_FOR_UNKNOWN",
        "sector_coverage_count": known_sector,
        "sector_coverage_pct": round(100.0 * known_sector / max(len(frame), 1), 2),
        "sector_enrichment": sector_meta,
        "fallback_sector_policy": "UNKNOWN_IF_UNVERIFIED_NEVER_FABRICATED",
        "zapi_quota_required_for_universe": False,
    }
    META_PATH.write_text(json.dumps(meta, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps(meta, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
