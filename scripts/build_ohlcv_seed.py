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

from idx_flow_scanner.data import fetch_yfinance_prices_batch, parse_universe
from idx_flow_scanner.evidence_700 import enrich_universe_sector_metadata
from idx_flow_scanner.universe_700 import materialize_universe_700

BASE_UNIVERSE_PATH = ROOT / "data" / "universe" / "idx_400_syariah.csv"
UNIVERSE_PATH = ROOT / "data" / "universe" / "idx_700_all.csv"
OUT_DIR = ROOT / "data" / "cache"
OUT_PATH = OUT_DIR / "idx_700_ohlcv_1y.csv.gz"
META_PATH = OUT_DIR / "ohlcv_seed_meta.json"
RECENT_JSON_PATH = OUT_DIR / "idx_700_ohlcv_recent.json"
MIN_BARS = 80
MIN_VALID_RATIO = 0.90
RECENT_MIRROR_BARS = 10
TARGET_UNIVERSE_COUNT = 700


def main() -> int:
    previous_universe = (
        pd.read_csv(UNIVERSE_PATH)
        if UNIVERSE_PATH.exists()
        else pd.DataFrame()
    )
    materialize_universe_700(
        BASE_UNIVERSE_PATH,
        api_key=os.getenv("ZAPI_KEY"),
        output_path=UNIVERSE_PATH,
        target_size=TARGET_UNIVERSE_COUNT,
        strict=True,
    )
    sector_meta = enrich_universe_sector_metadata(
        UNIVERSE_PATH,
        previous_frame=previous_universe,
        max_web_requests=int(os.getenv("IDX700_SECTOR_WEB_FALLBACK_LIMIT", "350") or "350"),
        workers=int(os.getenv("IDX700_SECTOR_WORKERS", "8") or "8"),
    )
    universe = parse_universe(pd.read_csv(UNIVERSE_PATH))
    if len(universe) != TARGET_UNIVERSE_COUNT:
        raise RuntimeError(
            f"Expected {TARGET_UNIVERSE_COUNT} bundled tickers, got {len(universe)}"
        )

    frames = fetch_yfinance_prices_batch(
        universe,
        period="1y",
        chunk_size=30,
        retries=3,
        inter_chunk_delay_seconds=2.5,
        retry_backoff_seconds=10.0,
    )

    accepted = []
    rejected = []
    latest_dates = []
    for ticker in universe:
        frame = frames.get(ticker, pd.DataFrame())
        if len(frame) < MIN_BARS:
            rejected.append({"ticker": ticker, "bars": int(len(frame))})
            continue
        clean = frame[["ticker", "date", "open", "high", "low", "close", "volume"]].copy()
        clean["date"] = pd.to_datetime(clean["date"]).dt.date.astype(str)
        accepted.append(clean)
        latest_dates.append(clean["date"].max())

    valid_count = len(accepted)
    valid_ratio = valid_count / len(universe)
    meta = {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "period": "1y",
        "universe_count": len(universe),
        "valid_tickers": valid_count,
        "valid_ratio": valid_ratio,
        "minimum_bars": MIN_BARS,
        "latest_trade_date": max(latest_dates) if latest_dates else None,
        "rejected": rejected,
        "source": "Yahoo Finance public chart/download endpoints",
        "sector_coverage_count": int(sector_meta.get("known", 0)),
        "sector_coverage_pct": float(sector_meta.get("coverage_pct", 0.0) or 0.0),
        "sector_enrichment": sector_meta,
    }

    print(json.dumps({k: v for k, v in meta.items() if k != "rejected"}, indent=2))
    if valid_ratio < MIN_VALID_RATIO or not accepted:
        print(
            f"Seed integrity gate failed: {valid_count}/{len(universe)} valid; tracked seed preserved",
            file=sys.stderr,
        )
        return 2

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    tmp_data = OUT_PATH.with_name(OUT_PATH.name + ".tmp")
    tmp_meta = META_PATH.with_name(META_PATH.name + ".tmp")
    tmp_recent = RECENT_JSON_PATH.with_name(RECENT_JSON_PATH.name + ".tmp")
    combined = pd.concat(accepted, ignore_index=True)
    combined.to_csv(tmp_data, index=False, compression="gzip")

    recent = (
        combined.sort_values(["ticker", "date"], kind="stable")
        .groupby("ticker", group_keys=False)
        .tail(RECENT_MIRROR_BARS)
        .reset_index(drop=True)
    )
    recent["date"] = pd.to_datetime(recent["date"], errors="raise").dt.strftime("%Y-%m-%d")
    tmp_recent.write_text(
        recent[["ticker", "date", "open", "high", "low", "close", "volume"]]
        .to_json(orient="records", double_precision=15)
        + "\n",
        encoding="utf-8",
    )
    meta["recent_mirror_rows"] = int(len(recent))
    meta["recent_mirror_bars_per_ticker"] = RECENT_MIRROR_BARS
    tmp_meta.write_text(json.dumps(meta, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    tmp_data.replace(OUT_PATH)
    tmp_recent.replace(RECENT_JSON_PATH)
    tmp_meta.replace(META_PATH)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
