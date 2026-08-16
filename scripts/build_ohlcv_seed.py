from __future__ import annotations

import json
import sys
from datetime import datetime, timezone
from pathlib import Path

import pandas as pd

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "src"
if str(SRC) not in sys.path:
    sys.path.insert(0, str(SRC))

from idx_flow_scanner.data import fetch_yfinance_prices_batch, parse_universe

UNIVERSE_PATH = ROOT / "data" / "universe" / "idx_400_syariah.csv"
OUT_DIR = ROOT / "data" / "cache"
OUT_PATH = OUT_DIR / "idx_400_ohlcv_1y.csv.gz"
META_PATH = OUT_DIR / "ohlcv_seed_meta.json"
MIN_BARS = 80
MIN_VALID_RATIO = 0.90


def main() -> int:
    universe = parse_universe(pd.read_csv(UNIVERSE_PATH))
    if len(universe) != 400:
        raise RuntimeError(f"Expected 400 bundled tickers, got {len(universe)}")

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
    }

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    META_PATH.write_text(json.dumps(meta, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    if accepted:
        combined = pd.concat(accepted, ignore_index=True)
        combined.to_csv(OUT_PATH, index=False, compression="gzip")

    print(json.dumps({k: v for k, v in meta.items() if k != "rejected"}, indent=2))
    if valid_ratio < MIN_VALID_RATIO:
        print(f"Seed integrity gate failed: {valid_count}/{len(universe)} valid", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
