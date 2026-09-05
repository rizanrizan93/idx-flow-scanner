from __future__ import annotations

import json
import sys
from pathlib import Path

import pandas as pd

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "src"
if str(SRC) not in sys.path:
    sys.path.insert(0, str(SRC))

from idx_flow_scanner.slow_evidence_store import (
    normalize_capital_actions,
    normalize_ownership,
    normalize_stock_summary,
)

CACHE = ROOT / "data" / "cache"
UNIVERSE = ROOT / "data" / "universe"


def _write(frame: pd.DataFrame, path: Path) -> int:
    path.parent.mkdir(parents=True, exist_ok=True)
    if frame is None or frame.empty:
        path.write_text("[]\n", encoding="utf-8")
        return 0
    out = frame.copy()
    for column in out.columns:
        if pd.api.types.is_datetime64_any_dtype(out[column]):
            out[column] = pd.to_datetime(out[column], errors="coerce").dt.strftime("%Y-%m-%d")
    payload = json.loads(out.to_json(orient="records", double_precision=15, date_format="iso"))
    path.write_text(
        json.dumps(payload, separators=(",", ":"), ensure_ascii=True, allow_nan=False) + "\n",
        encoding="utf-8",
    )
    return int(len(out))


def _read(path: Path) -> pd.DataFrame:
    if not path.exists():
        return pd.DataFrame()
    try:
        return pd.read_csv(path)
    except Exception:
        return pd.DataFrame()


def export() -> dict[str, object]:
    stock = normalize_stock_summary(_read(CACHE / "zapi_stock_summary_latest.csv.gz"))
    ownership = normalize_ownership(_read(CACHE / "zapi_ownership_latest.csv.gz"))
    actions = normalize_capital_actions(_read(CACHE / "zapi_capital_actions.csv.gz"))

    universe = _read(UNIVERSE / "idx_700_all.csv")
    if not universe.empty:
        universe.columns = [str(column).strip().lower() for column in universe.columns]
        keep = [column for column in ("ticker", "sector") if column in universe.columns]
        universe = universe[keep].copy() if keep else pd.DataFrame()
        if not universe.empty:
            universe["ticker"] = universe["ticker"].fillna("").astype(str).str.strip().str.upper()
            if "sector" not in universe.columns:
                universe["sector"] = "UNKNOWN"
            universe["sector"] = universe["sector"].fillna("UNKNOWN").astype(str).str.strip()
            universe = universe[universe["ticker"].str.fullmatch(r"[A-Z0-9]{1,10}", na=False)]
            universe["active"] = True
            universe = universe.drop_duplicates("ticker", keep="last").sort_values("ticker", kind="stable")

    stats = {
        "stock_summary_rows": _write(stock, CACHE / "zapi_stock_summary_latest.json"),
        "ownership_rows": _write(ownership, CACHE / "zapi_ownership_latest.json"),
        "capital_action_rows": _write(actions, CACHE / "zapi_capital_actions.json"),
        "universe_rows": _write(universe, UNIVERSE / "idx_700_all.json"),
        "no_fabricated_evidence": True,
    }
    print(json.dumps(stats, indent=2, sort_keys=True))
    return stats


if __name__ == "__main__":
    export()
