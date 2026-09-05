from __future__ import annotations

import json
import os
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone
from pathlib import Path

import pandas as pd

from .data import canonical_ticker

ROOT = Path(__file__).resolve().parents[2]
DEFAULT_UNIVERSE = ROOT / "data" / "universe" / "idx_700_all.csv"
DEFAULT_CACHE_DIR = ROOT / "data" / "cache"
COVERAGE_PATH = DEFAULT_CACHE_DIR / "idx_700_evidence_coverage.json"
STOCKANALYSIS_QUOTE_URL = "https://stockanalysis.com/quote/idx/{ticker}/"

_CANONICAL_SECTORS = {
    "energy": "Energy",
    "energi": "Energy",
    "basic materials": "Basic Materials",
    "materials": "Basic Materials",
    "barang baku": "Basic Materials",
    "industrials": "Industrials",
    "industrial": "Industrials",
    "perindustrian": "Industrials",
    "consumer non-cyclicals": "Consumer Non-Cyclicals",
    "consumer defensive": "Consumer Non-Cyclicals",
    "consumer staples": "Consumer Non-Cyclicals",
    "barang konsumen primer": "Consumer Non-Cyclicals",
    "consumer cyclicals": "Consumer Cyclicals",
    "consumer cyclical": "Consumer Cyclicals",
    "consumer discretionary": "Consumer Cyclicals",
    "barang konsumen non-primer": "Consumer Cyclicals",
    "healthcare": "Healthcare",
    "kesehatan": "Healthcare",
    "financials": "Financials",
    "financial services": "Financials",
    "keuangan": "Financials",
    "properties & real estate": "Properties & Real Estate",
    "real estate": "Properties & Real Estate",
    "properti & real estat": "Properties & Real Estate",
    "properti dan real estat": "Properties & Real Estate",
    "technology": "Technology",
    "teknologi": "Technology",
    "infrastructures": "Infrastructures",
    "infrastruktur": "Infrastructures",
    "communication services": "Infrastructures",
    "utilities": "Infrastructures",
    "transportation & logistic": "Transportation & Logistic",
    "transportation": "Transportation & Logistic",
    "transportasi & logistik": "Transportation & Logistic",
    "transportasi dan logistik": "Transportation & Logistic",
}


def _canonical_sector(value: object) -> str:
    text = str(value or "").strip()
    if not text or text.lower() in {"unknown", "nan", "none", "null"}:
        return "UNKNOWN"
    return _CANONICAL_SECTORS.get(text.lower(), "UNKNOWN")


def _read_csv(path: Path) -> pd.DataFrame:
    if not path.exists():
        return pd.DataFrame()
    try:
        frame = pd.read_csv(path)
    except Exception:
        return pd.DataFrame()
    frame.columns = [str(c).strip().lower() for c in frame.columns]
    if "ticker" in frame.columns:
        frame["ticker"] = frame["ticker"].map(canonical_ticker)
    return frame


def _fetch_stockanalysis_sector(ticker: str, *, timeout: float = 20.0) -> tuple[str, str | None]:
    from bs4 import BeautifulSoup
    from curl_cffi import requests as curl_requests

    symbol = canonical_ticker(ticker)
    if not symbol:
        return "", None
    try:
        response = curl_requests.get(
            STOCKANALYSIS_QUOTE_URL.format(ticker=symbol),
            headers={
                "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
                "Accept-Language": "en-US,en;q=0.9",
            },
            impersonate="chrome",
            timeout=timeout,
        )
        if response.status_code != 200:
            return symbol, None
        soup = BeautifulSoup(response.text, "html.parser")
        lines = [line.strip() for line in soup.get_text("\n", strip=True).splitlines() if line.strip()]
        for index, line in enumerate(lines[:-1]):
            if line.lower() != "sector":
                continue
            sector = _canonical_sector(lines[index + 1])
            if sector != "UNKNOWN":
                return symbol, sector
    except Exception:
        return symbol, None
    return symbol, None


def enrich_universe_sector_metadata(
    universe_path: Path = DEFAULT_UNIVERSE,
    *,
    previous_frame: pd.DataFrame | None = None,
    max_web_requests: int | None = None,
    workers: int = 8,
) -> dict[str, object]:
    """Fill missing sector metadata without fabricating classifications.

    Existing verified sectors are carried forward first. Only UNKNOWN rows are
    queried from StockAnalysis company pages; values are accepted only when they
    map to the scanner's canonical IDX sector groups.
    """
    path = Path(universe_path)
    frame = _read_csv(path)
    if frame.empty or "ticker" not in frame.columns:
        return {"status": "NO_UNIVERSE", "known": 0, "unknown": 0, "requests": 0, "resolved": 0}
    if "sector" not in frame.columns:
        frame["sector"] = "UNKNOWN"
    frame["sector"] = frame["sector"].map(_canonical_sector)

    previous = previous_frame.copy() if previous_frame is not None else pd.DataFrame()
    if not previous.empty:
        previous.columns = [str(c).strip().lower() for c in previous.columns]
        if {"ticker", "sector"}.issubset(previous.columns):
            previous["ticker"] = previous["ticker"].map(canonical_ticker)
            previous["sector"] = previous["sector"].map(_canonical_sector)
            known_previous = previous[previous["sector"].ne("UNKNOWN")].drop_duplicates("ticker", keep="last")
            prior_map = dict(zip(known_previous["ticker"], known_previous["sector"]))
            unknown_mask = frame["sector"].eq("UNKNOWN")
            frame.loc[unknown_mask, "sector"] = frame.loc[unknown_mask, "ticker"].map(prior_map).fillna("UNKNOWN")

    unknown = frame.loc[frame["sector"].eq("UNKNOWN"), "ticker"].drop_duplicates().tolist()
    request_cap = max_web_requests
    if request_cap is None:
        request_cap = int(os.getenv("IDX700_SECTOR_WEB_FALLBACK_LIMIT", "350") or "350")
    candidates = unknown[: max(0, int(request_cap))]

    resolved: dict[str, str] = {}
    if candidates:
        with ThreadPoolExecutor(max_workers=max(1, min(int(workers), 12))) as pool:
            futures = {pool.submit(_fetch_stockanalysis_sector, ticker): ticker for ticker in candidates}
            for future in as_completed(futures):
                try:
                    ticker, sector = future.result()
                except Exception:
                    continue
                if ticker and sector:
                    resolved[ticker] = sector
    if resolved:
        mask = frame["ticker"].isin(resolved)
        frame.loc[mask, "sector"] = frame.loc[mask, "ticker"].map(resolved).fillna(frame.loc[mask, "sector"])

    frame.to_csv(path, index=False)
    known = int(frame["sector"].ne("UNKNOWN").sum())
    return {
        "status": "UPDATED" if resolved else "PRESERVED",
        "known": known,
        "unknown": int(len(frame) - known),
        "coverage_pct": round(100.0 * known / max(len(frame), 1), 2),
        "requests": int(len(candidates)),
        "resolved": int(len(resolved)),
        "source": "STOCKANALYSIS_PROFILE_FALLBACK_ONLY_FOR_UNKNOWN",
    }


def _ticker_set(frame: pd.DataFrame) -> set[str]:
    if frame.empty or "ticker" not in frame.columns:
        return set()
    return {canonical_ticker(value) for value in frame["ticker"] if canonical_ticker(value)}


def _pct(count: int, total: int) -> float:
    return round(100.0 * int(count) / max(int(total), 1), 2)


def _json(path: Path) -> dict[str, object]:
    if not path.exists():
        return {}
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
        return payload if isinstance(payload, dict) else {}
    except Exception:
        return {}


def write_evidence_coverage_report(
    universe_path: Path = DEFAULT_UNIVERSE,
    *,
    cache_dir: Path = DEFAULT_CACHE_DIR,
    output_path: Path = COVERAGE_PATH,
) -> dict[str, object]:
    """Measure real 700-ticker evidence coverage from persisted cache contents."""
    universe = _read_csv(Path(universe_path))
    names = _ticker_set(universe)
    total = len(names)

    ohlcv = _read_csv(Path(cache_dir) / "idx_700_ohlcv_1y.csv.gz")
    foreign = _read_csv(Path(cache_dir) / "zapi_idx_foreign_60d.csv.gz")
    stock = _read_csv(Path(cache_dir) / "zapi_stock_summary_latest.csv.gz")
    ownership = _read_csv(Path(cache_dir) / "zapi_ownership_latest.csv.gz")
    actions = _read_csv(Path(cache_dir) / "zapi_capital_actions.csv.gz")
    flow_meta = _json(Path(cache_dir) / "flow_evidence_meta.json")

    ohlcv_names = _ticker_set(ohlcv) & names
    foreign_names = _ticker_set(foreign) & names
    stock_names = _ticker_set(stock) & names
    ownership_names = _ticker_set(ownership) & names
    action_names = _ticker_set(actions) & names

    free_float_names: set[str] = set()
    if not stock.empty and {"ticker", "listed_shares", "tradable_shares"}.issubset(stock.columns):
        listed = pd.to_numeric(stock["listed_shares"], errors="coerce")
        tradable = pd.to_numeric(stock["tradable_shares"], errors="coerce")
        valid = listed.gt(0) & tradable.gt(0) & tradable.le(listed * 1.05)
        free_float_names = _ticker_set(stock.loc[valid]) & names

    sector_names: set[str] = set()
    if not universe.empty and {"ticker", "sector"}.issubset(universe.columns):
        known = ~universe["sector"].fillna("UNKNOWN").astype(str).str.upper().isin({"", "UNKNOWN", "NAN", "NONE", "NULL"})
        sector_names = _ticker_set(universe.loc[known]) & names

    core = names & ohlcv_names & foreign_names & free_float_names & sector_names
    full = core & ownership_names
    missing_core = sorted(names - core)
    missing_full = sorted(names - full)

    report = {
        "schema_version": 1,
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "universe_count": total,
        "coverage": {
            "ohlcv": {"tickers": len(ohlcv_names), "pct": _pct(len(ohlcv_names), total)},
            "sector": {"tickers": len(sector_names), "pct": _pct(len(sector_names), total)},
            "foreign_flow": {"tickers": len(foreign_names), "pct": _pct(len(foreign_names), total)},
            "stock_summary": {"tickers": len(stock_names), "pct": _pct(len(stock_names), total)},
            "free_float": {"tickers": len(free_float_names), "pct": _pct(len(free_float_names), total)},
            "ownership": {"tickers": len(ownership_names), "pct": _pct(len(ownership_names), total)},
            "corporate_action_events": {
                "tickers_with_events": len(action_names),
                "semantics": "EVENT_DRIVEN_MARKET_WIDE_FEED_NOT_EXPECTED_FOR_EVERY_TICKER",
            },
            "core_complete": {"tickers": len(core), "pct": _pct(len(core), total)},
            "full_complete_including_ownership": {"tickers": len(full), "pct": _pct(len(full), total)},
        },
        "provider_status": {
            "foreign_flow": (flow_meta.get("zapi_idx_foreign") or {}).get("status") if isinstance(flow_meta.get("zapi_idx_foreign"), dict) else None,
            "stock_summary": (flow_meta.get("zapi_stock_summary") or {}).get("status") if isinstance(flow_meta.get("zapi_stock_summary"), dict) else None,
            "ownership": (flow_meta.get("zapi_ownership") or {}).get("status") if isinstance(flow_meta.get("zapi_ownership"), dict) else None,
            "capital_actions": (flow_meta.get("zapi_capital_actions") or {}).get("status") if isinstance(flow_meta.get("zapi_capital_actions"), dict) else None,
        },
        "missing_core_sample": missing_core[:80],
        "missing_full_sample": missing_full[:80],
        "readiness_contract": {
            "core_target_pct": 95.0,
            "ownership_target_pct": 90.0,
            "no_fabricated_evidence": True,
        },
    }
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return report
