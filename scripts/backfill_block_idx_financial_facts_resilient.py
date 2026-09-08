from __future__ import annotations

import argparse
import json
from collections import Counter
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

from idx_flow_scanner.providers.block_idx_financial_facts import (
    METRIC_CATALOG,
    METRIC_CATALOG_SHA256,
    extract_financial_facts_from_xbrl_zip,
)
from idx_flow_scanner.providers.block_idx_financial_locator import (
    resolve_exact_current_report_attachment,
)
from idx_flow_scanner.providers.block_idx_financial_profile_locator import (
    resolve_exact_profile_announcement_attachment,
)
from idx_flow_scanner.providers.block_idx_financial_transport import (
    OfficialIDXAttachmentDownloadError,
    download_official_idx_xbrl_attachment,
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
    selected: list[dict[str, object]] = []
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


def _attempt_summary(attempts: object) -> list[dict[str, object]]:
    out: list[dict[str, object]] = []
    for item in attempts if isinstance(attempts, (list, tuple)) else []:
        out.append(
            {
                "transport_url": str(getattr(item, "transport_url", "")),
                "attempt": int(getattr(item, "attempt", 0)),
                "status": getattr(item, "status", None),
                "error_kind": getattr(item, "error_kind", None),
            }
        )
    return out


def _locator_candidates(filing: dict[str, object]) -> list[dict[str, object]]:
    candidates: list[dict[str, object]] = []
    for resolver in (
        resolve_exact_current_report_attachment,
        resolve_exact_profile_announcement_attachment,
    ):
        try:
            resolved = resolver(filing)
        except Exception:
            resolved = None
        if not isinstance(resolved, dict):
            continue
        if resolved.get("point_in_time_identity_preserved") is not True:
            continue
        url = str(resolved.get("resolved_file_url") or "").strip()
        if not url:
            continue
        if any(str(row.get("resolved_file_url") or "") == url for row in candidates):
            continue
        candidates.append(resolved)
    return candidates


def _download_with_exact_locator_resolution(
    filing: dict[str, object],
    *,
    timeout: float,
    retries: int,
) -> tuple[bytes, str, str | None, dict[str, object]]:
    original_url = str(filing["file_url"])
    try:
        data, digest, content_type, attempts = download_official_idx_xbrl_attachment(
            original_url, timeout=timeout, retries=retries
        )
        return data, digest, content_type, {
            "original_file_url": original_url,
            "resolved_file_url": original_url,
            "url_resolution_state": "ORIGINAL_OFFICIAL_URL",
            "point_in_time_identity_preserved": True,
            "transport_attempts": _attempt_summary(attempts),
        }
    except OfficialIDXAttachmentDownloadError as original_error:
        # Locator repair is legal only when every attempted official transport says
        # the locator is absent. A 403/5xx/network/invalid body is transport failure,
        # not evidence that the historical attachment URL is missing.
        if not original_error.all_not_found:
            raise

        locator_errors: list[str] = []
        for resolved in _locator_candidates(filing):
            resolved_url = str(resolved["resolved_file_url"])
            if resolved_url == original_url:
                continue
            try:
                data, digest, content_type, attempts = download_official_idx_xbrl_attachment(
                    resolved_url, timeout=timeout, retries=retries
                )
                locator = dict(resolved)
                locator["transport_attempts"] = _attempt_summary(attempts)
                return data, digest, content_type, locator
            except OfficialIDXAttachmentDownloadError as exc:
                locator_errors.append(f"{exc.code}:{resolved_url}")

        if locator_errors:
            raise RuntimeError(
                "EXACT_LOCATOR_CANDIDATES_UNAVAILABLE:" + ";".join(locator_errors)
            ) from original_error
        raise


def _extract_one(
    filing: dict[str, object],
    *,
    timeout: float,
    retries: int,
) -> tuple[list[dict[str, object]], dict[str, object]]:
    data, digest, content_type, locator = _download_with_exact_locator_resolution(
        filing, timeout=timeout, retries=retries
    )
    facts, telemetry = extract_financial_facts_from_xbrl_zip(data, filing)
    if telemetry["content_hash"] != digest:
        raise RuntimeError("download hash and parser hash disagree")
    if telemetry["metric_catalog_sha256"] != METRIC_CATALOG_SHA256:
        raise RuntimeError("parser taxonomy catalog hash disagrees with backfill contract")
    telemetry["content_type"] = content_type
    telemetry["bytes"] = len(data)
    telemetry.update(locator)
    return facts, telemetry


def _failure_record(
    filing: dict[str, object],
    exc: BaseException,
    *,
    pass_number: int,
) -> dict[str, object]:
    record: dict[str, object] = {
        "filing_id": str(filing.get("filing_id") or ""),
        "ticker": str(filing.get("ticker") or ""),
        "file_url": str(filing.get("file_url") or ""),
        "published_at": str(filing.get("published_at") or ""),
        "error": f"{type(exc).__name__}: {exc}",
        "pass_number": int(pass_number),
        "retryable": False,
        "failure_class": "PARSER_OR_CONTRACT_FAILURE",
    }
    if isinstance(exc, OfficialIDXAttachmentDownloadError):
        record["failure_class"] = exc.code
        record["retryable"] = bool(exc.transient or exc.code == "INVALID_ZIP_BODY")
        record["all_not_found"] = bool(exc.all_not_found)
        record["transport_attempts"] = _attempt_summary(exc.attempts)
    elif isinstance(exc, TimeoutError):
        record["failure_class"] = "TRANSIENT_NETWORK_TIMEOUT"
        record["retryable"] = True
    elif "EXACT_LOCATOR_CANDIDATES_UNAVAILABLE" in str(exc):
        record["failure_class"] = "EXACT_LOCATOR_CANDIDATES_UNAVAILABLE"
        record["retryable"] = True
    return record


def _run_pass(
    filings: list[dict[str, object]],
    *,
    pass_number: int,
    workers: int,
    timeout: float,
    retries: int,
) -> tuple[
    dict[str, tuple[list[dict[str, object]], dict[str, object]]],
    dict[str, dict[str, object]],
]:
    successes: dict[str, tuple[list[dict[str, object]], dict[str, object]]] = {}
    failures: dict[str, dict[str, object]] = {}
    worker_count = max(1, min(8, int(workers)))

    with ThreadPoolExecutor(max_workers=worker_count) as pool:
        pending = {
            pool.submit(_extract_one, row, timeout=timeout, retries=retries): row
            for row in filings
        }
        for future in as_completed(pending):
            filing = pending[future]
            filing_id = str(filing.get("filing_id") or "")
            try:
                facts, info = future.result()
                successes[filing_id] = (facts, info)
                print(json.dumps({
                    "status": "OK",
                    "pass_number": pass_number,
                    "ticker": info["ticker"],
                    "filing_id": info["filing_id"],
                    "fact_rows": info["fact_rows"],
                    "currency": info["reporting_currency"],
                    "url_resolution_state": info["url_resolution_state"],
                }, sort_keys=True))
            except Exception as exc:
                failure = _failure_record(filing, exc, pass_number=pass_number)
                failures[filing_id] = failure
                print(json.dumps({"status": "FAIL", **failure}, sort_keys=True))

    return successes, failures


def _write_payload(
    output: Path,
    filings: list[dict[str, object]],
    successes: dict[str, tuple[list[dict[str, object]], dict[str, object]]],
    failures: dict[str, dict[str, object]],
    retry_history: list[dict[str, object]],
) -> dict[str, object]:
    all_facts = [fact for facts, _telemetry in successes.values() for fact in facts]
    telemetry = [info for _facts, info in successes.values()]
    all_facts.sort(key=lambda row: (str(row["ticker"]), str(row["filing_id"]), str(row["metric_key"])))
    telemetry.sort(key=lambda row: (str(row["ticker"]), str(row["filing_id"])))
    final_failures = sorted(failures.values(), key=lambda row: (str(row["ticker"]), str(row["filing_id"])))
    filing_hashes = {str(row["filing_id"]): str(row["content_hash"]) for row in telemetry}
    distinct_metrics = sorted({str(row["metric_key"]) for row in all_facts})
    distinct_tickers = sorted({str(row["ticker"]) for row in all_facts})
    reporting_currencies = sorted({str(row["reporting_currency"]) for row in telemetry if row.get("reporting_currency")})
    locator_resolution_rows = sum(
        1 for row in telemetry
        if row.get("url_resolution_state") not in {None, "ORIGINAL_OFFICIAL_URL"}
    )
    failure_class_counts = dict(sorted(Counter(str(row["failure_class"]) for row in final_failures).items()))

    payload = {
        "schema_version": CACHE_SCHEMA,
        "generated_at": datetime.now(WIB).isoformat(),
        "source_authority": "INDONESIA_STOCK_EXCHANGE",
        "parser_contract": PARSER_CONTRACT,
        "metric_catalog_sha256": METRIC_CATALOG_SHA256,
        "metric_catalog": {key: value for key, value in METRIC_CATALOG.items()},
        "selected_filing_rows": len(filings),
        "parsed_filing_rows": len(telemetry),
        "failed_filing_rows": len(final_failures),
        "fact_rows": len(all_facts),
        "distinct_tickers": distinct_tickers,
        "distinct_metrics": distinct_metrics,
        "reporting_currencies": reporting_currencies,
        "exact_locator_resolution_rows": locator_resolution_rows,
        "failure_class_counts": failure_class_counts,
        "retry_history": retry_history,
        "filing_hashes": filing_hashes,
        "filing_telemetry": telemetry,
        "failures": final_failures,
        "rows": all_facts,
        "production_scoring_changed": False,
    }
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return payload


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Resilient exact PIT extraction from official IDX instance.zip filings"
    )
    parser.add_argument("--source", type=Path, default=DEFAULT_SOURCE)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--ticker", action="append", default=[])
    parser.add_argument("--latest-only", action="store_true")
    parser.add_argument("--limit", type=int, default=0)
    parser.add_argument("--workers", type=int, default=8)
    parser.add_argument("--timeout", type=float, default=75.0)
    parser.add_argument("--retries", type=int, default=2)
    parser.add_argument("--retry-passes", type=int, default=2)
    parser.add_argument("--retry-workers", type=int, default=2)
    parser.add_argument("--retry-retries", type=int, default=4)
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

    by_id = {str(row["filing_id"]): row for row in filings}
    successes, failures = _run_pass(
        filings,
        pass_number=1,
        workers=args.workers,
        timeout=args.timeout,
        retries=args.retries,
    )
    retry_history: list[dict[str, object]] = [{
        "pass_number": 1,
        "selected_rows": len(filings),
        "success_rows": len(successes),
        "failed_rows": len(failures),
    }]

    _write_payload(args.output, filings, successes, failures, retry_history)

    for retry_index in range(1, max(0, int(args.retry_passes)) + 1):
        retry_ids = sorted(
            filing_id for filing_id, failure in failures.items()
            if failure.get("retryable") is True
        )
        if not retry_ids:
            break
        retry_filings = [by_id[filing_id] for filing_id in retry_ids]
        pass_number = retry_index + 1
        pass_successes, pass_failures = _run_pass(
            retry_filings,
            pass_number=pass_number,
            workers=max(1, int(args.retry_workers) // retry_index),
            timeout=args.timeout,
            retries=args.retry_retries,
        )
        successes.update(pass_successes)
        for filing_id in pass_successes:
            failures.pop(filing_id, None)
        for filing_id, failure in pass_failures.items():
            failures[filing_id] = failure
        retry_history.append({
            "pass_number": pass_number,
            "selected_rows": len(retry_filings),
            "success_rows": len(pass_successes),
            "failed_rows": len(pass_failures),
        })
        _write_payload(args.output, filings, successes, failures, retry_history)

    payload = _write_payload(args.output, filings, successes, failures, retry_history)
    print(json.dumps({
        "status": "OK" if not failures else "PARTIAL",
        "selected_filing_rows": payload["selected_filing_rows"],
        "parsed_filing_rows": payload["parsed_filing_rows"],
        "failed_filing_rows": payload["failed_filing_rows"],
        "fact_rows": payload["fact_rows"],
        "distinct_tickers": len(payload["distinct_tickers"]),
        "distinct_metrics": len(payload["distinct_metrics"]),
        "exact_locator_resolution_rows": payload["exact_locator_resolution_rows"],
        "failure_class_counts": payload["failure_class_counts"],
        "retry_history": payload["retry_history"],
        "production_scoring_changed": False,
    }, sort_keys=True))
    return 0 if not failures else 2


if __name__ == "__main__":
    raise SystemExit(main())
