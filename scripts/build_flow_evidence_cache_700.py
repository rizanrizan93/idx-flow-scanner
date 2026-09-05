from __future__ import annotations

import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "src"
if str(SRC) not in sys.path:
    sys.path.insert(0, str(SRC))
if str(Path(__file__).resolve().parent) not in sys.path:
    sys.path.insert(0, str(Path(__file__).resolve().parent))

import build_flow_evidence_cache as flow_cache
from idx_flow_scanner.universe_700 import materialize_universe_700

BASE_UNIVERSE_PATH = ROOT / "data" / "universe" / "idx_400_syariah.csv"
UNIVERSE_700_PATH = ROOT / "data" / "universe" / "idx_700_all.csv"


def main() -> int:
    path = materialize_universe_700(
        BASE_UNIVERSE_PATH,
        api_key=os.getenv("ZAPI_KEY"),
        output_path=UNIVERSE_700_PATH,
        target_size=700,
        strict=True,
    )
    flow_cache.UNIVERSE_PATH = path
    return int(flow_cache.main())


if __name__ == "__main__":
    raise SystemExit(main())
