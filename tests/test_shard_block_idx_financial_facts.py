from __future__ import annotations

import json
from pathlib import Path

import pytest

from scripts.shard_block_idx_financial_facts import shard_cache as _shard_cache, PARSER_CONTRACT
from idx_flow_scanner.providers.block_idx_financial_facts import METRIC_CATALOG, METRIC_CATALOG_SHA256

def shard_cache(*args, **kwargs):
    return _shard_cache(*args, source_run_id=34225525473, source_head_sha="de0bcfffafe1feb04cd23b2ad560a50d050a42fd", **kwargs)


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
                "fact_rows": 2,
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
        "parser_contract": PARSER_CONTRACT,
        "metric_catalog_sha256": METRIC_CATALOG_SHA256,
        "metric_catalog": METRIC_CATALOG,
        "failures": [],
        "failure_class_counts": {},
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

    assert manifest["schema_version"] == "BLOCK_IDX_FINANCIAL_FACT_MANIFEST_V5_3"
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
    with pytest.raises(ValueError, match="failed filing count"):
        shard_cache(source, tmp_path / "shards")


def _with_exclusion():
    p = _source_payload()
    p['selected_filing_rows'] = 6
    p['failed_filing_rows'] = 1
    p['failure_class_counts'] = {'OFFICIAL_ATTACHMENT_UNAVAILABLE_CONFIRMED': 1}
    p['failures'] = [{
        'filing_id': 'BLOCKIDX-FILING-excluded', 'ticker': 'EXCL',
        'failure_class': 'OFFICIAL_ATTACHMENT_UNAVAILABLE_CONFIRMED',
        'retryable': False, 'point_in_time_identity_preserved': True,
        'file_url': 'https://www.idx.co.id/exact/instance.zip',
        'published_at': '2026-08-01T00:00:00+07:00',
        'exact_profile_resolution_state': 'EXACT_PROFILE_ANNOUNCEMENT_ATTACHMENT',
        'exact_profile_announcement_id': 'original-identity',
        'exact_profile_resolved_file_url': 'https://www.idx.co.id/exact/instance.zip',
        'classification_reason': 'Exact official identity confirmed; exact attachment unavailable',
        'official_mirror_attempts': [{'status': 404, 'url': 'https://block.idx.id/exact/instance.zip'}],
    }]
    return p


def test_permanent_exclusions_survive_byte_identical_rerun(tmp_path):
    p = _with_exclusion()
    source = tmp_path / 'cache.json'
    source.write_text(json.dumps(p))
    manifest = shard_cache(source, tmp_path / 'a', filings_per_shard=2)
    shard_cache(source, tmp_path / 'b', filings_per_shard=2)
    assert manifest['selected_filing_rows'] == manifest['parsed_filing_rows'] + manifest['permanent_excluded_filing_rows']
    assert manifest['failed_filing_rows'] == 1
    assert json.loads((tmp_path / 'a/exclusions.json').read_text())['rows'] == p['failures']
    for path in (tmp_path / 'a').iterdir():
        assert path.read_bytes() == (tmp_path / 'b' / path.name).read_bytes()
    with pytest.raises(ValueError, match='never overwritten'):
        shard_cache(source, tmp_path / 'a')


@pytest.mark.parametrize('field,value,reason', [
    ('retryable', True, 'retryable'),
    ('failure_class', 'PARSER_OR_CONTRACT_FAILURE', 'parser'),
    ('point_in_time_identity_preserved', False, 'PIT'),
    ('classification_reason', '', 'provenance'),
    ('exact_profile_announcement_id', None, 'exact identity'),
])
def test_invalid_exclusion_fails_closed(tmp_path, field, value, reason):
    p = _with_exclusion()
    p['failures'][0][field] = value
    source = tmp_path / 'cache.json'
    source.write_text(json.dumps(p))
    with pytest.raises(ValueError, match=reason):
        shard_cache(source, tmp_path / 'out')


@pytest.mark.parametrize('case', ['overlap', 'duplicate_exclusion', 'duplicate_fact', 'catalog', 'reconciliation', 'hash'])
def test_integrity_corruption_fails_closed(tmp_path, case):
    p = _with_exclusion()
    if case == 'overlap':
        p['failures'][0]['filing_id'] = p['filing_telemetry'][0]['filing_id']
    elif case == 'duplicate_exclusion':
        p['failures'].append(dict(p['failures'][0]))
    elif case == 'duplicate_fact':
        p['rows'].append(dict(p['rows'][0]))
    elif case == 'catalog':
        p['metric_catalog_sha256'] = '0' * 64
    elif case == 'reconciliation':
        p['selected_filing_rows'] = p['parsed_filing_rows']
    else:
        p['filing_telemetry'][0]['content_hash'] = 'f' * 64
    source = tmp_path / 'cache.json'
    source.write_text(json.dumps(p))
    with pytest.raises(ValueError):
        shard_cache(source, tmp_path / 'out')
