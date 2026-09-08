from __future__ import annotations

import argparse
import hashlib
import json
import shutil
from collections import defaultdict
from pathlib import Path

SOURCE_SCHEMA = "BLOCK_IDX_FINANCIAL_FACT_CACHE_V5_2"
SHARD_SCHEMA = "BLOCK_IDX_FINANCIAL_FACT_SHARD_V5_2"
MANIFEST_SCHEMA = "BLOCK_IDX_FINANCIAL_FACT_MANIFEST_V5_2"
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
) -> dict[str, object]:
    if filings_per_shard <= 0:
        raise ValueError("filings_per_shard must be positive")
    payload = json.loads(source.read_text(encoding="utf-8"))
    if payload.get("schema_version") != SOURCE_SCHEMA:
        raise ValueError("unexpected financial fact cache schema")
    if int(payload.get("failed_filing_rows") or 0) != 0:
        raise ValueError("cannot shard a cache with failed filings")
    if int(payload.get("selected_filing_rows") or -1) != int(payload.get("parsed_filing_rows") or -2):
        raise ValueError("selected and parsed filing counts disagree")
    if payload.get("production_scoring_changed") is not False:
        raise ValueError("production scoring contract changed")

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
    if set(filing_hashes) != set(filing_ids):
        raise ValueError("filing hash identities do not match telemetry identities")
    if sum(len(value) for value in facts_by_id.values()) != int(payload.get("fact_rows") or -1):
        raise ValueError("fact count does not match cache summary")

    if out_dir.exists():
        shutil.rmtree(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

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
        "failed_filing_rows": 0,
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
    args = parser.parse_args()
    manifest = shard_cache(args.source, args.out_dir, filings_per_shard=args.filings_per_shard)
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
