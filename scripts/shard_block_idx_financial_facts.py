from __future__ import annotations

import argparse
import hashlib
import json
import re
from collections import Counter

from idx_flow_scanner.providers.block_idx_financial_facts import METRIC_CATALOG, METRIC_CATALOG_SHA256
from collections import defaultdict
from pathlib import Path

SOURCE_SCHEMA = "BLOCK_IDX_FINANCIAL_FACT_CACHE_V5_2"
SHARD_SCHEMA = "BLOCK_IDX_FINANCIAL_FACT_SHARD_V5_2"
MANIFEST_SCHEMA = "BLOCK_IDX_FINANCIAL_FACT_MANIFEST_V5_3"
PARSER_CONTRACT = "EXACT_IDX_CORE_TAXONOMY_SINGLE_CURRENCY_CURRENT_UNDIMENSIONED_YTD_OR_INSTANT_V5_2"
EXCLUSION_SCHEMA = "BLOCK_IDX_FINANCIAL_FACT_EXCLUSIONS_V5_3"
PERMANENT_CLASSES = frozenset({"OFFICIAL_ATTACHMENT_UNAVAILABLE_CONFIRMED", "OFFICIAL_ATTACHMENT_CORRUPT_CONFIRMED"})
DEFAULT_SOURCE = Path("data/cache/evidence_v5/block_idx_financial_facts.json")
DEFAULT_OUT_DIR = Path("data/cache/evidence_v5/financial_facts_v5")


def _canonical_bytes(payload: object) -> bytes:
    return (json.dumps(payload, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")


def _sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def shard_cache(
    source: Path,
    out_dir: Path,
    *,
    filings_per_shard: int = 500,
    source_run_id: int,
    source_head_sha: str,
) -> dict[str, object]:
    if filings_per_shard <= 0:
        raise ValueError("filings_per_shard must be positive")
    payload = json.loads(source.read_text(encoding="utf-8"))
    if payload.get("schema_version") != SOURCE_SCHEMA:
        raise ValueError("unexpected financial fact cache schema")
    expected = {
        "source_authority": "INDONESIA_STOCK_EXCHANGE",
        "parser_contract": PARSER_CONTRACT,
        "metric_catalog_sha256": METRIC_CATALOG_SHA256,
        "production_scoring_changed": False,
    }
    for key, value in expected.items():
        if payload.get(key) != value:
            raise ValueError(f"cache contract mismatch: {key}")
    if _canonical_bytes(payload.get("metric_catalog")) != _canonical_bytes(METRIC_CATALOG):
        raise ValueError("metric catalog content mismatch")
    if type(source_run_id) is not int or source_run_id <= 0 or not re.fullmatch(r"[0-9a-f]{40}", source_head_sha):
        raise ValueError("source run/head provenance required")
    failures = payload.get("failures")
    if not isinstance(failures, list):
        raise ValueError("explicit failure ledger required")
    exclusions = {}
    for failure in failures:
        if not isinstance(failure, dict):
            raise ValueError("invalid exclusion row")
        fid = failure.get("filing_id")
        if not isinstance(fid, str) or not fid or fid in exclusions:
            raise ValueError("missing or duplicate exclusion filing id")
        if failure.get("failure_class") not in PERMANENT_CLASSES or failure.get("retryable") is not False:
            raise ValueError("unresolved retryable/parser/contract failed filings")
        if failure.get("point_in_time_identity_preserved") is not True:
            raise ValueError("exclusion PIT identity not preserved")
        for key in ("ticker", "file_url", "published_at", "exact_profile_resolution_state", "classification_reason", "official_mirror_attempts"):
            if not failure.get(key):
                raise ValueError(f"exclusion provenance missing: {key}")
        if failure["failure_class"] == "OFFICIAL_ATTACHMENT_UNAVAILABLE_CONFIRMED":
            for key in ("exact_profile_announcement_id", "exact_profile_resolved_file_url"):
                if not failure.get(key):
                    raise ValueError(f"exclusion exact identity missing: {key}")
        exclusions[fid] = failure
    class_counts = dict(sorted(Counter(row["failure_class"] for row in failures).items()))
    if payload.get("failure_class_counts") != class_counts:
        raise ValueError("failure class count mismatch")
    if payload.get("failed_filing_rows") != len(exclusions):
        raise ValueError("failed filing count/ledger mismatch")
    if payload.get("selected_filing_rows") != payload.get("parsed_filing_rows", -1) + len(exclusions):
        raise ValueError("selected must equal parsed plus permanent excluded")
    for key in ("retryable_failure_rows", "parser_or_contract_failure_rows"):
        if key in payload and payload[key] != 0:
            raise ValueError(f"nonzero {key}")
    closure = payload.get("gate3_closure", {})
    if closure.get("retryable_failure_rows", 0) != 0:
        raise ValueError("nonzero Gate 3 retryable failures")

    telemetry = payload.get("filing_telemetry")
    rows = payload.get("rows")
    filing_hashes = payload.get("filing_hashes")
    if not isinstance(telemetry, list) or not isinstance(rows, list) or not isinstance(filing_hashes, dict):
        raise ValueError("cache is missing telemetry, rows, or filing hashes")

    telemetry_by_id: dict[str, dict[str, object]] = {}
    for item in telemetry:
        if not isinstance(item, dict):
            raise ValueError("invalid filing telemetry row")
        filing_id = str(item.get("filing_id") or "")
        if not filing_id or filing_id in telemetry_by_id:
            raise ValueError("missing or duplicate filing telemetry id")
        telemetry_by_id[filing_id] = item

    facts_by_id: dict[str, list[dict[str, object]]] = defaultdict(list)
    seen_fact_ids: set[str] = set()
    seen_filing_metric: set[tuple[str, str]] = set()
    for item in rows:
        if not isinstance(item, dict):
            raise ValueError("invalid fact row")
        filing_id = str(item.get("filing_id") or "")
        fact_id = str(item.get("fact_id") or "")
        metric_key = str(item.get("metric_key") or "")
        if not filing_id or filing_id not in telemetry_by_id or not fact_id or not metric_key:
            raise ValueError("fact row has invalid identity")
        if fact_id in seen_fact_ids:
            raise ValueError(f"duplicate fact_id: {fact_id}")
        if (filing_id, metric_key) in seen_filing_metric:
            raise ValueError(f"duplicate filing/metric: {filing_id}/{metric_key}")
        seen_fact_ids.add(fact_id)
        seen_filing_metric.add((filing_id, metric_key))
        facts_by_id[filing_id].append(item)

    filing_ids = sorted(telemetry_by_id)
    if len(filing_ids) != int(payload.get("parsed_filing_rows") or -1):
        raise ValueError("parsed filing count does not match telemetry identities")
    if set(filing_ids) & set(exclusions):
        raise ValueError("parsed/excluded filing overlap")
    if set(filing_hashes) != set(filing_ids):
        raise ValueError("filing hash identities do not match telemetry identities")
    if sum(len(value) for value in facts_by_id.values()) != int(payload.get("fact_rows") or -1):
        raise ValueError("fact count does not match cache summary")

    for fid, item in telemetry_by_id.items():
        if not re.fullmatch(r"[0-9a-f]{64}", str(filing_hashes[fid])) or filing_hashes[fid] != item.get("content_hash"):
            raise ValueError("filing content hash mismatch")
        if item.get("fact_rows") != len(facts_by_id[fid]):
            raise ValueError("filing fact count mismatch")
    if sorted({row["ticker"] for row in rows}) != payload.get("distinct_tickers"):
        raise ValueError("ticker summary mismatch")
    if sorted({row["metric_key"] for row in rows}) != payload.get("distinct_metrics"):
        raise ValueError("metric summary mismatch")
    if sorted({row["reporting_currency"] for row in telemetry if row.get("reporting_currency")}) != payload.get("reporting_currencies"):
        raise ValueError("currency summary mismatch")
    if any(row["metric_key"] not in METRIC_CATALOG for row in rows):
        raise ValueError("unknown metric")
    if out_dir.exists() and any(out_dir.iterdir()):
        raise ValueError("output directory must be empty; immutable artifacts are never overwritten")
    out_dir.mkdir(parents=True, exist_ok=True)
    exclusion_payload = {
        "schema_version": EXCLUSION_SCHEMA,
        "source_schema_version": SOURCE_SCHEMA,
        "source_run_id": source_run_id,
        "source_head_sha": source_head_sha,
        "production_scoring_changed": False,
        "permanent_excluded_filing_rows": len(exclusions),
        "exclusion_class_counts": class_counts,
        "rows": [exclusions[fid] for fid in sorted(exclusions)],
    }
    exclusion_bytes = _canonical_bytes(exclusion_payload)
    (out_dir / "exclusions.json").write_bytes(exclusion_bytes)

    shard_entries: list[dict[str, object]] = []
    total_facts = 0
    total_filings = 0
    for offset in range(0, len(filing_ids), filings_per_shard):
        chunk = filing_ids[offset : offset + filings_per_shard]
        shard_rows = [fact for filing_id in chunk for fact in facts_by_id.get(filing_id, [])]
        shard_rows.sort(key=lambda row: (str(row["filing_id"]), str(row["metric_key"]), str(row["fact_id"])))
        shard_telemetry = [telemetry_by_id[filing_id] for filing_id in chunk]
        shard_hashes = {filing_id: str(filing_hashes[filing_id]) for filing_id in chunk}
        shard_index = len(shard_entries) + 1
        file_name = f"shard-{shard_index:04d}.json"
        shard_payload = {
            "schema_version": SHARD_SCHEMA,
            "source_schema_version": SOURCE_SCHEMA,
            "generated_at": payload.get("generated_at"),
            "source_authority": payload.get("source_authority"),
            "parser_contract": payload.get("parser_contract"),
            "metric_catalog_sha256": payload.get("metric_catalog_sha256"),
            "production_scoring_changed": False,
            "shard_index": shard_index,
            "filing_rows": len(chunk),
            "fact_rows": len(shard_rows),
            "filing_ids": chunk,
            "filing_hashes": shard_hashes,
            "filing_telemetry": shard_telemetry,
            "rows": shard_rows,
        }
        data = _canonical_bytes(shard_payload)
        (out_dir / file_name).write_bytes(data)
        digest = _sha256(data)
        shard_entries.append(
            {
                "shard_index": shard_index,
                "file_name": file_name,
                "sha256": digest,
                "bytes": len(data),
                "filing_rows": len(chunk),
                "fact_rows": len(shard_rows),
                "first_filing_id": chunk[0],
                "last_filing_id": chunk[-1],
            }
        )
        total_filings += len(chunk)
        total_facts += len(shard_rows)

    if total_filings != int(payload["parsed_filing_rows"]):
        raise RuntimeError("shard filing total mismatch")
    if total_facts != int(payload["fact_rows"]):
        raise RuntimeError("shard fact total mismatch")

    manifest = {
        "schema_version": MANIFEST_SCHEMA,
        "source_schema_version": SOURCE_SCHEMA,
        "generated_at": payload.get("generated_at"),
        "source_authority": payload.get("source_authority"),
        "parser_contract": payload.get("parser_contract"),
        "metric_catalog_sha256": payload.get("metric_catalog_sha256"),
        "metric_catalog": payload.get("metric_catalog"),
        "selected_filing_rows": payload.get("selected_filing_rows"),
        "parsed_filing_rows": payload.get("parsed_filing_rows"),
        "failed_filing_rows": len(exclusions),
        "permanent_excluded_filing_rows": len(exclusions),
        "retryable_failure_rows": 0,
        "parser_or_contract_failure_rows": 0,
        "exclusion_class_counts": class_counts,
        "exclusions": {"file_name": "exclusions.json", "sha256": _sha256(exclusion_bytes), "bytes": len(exclusion_bytes), "filing_rows": len(exclusions)},
        "source_run_id": source_run_id,
        "source_head_sha": source_head_sha,
        "source_cache_sha256": _sha256(source.read_bytes()),
        "artifact_commit_binding": "IMMUTABLE_COMMIT_URL_AND_EXTERNAL_PUBLICATION_RECEIPT",
        "fact_rows": payload.get("fact_rows"),
        "distinct_tickers": payload.get("distinct_tickers"),
        "distinct_metrics": payload.get("distinct_metrics"),
        "reporting_currencies": payload.get("reporting_currencies"),
        "exact_locator_resolution_rows": payload.get("exact_locator_resolution_rows", 0),
        "shard_count": len(shard_entries),
        "filings_per_shard": filings_per_shard,
        "shards": shard_entries,
        "production_scoring_changed": False,
    }
    manifest_bytes = _canonical_bytes(manifest)
    (out_dir / "manifest.json").write_bytes(manifest_bytes)
    return manifest


def main() -> int:
    parser = argparse.ArgumentParser(description="Split validated IDX financial fact cache into deterministic ingest shards")
    parser.add_argument("--source", type=Path, default=DEFAULT_SOURCE)
    parser.add_argument("--out-dir", type=Path, default=DEFAULT_OUT_DIR)
    parser.add_argument("--filings-per-shard", type=int, default=500)
    parser.add_argument("--source-run-id", type=int, required=True)
    parser.add_argument("--source-head-sha", required=True)
    args = parser.parse_args()
    manifest = shard_cache(args.source, args.out_dir, filings_per_shard=args.filings_per_shard, source_run_id=args.source_run_id, source_head_sha=args.source_head_sha)
    print(json.dumps({
        "status": "OK",
        "schema_version": manifest["schema_version"],
        "parsed_filing_rows": manifest["parsed_filing_rows"],
        "fact_rows": manifest["fact_rows"],
        "shard_count": manifest["shard_count"],
        "production_scoring_changed": False,
    }, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
