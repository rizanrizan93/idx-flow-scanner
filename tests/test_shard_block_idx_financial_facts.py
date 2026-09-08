from __future__ import annotations

import json
from pathlib import Path

import pytest

from scripts.shard_block_idx_financial_facts import shard_cache


def _source_payload() -> dict[str, object]:
    telemetry = []
    rows = []
    hashes = {}
    for index in range(5):
        filing_id = f"BLOCKIDX-FILING-{index:032d}"
        ticker = f"T{index:03d}"
        telemetry.append(
            {
                "filing_id": filing_id,
                "ticker": ticker,
                "content_hash": f"{index + 1:064x}",
                "reporting_currency": "IDR",
                "url_resolution_state": "ORIGINAL_OFFICIAL_URL",
            }
        )
        hashes[filing_id] = f"{index + 1:064x}"
        for metric in ("total_assets", "profit_loss"):
            rows.append(
                {
                    "fact_id": f"BLOCKIDX-FACT-{index:02d}-{metric}",
                    "filing_id": filing_id,
                    "ticker": ticker,
                    "metric_key": metric,
                }
            )
    return {
        "schema_version": "BLOCK_IDX_FINANCIAL_FACT_CACHE_V5_2",
        "generated_at": "2026-09-08T12:00:00+07:00",
        "source_authority": "INDONESIA_STOCK_EXCHANGE",
        "parser_contract": "EXACT",
        "metric_catalog_sha256": "a" * 64,
        "metric_catalog": {"total_assets": {}, "profit_loss": {}},
        "selected_filing_rows": 5,
        "parsed_filing_rows": 5,
        "failed_filing_rows": 0,
        "fact_rows": 10,
        "distinct_tickers": [f"T{i:03d}" for i in range(5)],
        "distinct_metrics": ["profit_loss", "total_assets"],
        "reporting_currencies": ["IDR"],
        "exact_locator_resolution_rows": 0,
        "filing_hashes": hashes,
        "filing_telemetry": telemetry,
        "rows": rows,
        "production_scoring_changed": False,
    }


def test_sharder_preserves_counts_and_hashes(tmp_path: Path) -> None:
    source = tmp_path / "full.json"
    out = tmp_path / "shards"
    source.write_text(json.dumps(_source_payload()), encoding="utf-8")
    manifest = shard_cache(source, out, filings_per_shard=2)

    assert manifest["schema_version"] == "BLOCK_IDX_FINANCIAL_FACT_MANIFEST_V5_2"
    assert manifest["shard_count"] == 3
    assert manifest["parsed_filing_rows"] == 5
    assert manifest["fact_rows"] == 10
    assert sum(row["filing_rows"] for row in manifest["shards"]) == 5
    assert sum(row["fact_rows"] for row in manifest["shards"]) == 10
    assert (out / "manifest.json").exists()
    for entry in manifest["shards"]:
        shard = json.loads((out / entry["file_name"]).read_text(encoding="utf-8"))
        assert shard["schema_version"] == "BLOCK_IDX_FINANCIAL_FACT_SHARD_V5_2"
        assert shard["production_scoring_changed"] is False


def test_duplicate_filing_metric_is_rejected(tmp_path: Path) -> None:
    payload = _source_payload()
    payload["rows"].append(dict(payload["rows"][0], fact_id="BLOCKIDX-FACT-duplicate"))
    payload["fact_rows"] = 11
    source = tmp_path / "full.json"
    source.write_text(json.dumps(payload), encoding="utf-8")
    with pytest.raises(ValueError, match="duplicate filing/metric"):
        shard_cache(source, tmp_path / "shards", filings_per_shard=2)


def test_failed_source_cache_is_not_sharded(tmp_path: Path) -> None:
    payload = _source_payload()
    payload["failed_filing_rows"] = 1
    source = tmp_path / "full.json"
    source.write_text(json.dumps(payload), encoding="utf-8")
    with pytest.raises(ValueError, match="failed filings"):
        shard_cache(source, tmp_path / "shards")
