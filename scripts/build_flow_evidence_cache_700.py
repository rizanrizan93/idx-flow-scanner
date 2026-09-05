from __future__ import annotations

import json
import math
import os
import sys
from pathlib import Path

import pandas as pd

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "src"
if str(SRC) not in sys.path:
    sys.path.insert(0, str(SRC))
if str(Path(__file__).resolve().parent) not in sys.path:
    sys.path.insert(0, str(Path(__file__).resolve().parent))

import build_flow_evidence_cache as flow_cache
from idx_flow_scanner.evidence_700 import (
    enrich_universe_sector_metadata,
    write_evidence_coverage_report,
)
from idx_flow_scanner.universe_700 import materialize_universe_700

BASE_UNIVERSE_PATH = ROOT / "data" / "universe" / "idx_400_syariah.csv"
UNIVERSE_700_PATH = ROOT / "data" / "universe" / "idx_700_all.csv"


def _existing_ownership_tickers(universe: list[str]) -> set[str]:
    frame = flow_cache.load_bundled_zapi_ownership(
        universe,
        flow_cache.ZAPI_OWNERSHIP_CACHE,
    )
    if frame is None or frame.empty or "ticker" not in frame.columns:
        return set()
    return {
        str(value).strip().upper()
        for value in frame["ticker"].dropna().tolist()
        if str(value).strip()
    }


def _install_uncovered_first_ownership_policy() -> dict[str, object]:
    original_selector = flow_cache._ownership_profile_candidates
    target_ratio = min(
        1.0,
        max(0.0, float(os.getenv("ZAPI_OWNERSHIP_TARGET_COVERAGE", "0.90") or "0.90")),
    )
    os.environ.setdefault("ZAPI_OWNERSHIP_PROFILE_FALLBACK_LIMIT", "60")

    def selector(
        universe: list[str],
        foreign: pd.DataFrame,
        stock: pd.DataFrame,
        *,
        limit: int,
    ) -> list[str]:
        names = [str(t).strip().upper() for t in universe if str(t).strip()]
        cap = max(1, int(limit))
        covered = _existing_ownership_tickers(names)
        target_count = int(math.ceil(len(names) * target_ratio))
        if len(covered) >= target_count:
            return original_selector(names, foreign, stock, limit=cap)

        uncovered = [ticker for ticker in names if ticker not in covered]
        selected = original_selector(uncovered, foreign, stock, limit=min(cap, len(uncovered)))
        if len(selected) < cap:
            selected_set = set(selected)
            covered_names = [ticker for ticker in names if ticker in covered and ticker not in selected_set]
            selected.extend(
                original_selector(
                    covered_names,
                    foreign,
                    stock,
                    limit=min(cap - len(selected), len(covered_names)),
                )
            )
        return selected[:cap]

    flow_cache._ownership_profile_candidates = selector
    return {
        "target_ratio": target_ratio,
        "profile_batch_limit": int(os.getenv("ZAPI_OWNERSHIP_PROFILE_FALLBACK_LIMIT", "60") or "60"),
    }


def _install_per_ticker_ownership_retention() -> None:
    def merge(existing: pd.DataFrame, fresh: pd.DataFrame) -> pd.DataFrame:
        parts = [frame.copy() for frame in (existing, fresh) if frame is not None and not frame.empty]
        if not parts:
            return pd.DataFrame()
        out = pd.concat(parts, ignore_index=True)
        out["report_date"] = pd.to_datetime(out.get("report_date"), errors="coerce").dt.normalize()
        out = out.dropna(subset=["ticker", "report_date"])
        out["ticker"] = out["ticker"].astype(str).str.strip().str.upper()
        keys = ["category", "report_date", "ticker", "holder_identity_hash"]
        out = out.drop_duplicates([key for key in keys if key in out.columns], keep="last")

        group_cols = ["ticker"]
        if "category" in out.columns:
            group_cols.append("category")
        kept: list[pd.DataFrame] = []
        for _, group in out.groupby(group_cols, observed=True, dropna=False):
            dates = sorted(group["report_date"].dropna().unique(), reverse=True)[:3]
            kept.append(group[group["report_date"].isin(dates)].copy())
        merged = pd.concat(kept, ignore_index=True) if kept else pd.DataFrame()
        if merged.empty:
            return merged
        merged["report_date"] = pd.to_datetime(merged["report_date"]).dt.strftime("%Y-%m-%d")
        sort_cols = [col for col in ("category", "ticker", "report_date") if col in merged.columns]
        return merged.sort_values(sort_cols, kind="stable").reset_index(drop=True)

    flow_cache._merge_ownership = merge


def main() -> int:
    previous_universe = (
        pd.read_csv(UNIVERSE_700_PATH)
        if UNIVERSE_700_PATH.exists()
        else pd.DataFrame()
    )
    path = materialize_universe_700(
        BASE_UNIVERSE_PATH,
        api_key=os.getenv("ZAPI_KEY"),
        output_path=UNIVERSE_700_PATH,
        target_size=700,
        strict=True,
    )
    sector_meta = enrich_universe_sector_metadata(
        path,
        previous_frame=previous_universe,
        max_web_requests=int(os.getenv("IDX700_SECTOR_WEB_FALLBACK_LIMIT", "350") or "350"),
        workers=int(os.getenv("IDX700_SECTOR_WORKERS", "8") or "8"),
    )

    flow_cache.UNIVERSE_PATH = path
    ownership_policy = _install_uncovered_first_ownership_policy()
    _install_per_ticker_ownership_retention()

    universe = flow_cache.load_bundled_universe(path)
    covered = _existing_ownership_tickers(universe)
    target_count = int(math.ceil(len(universe) * float(ownership_policy["target_ratio"])))
    if len(covered) < target_count:
        os.environ["ZAPI_FORCE_SLOW_REFRESH"] = "1"

    result = int(flow_cache.main())
    coverage = write_evidence_coverage_report(path)
    print(
        json.dumps(
            {
                "sector_enrichment": sector_meta,
                "ownership_backfill_policy": {
                    **ownership_policy,
                    "covered_before_run": len(covered),
                    "target_tickers": target_count,
                    "forced_until_target": len(covered) < target_count,
                },
                "evidence_coverage": coverage,
            },
            indent=2,
            sort_keys=True,
            default=str,
        )
    )
    return result


if __name__ == "__main__":
    raise SystemExit(main())
