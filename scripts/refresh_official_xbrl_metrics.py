from __future__ import annotations

import argparse
import hashlib
import json
import os
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import date, datetime, timezone
from pathlib import Path
from urllib.parse import quote, urlencode, urljoin, urlsplit, urlunsplit

import pandas as pd
from curl_cffi import requests

from idx_flow_scanner.data import canonical_ticker
from idx_flow_scanner.official_xbrl import standardized_metrics

BASE = "https://block.idx.id"
API = f"{BASE}/primary/ListedCompany/GetFinancialReport"
ROOT = Path(__file__).resolve().parents[1]
UNIVERSE = ROOT / "data" / "universe" / "idx_700_all.csv"
OUTPUT = ROOT / "data" / "cache" / "idx_official_financial_metrics_latest.csv.gz"
META = ROOT / "data" / "cache" / "idx_official_financial_metrics_latest.meta.json"
PERIOD_RANK = {"AUDIT": 0, "TW1": 1, "TW2": 2, "TW3": 3}


def _official_url(path: str) -> str:
    parts = urlsplit(urljoin(BASE + "/", str(path or "").lstrip("/")))
    if parts.scheme != "https" or (parts.hostname or "").lower() != "block.idx.id":
        raise ValueError("official XBRL file must resolve to block.idx.id")
    return urlunsplit((parts.scheme, parts.netloc, quote(parts.path, safe="/%:@-._~!$&'()*+,;="), parts.query, ""))


def _get_report_index(year: int, period: str) -> list[dict[str, object]]:
    params = {
        "periode": period if period != "AUDIT" else "audit",
        "year": year,
        "indexFrom": 0,
        "pageSize": 1500,
        "reportType": "rdf",
        "kodeEmiten": "",
    }
    response = requests.get(
        f"{API}?{urlencode(params)}",
        impersonate="chrome",
        timeout=60,
        headers={"Accept": "application/json, text/plain, */*", "Referer": BASE + "/"},
    )
    if response.status_code != 200:
        raise RuntimeError(f"GetFinancialReport {year} {period}: HTTP {response.status_code}")
    payload = response.json()
    rows = payload.get("Results") or []
    count = int(payload.get("ResultCount") or 0)
    if count > 1500 or len(rows) != count:
        raise RuntimeError(f"incomplete financial index {year} {period}: count={count} rows={len(rows)}")
    return [row for row in rows if isinstance(row, dict)]


def _instance_attachment(row: dict[str, object]) -> dict[str, object] | None:
    attachments = row.get("Attachments") or []
    if not isinstance(attachments, list):
        return None
    matches = [a for a in attachments if isinstance(a, dict) and str(a.get("File_Name") or "").strip().lower() == "instance.zip"]
    return matches[0] if len(matches) == 1 else None


def _latest_index(universe: set[str]) -> dict[str, dict[str, object]]:
    today = date.today()
    candidates = [
        (today.year - 1, "AUDIT"),
        (today.year, "TW1"),
        (today.year, "TW2"),
        (today.year, "TW3"),
    ]
    latest: dict[str, dict[str, object]] = {}
    for year, period in candidates:
        for row in _get_report_index(year, period):
            ticker = canonical_ticker(row.get("KodeEmiten"))
            if not ticker or ticker not in universe:
                continue
            attachment = _instance_attachment(row)
            if not attachment:
                continue
            item = {
                "ticker": ticker,
                "report_year": int(row.get("Report_Year") or year),
                "report_period": str(row.get("Report_Period") or period).upper(),
                "file_modified": row.get("File_Modified"),
                "issuer_name": row.get("NamaEmiten"),
                "instance_file_id": attachment.get("File_ID"),
                "instance_path": attachment.get("File_Path"),
                "instance_size_bytes": int(attachment.get("File_Size") or 0),
            }
            key = (item["report_year"], PERIOD_RANK.get(item["report_period"], -1))
            previous = latest.get(ticker)
            previous_key = (previous["report_year"], PERIOD_RANK.get(previous["report_period"], -1)) if previous else (-1, -1)
            if key > previous_key:
                latest[ticker] = item
    return latest


def _download_parse(item: dict[str, object]) -> dict[str, object]:
    url = _official_url(str(item["instance_path"]))
    response = requests.get(
        url,
        impersonate="chrome",
        timeout=60,
        headers={"Accept": "application/zip, application/octet-stream, */*", "Referer": BASE + "/"},
    )
    content = bytes(response.content)
    expected = int(item.get("instance_size_bytes") or 0)
    if response.status_code != 200:
        raise RuntimeError(f"HTTP {response.status_code}")
    if not content.startswith(b"PK"):
        raise RuntimeError("invalid ZIP magic")
    if expected <= 0 or len(content) != expected:
        raise RuntimeError(f"size mismatch expected={expected} actual={len(content)}")
    metrics = standardized_metrics(content)
    return {
        **item,
        **metrics,
        "source_file_sha256": hashlib.sha256(content).hexdigest(),
        "source_file_size_bytes": len(content),
        "source_url": url,
        "source": "IDX_OFFICIAL_XBRL_INSTANCE",
        "source_verified": True,
        "provenance_state": "VERIFIED_OFFICIAL_IDX_XBRL_STANDARDIZED_METRICS",
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--limit", type=int, default=0)
    parser.add_argument("--workers", type=int, default=8)
    args = parser.parse_args()

    frame = pd.read_csv(UNIVERSE)
    ticker_col = "ticker" if "ticker" in frame.columns else frame.columns[0]
    universe_list = [canonical_ticker(v) for v in frame[ticker_col].tolist()]
    universe_list = list(dict.fromkeys(t for t in universe_list if t))
    universe = set(universe_list)
    latest = _latest_index(universe)
    targets = [latest[t] for t in universe_list if t in latest]
    if args.limit > 0:
        targets = targets[: args.limit]

    rows: list[dict[str, object]] = []
    failures: list[dict[str, str]] = []
    workers = max(1, min(int(args.workers), 12))
    with ThreadPoolExecutor(max_workers=workers) as executor:
        futures = {executor.submit(_download_parse, item): item for item in targets}
        for future in as_completed(futures):
            item = futures[future]
            try:
                rows.append(future.result())
            except Exception as exc:
                failures.append({"ticker": str(item["ticker"]), "error": f"{type(exc).__name__}: {exc}"})

    rows.sort(key=lambda r: str(r["ticker"]))
    out = pd.DataFrame(rows)
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    out.to_csv(OUTPUT, index=False, compression="gzip")
    validated = int(out["metric_validation_state"].astype(str).str.startswith("VALIDATED").sum()) if not out.empty else 0
    meta = {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "source": "IDX_OFFICIAL_BLOCK_GETFINANCIALREPORT_AND_INSTANCE_ZIP",
        "universe_count": len(universe_list),
        "target_count": len(targets),
        "success_count": len(rows),
        "validated_count": validated,
        "failure_count": len(failures),
        "failures": failures[:100],
    }
    META.write_text(json.dumps(meta, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({k: v for k, v in meta.items() if k != "failures"}, indent=2))
    if len(rows) < max(1, int(len(targets) * 0.90)):
        raise SystemExit(f"XBRL success coverage too low: {len(rows)}/{len(targets)}")


if __name__ == "__main__":
    main()
