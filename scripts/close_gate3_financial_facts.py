from __future__ import annotations

import argparse
import hashlib
import json
from collections import Counter
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime
from io import BytesIO
from pathlib import Path
from typing import Any
from urllib.parse import quote, urlparse, urlunparse
from zoneinfo import ZoneInfo
from zipfile import is_zipfile

from curl_cffi import requests as curl_requests

from idx_flow_scanner.providers.block_idx_financial_facts import (
    METRIC_CATALOG_SHA256,
    extract_financial_facts_from_xbrl_zip,
)
from idx_flow_scanner.providers.block_idx_financial_profile_locator import (
    resolve_exact_profile_announcement_attachment,
)

WIB = ZoneInfo("Asia/Jakarta")
EXPECTED_METRIC_COUNT = 19
OFFICIAL_STATIC_MIRRORS = ("block.idx.id", "idx.id", "www.idx.id")
PERMANENT_UNAVAILABLE = "OFFICIAL_ATTACHMENT_UNAVAILABLE_CONFIRMED"
CORRUPT_UNRECOVERABLE = "OFFICIAL_ATTACHMENT_CORRUPT_CONFIRMED"
CLOSURE_SCHEMA = "BLOCK_IDX_FINANCIAL_FACT_GATE3_CLOSURE_V1"


def _load(path: Path) -> dict[str, Any]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(payload, dict):
        raise ValueError(f"{path} is not a JSON object")
    return payload


def _filing_index(source: dict[str, Any]) -> dict[str, dict[str, Any]]:
    rows = source.get("rows")
    if not isinstance(rows, list):
        raise ValueError("historical filing source has no rows")
    out: dict[str, dict[str, Any]] = {}
    for row in rows:
        if not isinstance(row, dict):
            continue
        filing_id = str(row.get("filing_id") or "")
        if filing_id:
            out[filing_id] = row
    return out


def _same_evidence_path(left: str, right: str) -> bool:
    a = urlparse(str(left or ""))
    b = urlparse(str(right or ""))
    return a.path.rstrip("/") == b.path.rstrip("/") and (a.query or "") == (b.query or "")


def _candidate_url(original_url: str, host: str) -> str:
    parsed = urlparse(original_url)
    if parsed.scheme != "https":
        raise ValueError("official evidence URL must be https")
    return urlunparse(parsed._replace(netloc=host))


def _headers() -> dict[str, str]:
    return {
        "Accept": "application/zip,application/octet-stream,*/*",
        "Accept-Language": "id-ID,id;q=0.9,en;q=0.8",
        "User-Agent": "Mozilla/5.0",
        "Cache-Control": "no-cache",
        "Pragma": "no-cache",
    }


def _fetch(url: str, *, timeout: float, retries: int = 1) -> dict[str, Any]:
    last: dict[str, Any] = {"url": url, "status": None, "error_kind": "NO_ATTEMPT"}
    for attempt in range(1, max(1, int(retries)) + 1):
        session = curl_requests.Session(impersonate="chrome")
        try:
            response = session.get(
                url,
                headers=_headers(),
                timeout=max(1.0, float(timeout)),
                allow_redirects=True,
            )
        except Exception as exc:
            last = {
                "url": url,
                "attempt": attempt,
                "status": None,
                "error_kind": "NETWORK_ERROR",
                "error": f"{type(exc).__name__}: {exc}",
            }
            continue
        data = bytes(response.content or b"")
        valid_zip = bool(data) and is_zipfile(BytesIO(data))
        last = {
            "url": url,
            "attempt": attempt,
            "status": int(response.status_code),
            "final_url": str(response.url),
            "bytes": len(data),
            "sha256": hashlib.sha256(data).hexdigest() if data else None,
            "is_zip": valid_zip,
            "content_type": response.headers.get("content-type"),
            "error_kind": None if int(response.status_code) == 200 and valid_zip else (
                "INVALID_ZIP_BODY" if int(response.status_code) == 200 and data else None
            ),
            "_data": data,
        }
        if int(response.status_code) == 200 and valid_zip:
            return last
        if int(response.status_code) == 404:
            return last
    return last


def _public_attempt(record: dict[str, Any]) -> dict[str, Any]:
    return {key: value for key, value in record.items() if key != "_data"}


def _profile_exact_identity(filing: dict[str, Any]) -> dict[str, Any]:
    resolved = resolve_exact_profile_announcement_attachment(filing)
    if not isinstance(resolved, dict):
        raise RuntimeError("EXACT_PROFILE_IDENTITY_NOT_RESOLVED")
    if resolved.get("point_in_time_identity_preserved") is not True:
        raise RuntimeError("EXACT_PROFILE_IDENTITY_NOT_PRESERVED")
    original = str(filing.get("file_url") or "")
    resolved_url = str(resolved.get("resolved_file_url") or "")
    if not original or not resolved_url or not _same_evidence_path(original, resolved_url):
        raise RuntimeError("EXACT_PROFILE_ATTACHMENT_PATH_MISMATCH")
    if str(resolved.get("ticker") or "").upper() != str(filing.get("ticker") or "").upper():
        raise RuntimeError("EXACT_PROFILE_TICKER_MISMATCH")
    return resolved


def _portal_archive_urls(filing: dict[str, Any]) -> list[str]:
    year = int(filing.get("report_year") or 0)
    period = str(filing.get("report_period") or "").upper()
    ticker = str(filing.get("ticker") or "").upper()
    if year < 2000 or not ticker:
        return []
    folders = [period] if period in {"TW1", "TW2", "TW3"} else (
        ["Audit", "AUDIT", "Tahunan"] if period == "AUDIT" else []
    )
    base = (
        "Portals/0/StaticData/ListedCompanies/Corporate_Actions/New_Info_JSX/"
        "Jenis_Informasi/01_Laporan_Keuangan/02_Soft_Copy_Laporan_Keuangan"
    )
    urls: list[str] = []
    for folder in folders:
        rel = f"/{base}/Laporan Keuangan Tahun {year}/{folder}/{ticker}/instance.zip"
        encoded = quote(rel, safe="/:._-~()[]")
        for host in ("www.idx.id", "idx.id"):
            urls.append(f"https://{host}{encoded}")
    return urls


def _parse_recovery(
    filing: dict[str, Any],
    data: bytes,
    *,
    resolved_file_url: str,
    resolution_state: str,
    extra: dict[str, Any],
) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    digest = hashlib.sha256(data).hexdigest()
    facts, telemetry = extract_financial_facts_from_xbrl_zip(data, filing)
    if telemetry.get("content_hash") != digest:
        raise RuntimeError("RECOVERY_HASH_MISMATCH")
    if telemetry.get("metric_catalog_sha256") != METRIC_CATALOG_SHA256:
        raise RuntimeError("RECOVERY_METRIC_CATALOG_MISMATCH")
    telemetry.update(
        {
            "content_type": "application/zip",
            "bytes": len(data),
            "original_file_url": str(filing.get("file_url") or ""),
            "resolved_file_url": resolved_file_url,
            "url_resolution_state": resolution_state,
            "point_in_time_identity_preserved": True,
            **extra,
        }
    )
    return facts, telemetry


def _recover_from_same_path_mirror(
    filing: dict[str, Any],
    *,
    timeout: float,
) -> tuple[tuple[list[dict[str, Any]], dict[str, Any]] | None, list[dict[str, Any]]]:
    attempts: list[dict[str, Any]] = []
    original_url = str(filing.get("file_url") or "")
    for host in OFFICIAL_STATIC_MIRRORS:
        rec = _fetch(_candidate_url(original_url, host), timeout=timeout, retries=2)
        attempts.append(_public_attempt(rec))
        if rec.get("status") == 200 and rec.get("is_zip") is True:
            facts, telemetry = _parse_recovery(
                filing,
                rec["_data"],
                resolved_file_url=str(rec["url"]),
                resolution_state="EXACT_PROFILE_SAME_PATH_OFFICIAL_MIRROR",
                extra={"gate3_mirror_attempts": list(attempts)},
            )
            return (facts, telemetry), attempts
    return None, attempts


def _recover_truncated_portal_archive(
    filing: dict[str, Any],
    *,
    timeout: float,
) -> tuple[list[dict[str, Any]], dict[str, Any], dict[str, Any]] | None:
    original_url = str(filing.get("file_url") or "")
    block_url = _candidate_url(original_url, "block.idx.id")
    original = _fetch(block_url, timeout=timeout, retries=2)
    original_data = original.get("_data") or b""
    if original.get("status") != 200 or original.get("is_zip") is True or not original_data:
        return None

    for portal_url in _portal_archive_urls(filing):
        portal = _fetch(portal_url, timeout=timeout, retries=2)
        portal_data = portal.get("_data") or b""
        if portal.get("status") != 200 or portal.get("is_zip") is not True:
            continue
        if len(portal_data) <= len(original_data) or portal_data[: len(original_data)] != original_data:
            continue
        facts, telemetry = _parse_recovery(
            filing,
            portal_data,
            resolved_file_url=portal_url,
            resolution_state="OFFICIAL_PORTAL_ARCHIVE_PREFIX_IDENTITY_RECOVERY",
            extra={
                "prefix_identity": True,
                "truncated_original_bytes": len(original_data),
                "truncated_original_sha256": hashlib.sha256(original_data).hexdigest(),
                "gate3_portal_archive_bytes": len(portal_data),
                "gate3_portal_archive_sha256": hashlib.sha256(portal_data).hexdigest(),
            },
        )
        proof = {
            "original": _public_attempt(original),
            "portal": _public_attempt(portal),
            "prefix_identity": True,
        }
        return facts, telemetry, proof
    return None


def _persistent_run4_pattern(failure: dict[str, Any]) -> bool:
    attempts = failure.get("transport_attempts")
    if not isinstance(attempts, list):
        return False
    primary = [
        row for row in attempts
        if isinstance(row, dict)
        and urlparse(str(row.get("transport_url") or "")).netloc.lower() == "www.idx.co.id"
    ]
    block = [
        row for row in attempts
        if isinstance(row, dict)
        and urlparse(str(row.get("transport_url") or "")).netloc.lower() == "block.idx.id"
    ]
    return bool(primary) and all(row.get("status") == 403 for row in primary) and bool(block) and all(
        row.get("status") == 404 for row in block
    )


def _close_failure(
    failure: dict[str, Any],
    filing: dict[str, Any],
    *,
    timeout: float,
) -> dict[str, Any]:
    result: dict[str, Any] = {
        "filing_id": str(filing.get("filing_id") or ""),
        "ticker": str(filing.get("ticker") or ""),
        "action": "UNRESOLVED",
        "failure": dict(failure),
    }
    try:
        profile = _profile_exact_identity(filing)
    except Exception as exc:
        result["reason"] = f"{type(exc).__name__}: {exc}"
        result["failure"]["retryable"] = True
        result["failure"]["failure_class"] = "EXACT_PROFILE_IDENTITY_UNRESOLVED"
        return result

    result["profile_identity"] = profile

    recovered, mirror_attempts = _recover_from_same_path_mirror(filing, timeout=timeout)
    if recovered is not None:
        facts, telemetry = recovered
        result.update(
            action="RECOVERED",
            facts=facts,
            telemetry=telemetry,
            mirror_attempts=mirror_attempts,
        )
        return result

    if str(failure.get("failure_class") or "") == "INVALID_ZIP_BODY":
        portal = _recover_truncated_portal_archive(filing, timeout=timeout)
        if portal is not None:
            facts, telemetry, proof = portal
            result.update(
                action="RECOVERED",
                facts=facts,
                telemetry=telemetry,
                portal_prefix_proof=proof,
            )
            return result

    result["mirror_attempts"] = mirror_attempts

    if _persistent_run4_pattern(failure) and mirror_attempts and all(
        row.get("status") == 404 for row in mirror_attempts
    ):
        final_failure = dict(failure)
        final_failure.update(
            {
                "failure_class": PERMANENT_UNAVAILABLE,
                "retryable": False,
                "point_in_time_identity_preserved": True,
                "exact_profile_resolution_state": profile.get("resolution_state"),
                "exact_profile_announcement_id": profile.get("announcement_id"),
                "exact_profile_jmsx_group_id": profile.get("announcement_jmsx_group_id"),
                "exact_profile_resolved_file_url": profile.get("resolved_file_url"),
                "official_mirror_attempts": mirror_attempts,
                "classification_reason": (
                    "run4 primary edge remained 403 after bounded retries; exact official profile "
                    "identity re-confirmed; block.idx.id, idx.id and www.idx.id exact-path mirrors all 404"
                ),
            }
        )
        result.update(action="CLASSIFIED_PERMANENT", failure=final_failure)
        return result

    if str(failure.get("failure_class") or "") == "INVALID_ZIP_BODY" and mirror_attempts and all(
        row.get("status") in {200, 404} for row in mirror_attempts
    ):
        final_failure = dict(failure)
        final_failure.update(
            {
                "failure_class": CORRUPT_UNRECOVERABLE,
                "retryable": False,
                "point_in_time_identity_preserved": True,
                "exact_profile_resolution_state": profile.get("resolution_state"),
                "official_mirror_attempts": mirror_attempts,
                "classification_reason": "exact official attachment identity confirmed but no valid complete ZIP could be recovered",
            }
        )
        result.update(action="CLASSIFIED_PERMANENT", failure=final_failure)
        return result

    final_failure = dict(failure)
    final_failure["retryable"] = True
    final_failure["failure_class"] = "UNRESOLVED_OFFICIAL_ATTACHMENT_TRANSPORT"
    final_failure["official_mirror_attempts"] = mirror_attempts
    result["failure"] = final_failure
    return result


def _rebuild_payload(
    cache: dict[str, Any],
    outcomes: list[dict[str, Any]],
) -> dict[str, Any]:
    rows = list(cache.get("rows") or [])
    telemetry = list(cache.get("filing_telemetry") or [])
    failures_by_id = {
        str(row.get("filing_id") or ""): dict(row)
        for row in cache.get("failures") or []
        if isinstance(row, dict)
    }

    recovered = 0
    permanent = 0
    for outcome in outcomes:
        filing_id = str(outcome.get("filing_id") or "")
        action = outcome.get("action")
        if action == "RECOVERED":
            rows.extend(outcome["facts"])
            telemetry.append(outcome["telemetry"])
            failures_by_id.pop(filing_id, None)
            recovered += 1
        elif action == "CLASSIFIED_PERMANENT":
            failures_by_id[filing_id] = outcome["failure"]
            permanent += 1
        else:
            failures_by_id[filing_id] = outcome["failure"]

    rows.sort(key=lambda row: (str(row.get("ticker") or ""), str(row.get("filing_id") or ""), str(row.get("metric_key") or "")))
    telemetry.sort(key=lambda row: (str(row.get("ticker") or ""), str(row.get("filing_id") or "")))
    failures = sorted(
        failures_by_id.values(),
        key=lambda row: (str(row.get("ticker") or ""), str(row.get("filing_id") or "")),
    )

    payload = dict(cache)
    payload["generated_at"] = datetime.now(WIB).isoformat()
    payload["parsed_filing_rows"] = len(telemetry)
    payload["failed_filing_rows"] = len(failures)
    payload["fact_rows"] = len(rows)
    payload["distinct_tickers"] = sorted({str(row.get("ticker") or "") for row in rows if row.get("ticker")})
    payload["distinct_metrics"] = sorted({str(row.get("metric_key") or "") for row in rows if row.get("metric_key")})
    payload["reporting_currencies"] = sorted({
        str(row.get("reporting_currency") or "")
        for row in telemetry if row.get("reporting_currency")
    })
    payload["exact_locator_resolution_rows"] = sum(
        1 for row in telemetry if row.get("url_resolution_state") not in {None, "ORIGINAL_OFFICIAL_URL"}
    )
    payload["failure_class_counts"] = dict(sorted(Counter(
        str(row.get("failure_class") or "") for row in failures
    ).items()))
    payload["filing_hashes"] = {
        str(row.get("filing_id") or ""): str(row.get("content_hash") or "")
        for row in telemetry if row.get("filing_id") and row.get("content_hash")
    }
    payload["filing_telemetry"] = telemetry
    payload["failures"] = failures
    payload["rows"] = rows
    payload["production_scoring_changed"] = False
    payload["gate3_closure"] = {
        "schema_version": CLOSURE_SCHEMA,
        "recovered_filing_rows": recovered,
        "permanent_classified_failure_rows": permanent,
        "retryable_failure_rows": sum(1 for row in failures if row.get("retryable") is True),
        "production_scoring_changed": False,
    }
    return payload


def main() -> int:
    parser = argparse.ArgumentParser(description="Close Gate 3 without fabricating unavailable official IDX bytes")
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--cache", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--summary", type=Path, required=True)
    parser.add_argument("--workers", type=int, default=6)
    parser.add_argument("--timeout", type=float, default=20.0)
    args = parser.parse_args()

    source = _load(args.source)
    cache = _load(args.cache)
    filings = _filing_index(source)
    failures = [row for row in cache.get("failures") or [] if isinstance(row, dict)]
    if int(cache.get("selected_filing_rows") or 0) <= 0:
        raise SystemExit("invalid full-corpus cache: selected_filing_rows <= 0")
    if cache.get("production_scoring_changed") is not False:
        raise SystemExit("production scoring changed in Gate 3 input")
    if len(cache.get("distinct_metrics") or []) != EXPECTED_METRIC_COUNT:
        raise SystemExit("full-corpus input does not contain all 19 metrics")

    outcomes: list[dict[str, Any]] = []
    worker_count = max(1, min(8, int(args.workers)))
    with ThreadPoolExecutor(max_workers=worker_count) as pool:
        pending = {}
        for failure in failures:
            filing_id = str(failure.get("filing_id") or "")
            filing = filings.get(filing_id)
            if filing is None:
                outcome = {
                    "filing_id": filing_id,
                    "ticker": str(failure.get("ticker") or ""),
                    "action": "UNRESOLVED",
                    "failure": {
                        **failure,
                        "failure_class": "SOURCE_FILING_ID_NOT_FOUND",
                        "retryable": False,
                    },
                }
                outcomes.append(outcome)
                continue
            pending[pool.submit(_close_failure, failure, filing, timeout=args.timeout)] = filing_id

        for future in as_completed(pending):
            filing_id = pending[future]
            try:
                outcome = future.result()
            except Exception as exc:
                failure = next(row for row in failures if str(row.get("filing_id") or "") == filing_id)
                outcome = {
                    "filing_id": filing_id,
                    "ticker": str(failure.get("ticker") or ""),
                    "action": "UNRESOLVED",
                    "failure": {
                        **failure,
                        "failure_class": "GATE3_CLOSURE_EXCEPTION",
                        "retryable": True,
                        "closure_error": f"{type(exc).__name__}: {exc}",
                    },
                }
            outcomes.append(outcome)
            print(json.dumps({
                "filing_id": outcome.get("filing_id"),
                "ticker": outcome.get("ticker"),
                "action": outcome.get("action"),
                "failure_class": (outcome.get("failure") or {}).get("failure_class"),
                "fact_rows": len(outcome.get("facts") or []),
            }, sort_keys=True))

    outcomes.sort(key=lambda row: (str(row.get("ticker") or ""), str(row.get("filing_id") or "")))
    final_payload = _rebuild_payload(cache, outcomes)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(final_payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    final_failures = final_payload["failures"]
    retryable = [row for row in final_failures if row.get("retryable") is True]
    parser_contract_failures = [
        row for row in final_failures
        if str(row.get("failure_class") or "") in {
            "PARSER_OR_CONTRACT_FAILURE",
            "UNRESOLVED_OFFICIAL_ATTACHMENT_TRANSPORT",
            "EXACT_PROFILE_IDENTITY_UNRESOLVED",
            "GATE3_CLOSURE_EXCEPTION",
        }
    ]
    summary = {
        "schema_version": CLOSURE_SCHEMA,
        "gate3_status": "PASS" if not retryable and not parser_contract_failures else "FAIL",
        "selected_filing_rows": final_payload["selected_filing_rows"],
        "parsed_filing_rows": final_payload["parsed_filing_rows"],
        "failed_filing_rows": final_payload["failed_filing_rows"],
        "fact_rows": final_payload["fact_rows"],
        "distinct_tickers": len(final_payload["distinct_tickers"]),
        "distinct_metrics": len(final_payload["distinct_metrics"]),
        "reporting_currencies": final_payload["reporting_currencies"],
        "exact_locator_resolution_rows": final_payload["exact_locator_resolution_rows"],
        "failure_class_counts": final_payload["failure_class_counts"],
        "retryable_failure_rows": len(retryable),
        "parser_or_contract_failure_rows": len(parser_contract_failures),
        "recovered_filing_rows": sum(1 for row in outcomes if row.get("action") == "RECOVERED"),
        "permanent_classified_failure_rows": sum(1 for row in outcomes if row.get("action") == "CLASSIFIED_PERMANENT"),
        "production_scoring_changed": False,
        "no_fake_100_percent": final_payload["failed_filing_rows"] > 0,
        "outcomes": [
            {
                "filing_id": row.get("filing_id"),
                "ticker": row.get("ticker"),
                "action": row.get("action"),
                "failure_class": (row.get("failure") or {}).get("failure_class"),
                "fact_rows": len(row.get("facts") or []),
            }
            for row in outcomes
        ],
    }
    args.summary.parent.mkdir(parents=True, exist_ok=True)
    args.summary.write_text(json.dumps(summary, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps({key: value for key, value in summary.items() if key != "outcomes"}, sort_keys=True))

    return 0 if summary["gate3_status"] == "PASS" else 2


if __name__ == "__main__":
    raise SystemExit(main())
