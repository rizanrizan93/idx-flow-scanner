from __future__ import annotations

import argparse
import json
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

from idx_flow_scanner.providers.block_idx_evidence import download_official_idx_attachment
from idx_flow_scanner.providers.block_idx_financial_facts import (
    METRIC_CATALOG,
    METRIC_CATALOG_SHA256,
    extract_financial_facts_from_xbrl_zip,
)
from idx_flow_scanner.providers.block_idx_financial_locator import (
    resolve_exact_current_report_attachment,
)

WIB = ZoneInfo("Asia/Jakarta")
DEFAULT_SOURCE = Path("data/cache/evidence_v5/block_idx_historical_financial_filings.json")
DEFAULT_OUTPUT = Path("data/cache/evidence_v5/block_idx_financial_facts.json")
CACHE_SCHEMA = "BLOCK_IDX_FINANCIAL_FACT_CACHE_V5_2"
PARSER_CONTRACT = "EXACT_IDX_CORE_TAXONOMY_SINGLE_CURRENCY_CURRENT_UNDIMENSIONED_YTD_OR_INSTANT_V5_2"


def _load_filings(path: Path) -> list[dict[str, object]]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    rows = payload.get("rows") if isinstance(payload, dict) else None
    if not isinstance(rows, list):
        raise ValueError("historical financial filing cache has no rows array")
    return [row for row in rows if isinstance(row, dict)]


def _eligible_instances(rows: list[dict[str, object]]) -> list[dict[str, object]]:
    selected = []
    for row in rows:
        if str(row.get("file_name") or "").strip().lower() != "instance.zip":
            continue
        if row.get("source_verified") is not True:
            continue
        if row.get("publication_time_verified") is not True:
            continue
        if row.get("point_in_time_eligible") is not True:
            continue
        selected.append(row)
    return selected


def _latest_per_ticker(rows: list[dict[str, object]]) -> list[dict[str, object]]:
    latest: dict[str, dict[str, object]] = {}
    for row in rows:
        ticker = str(row.get("ticker") or "").strip().upper()
        current = latest.get(ticker)
        key = (str(row.get("published_at") or ""), str(row.get("filing_id") or ""))
        current_key = (
            str(current.get("published_at") or ""),
            str(current.get("filing_id") or ""),
        ) if current else ("", "")
        if ticker and (current is None or key > current_key):
            latest[ticker] = row
    return [latest[ticker] for ticker in sorted(latest)]


def _download_with_exact_locator_resolution(
    filing: dict[str, object],
) -> tuple[bytes, str, str, dict[str, object]]:
    original_url = str(filing["file_url"])
    try:
        data, digest, content_type = download_official_idx_attachment(
            original_url, timeout=90.0, retries=2
        )
        return data, digest, content_type, {
            "original_file_url": original_url,
            "resolved_file_url": original_url,
            "url_resolution_state": "ORIGINAL_OFFICIAL_URL",
            "point_in_time_identity_preserved": True,
        }
    except Exception as exc:
        # Only a missing locator is eligible for exact official re-resolution. Network,
        # throttling, TLS, and server failures remain hard failures and are never masked.
        if "HTTP 404" not in str(exc):
            raise
        resolved = resolve_exact_current_report_attachment(filing)
        if resolved is None:
            raise
        resolved_url = str(resolved["resolved_file_url"])
        data, digest, content_type = download_official_idx_attachment(
            resolved_url, timeout=90.0, retries=2
        )
        return data, digest, content_type, {
            "original_file_url": original_url,
            "resolved_file_url": resolved_url,
            "url_resolution_state": str(resolved["resolution_state"]),
            "point_in_time_identity_preserved": bool(resolved["point_in_time_identity_preserved"]),
            "resolved_published_second": str(resolved["published_second"]),
            "resolved_report_file_modified_at": str(resolved["report_file_modified_at"]),
        }


def _extract_one(filing: dict[str, object]) -> tuple[list[dict[str, object]], dict[str, object]]:
    data, digest, content_type, locator = _download_with_exact_locator_resolution(filing)
    facts, telemetry = extract_financial_facts_from_xbrl_zip(data, filing)
    if telemetry["content_hash"] != digest:
        raise RuntimeError("download hash and parser hash disagree")
    if telemetry["metric_catalog_sha256"] != METRIC_CATALOG_SHA256:
        raise RuntimeError("parser taxonomy catalog hash disagrees with backfill contract")
    telemetry["content_type"] = content_type
    telemetry["bytes"] = len(data)
    telemetry.update(locator)
    return facts, telemetry


def main() -> int:
    parser = argparse.ArgumentParser(description="Extract exact point-in-time facts from official IDX instance.zip filings")
    parser.add_argument("--source", type=Path, default=DEFAULT_SOURCE)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--ticker", action="append", default=[])
    parser.add_argument("--latest-only", action="store_true")
    parser.add_argument("--limit", type=int, default=0)
    parser.add_argument("--workers", type=int, default=4)
    args = parser.parse_args()

    filings = _eligible_instances(_load_filings(args.source))
    tickers = {str(value).strip().upper() for value in args.ticker if str(value).strip()}
    if tickers:
        filings = [row for row in filings if str(row.get("ticker") or "").strip().upper() in tickers]
    if args.latest_only:
        filings = _latest_per_ticker(filings)
    filings.sort(key=lambda row: (str(row.get("ticker") or ""), str(row.get("published_at") or ""), str(row.get("filing_id") or "")))
    if args.limit > 0:
        filings = filings[: args.limit]
    if not filings:
        raise SystemExit("no eligible instance.zip filings selected")

    workers = max(1, min(8, int(args.workers)))
    all_facts: list[dict[str, object]] = []
    telemetry: list[dict[str, object]] = []
    failures: list[dict[str, str]] = []

    with ThreadPoolExecutor(max_workers=workers) as pool:
        pending = {pool.submit(_extract_one, row): row for row in filings}
        for future in as_completed(pending):
            filing = pending[future]
            try:
                facts, info = future.result()
                all_facts.extend(facts)
                telemetry.append(info)
                print(json.dumps({
                    "ticker": info["ticker"],
                    "filing_id": info["filing_id"],
                    "fact_rows": info["fact_rows"],
                    "currency": info["reporting_currency"],
                    "url_resolution_state": info["url_resolution_state"],
                }, sort_keys=True))
            except Exception as exc:
                failure = {
                    "filing_id": str(filing.get("filing_id") or ""),
                    "ticker": str(filing.get("ticker") or ""),
                    "file_url": str(filing.get("file_url") or ""),
                    "published_at": str(filing.get("published_at") or ""),
                    "error": f"{type(exc).__name__}: {exc}",
                }
                failures.append(failure)
                print(json.dumps({"status": "FAIL", **failure}, sort_keys=True))

    all_facts.sort(key=lambda row: (str(row["ticker"]), str(row["filing_id"]), str(row["metric_key"])))
    telemetry.sort(key=lambda row: (str(row["ticker"]), str(row["filing_id"])))
    failures.sort(key=lambda row: (row["ticker"], row["filing_id"]))
    now = datetime.now(WIB)
    filing_hashes = {str(row["filing_id"]): str(row["content_hash"]) for row in telemetry}
    distinct_metrics = sorted({str(row["metric_key"]) for row in all_facts})
    distinct_tickers = sorted({str(row["ticker"]) for row in all_facts})
    reporting_currencies = sorted({str(row["reporting_currency"]) for row in telemetry if row.get("reporting_currency")})
    locator_resolution_rows = sum(
        1 for row in telemetry
        if row.get("url_resolution_state") == "EXACT_CURRENT_REPORT_TIMESTAMP_FILENAME"
    )

    payload = {
        "schema_version": CACHE_SCHEMA,
        "generated_at": now.isoformat(),
        "source_authority": "INDONESIA_STOCK_EXCHANGE",
        "parser_contract": PARSER_CONTRACT,
        "metric_catalog_sha256": METRIC_CATALOG_SHA256,
        "metric_catalog": {key: value for key, value in METRIC_CATALOG.items()},
        "selected_filing_rows": len(filings),
        "parsed_filing_rows": len(telemetry),
        "failed_filing_rows": len(failures),
        "fact_rows": len(all_facts),
        "distinct_tickers": distinct_tickers,
        "distinct_metrics": distinct_metrics,
        "reporting_currencies": reporting_currencies,
        "exact_locator_resolution_rows": locator_resolution_rows,
        "filing_hashes": filing_hashes,
        "filing_telemetry": telemetry,
        "failures": failures,
        "rows": all_facts,
        "production_scoring_changed": False,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps({
        "status": "OK" if not failures else "PARTIAL",
        "selected_filing_rows": len(filings),
        "parsed_filing_rows": len(telemetry),
        "failed_filing_rows": len(failures),
        "fact_rows": len(all_facts),
        "distinct_tickers": len(distinct_tickers),
        "distinct_metrics": len(distinct_metrics),
        "exact_locator_resolution_rows": locator_resolution_rows,
        "production_scoring_changed": False,
    }, sort_keys=True))
    return 0 if not failures else 2


if __name__ == "__main__":
    raise SystemExit(main())
