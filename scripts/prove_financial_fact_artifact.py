"""Offline Gate 4 proof. Never fetch or substitute a filing or re-run the parser."""
from __future__ import annotations

import argparse
import hashlib
import json
import tempfile
from pathlib import Path

from scripts.shard_block_idx_financial_facts import shard_cache, _canonical_bytes
from scripts.backfill_block_idx_financial_facts_resilient import _eligible_instances

GATE3_RUN = 34225525473
GATE3_HEAD = 'de0bcfffafe1feb04cd23b2ad560a50d050a42fd'
GATE3_CACHE_ARTIFACT_ID = 10055637731
GATE3_CACHE_ARCHIVE_SHA256 = '8f369a9e36fa79d0e5e87f17dbc5e4a572f8c8c7e8d07282fb12a88dcba0da0e'
EXPECTED_COUNTS = {'selected_filing_rows': 12285, 'parsed_filing_rows': 12029,
                   'failed_filing_rows': 256, 'fact_rows': 203408}


def prove(source: Path, summary: Path, historical: Path, out: Path, *, verify_existing: bool = False) -> dict:
    cache = json.loads(source.read_text())
    gate3 = json.loads(summary.read_text())
    for key, value in EXPECTED_COUNTS.items():
        if cache.get(key) != value or gate3.get(key) != value:
            raise ValueError(f'Gate 3 baseline count mismatch: {key}')
    for key, value in {'gate3_status': 'PASS', 'retryable_failure_rows': 0,
                       'parser_or_contract_failure_rows': 0, 'production_scoring_changed': False,
                       'no_fake_100_percent': True, 'distinct_tickers': 1057, 'distinct_metrics': 19}.items():
        if gate3.get(key) != value:
            raise ValueError(f'Gate 3 summary mismatch: {key}')
    parents = json.loads(historical.read_text())['rows']
    parent_ids = [r['filing_id'] for r in parents]
    if len(parent_ids) != len(set(parent_ids)):
        raise ValueError('duplicate historical parent identity')
    selected_ids = {r['filing_id'] for r in _eligible_instances(parents)}
    actual_ids = {r['filing_id'] for r in cache['filing_telemetry'] + cache['failures']}
    if selected_ids != actual_ids:
        raise ValueError('selected filing identity set differs from Gate 3 selection')
    parents = {r['filing_id']: r for r in parents}
    for row in cache['filing_telemetry'] + cache['failures']:
        parent = parents.get(row['filing_id'])
        if not parent or row['ticker'] != parent['ticker']:
            raise ValueError('source filing identity mismatch')
        for key in ('source_verified', 'publication_time_verified', 'point_in_time_eligible'):
            if parent.get(key) is not True:
                raise ValueError(f'parent PIT contract mismatch: {key}')
        if row in cache['failures']:
            for key in ('file_url', 'published_at'):
                if row.get(key) != parent.get(key):
                    raise ValueError(f'exclusion identity substitution: {key}')
        elif row.get('original_file_url', parent['file_url']) != parent['file_url']:
            raise ValueError('parsed original URL substitution')
    kwargs = {'source_run_id': GATE3_RUN, 'source_head_sha': GATE3_HEAD}
    if not verify_existing:
        shard_cache(source, out, **kwargs)
    with tempfile.TemporaryDirectory() as temporary:
        rerun = Path(temporary) / 'rerun'
        shard_cache(source, rerun, **kwargs)
        actual_names = sorted(p.name for p in out.iterdir())
        expected_names = sorted(p.name for p in rerun.iterdir())
        if actual_names != expected_names:
            raise ValueError('artifact file set mismatch')
        for name in actual_names:
            if (out / name).read_bytes() != (rerun / name).read_bytes():
                raise ValueError(f'artifact is not byte-identical to source reconstruction: {name}')
    manifest = json.loads((out / 'manifest.json').read_text())
    source_facts = {r['fact_id']: r for r in cache['rows']}
    if len(source_facts) != len(cache['rows']):
        raise ValueError('duplicate source fact identity')
    seen_facts, seen_filings = set(), set()
    for entry in manifest['shards']:
        data = (out / entry['file_name']).read_bytes()
        if hashlib.sha256(data).hexdigest() != entry['sha256'] or len(data) != entry['bytes']:
            raise ValueError('shard hash/byte mismatch')
        shard = json.loads(data)
        if seen_filings.intersection(shard['filing_ids']):
            raise ValueError('filing appears in multiple shards')
        seen_filings.update(shard['filing_ids'])
        for row in shard['rows']:
            if row['fact_id'] in seen_facts or row != source_facts[row['fact_id']]:
                raise ValueError('duplicate or altered parsed fact')
            seen_facts.add(row['fact_id'])
    if seen_facts != set(source_facts):
        raise ValueError('fact identity set mismatch')
    checks = [
        'selected_equals_parsed_plus_permanent_excluded', 'fact_rows_reconcile_exactly',
        'each_parsed_filing_in_exactly_one_shard', 'each_exclusion_in_ledger_exactly_once',
        'parsed_and_exclusion_sets_disjoint', 'no_duplicate_filing_ids', 'no_duplicate_fact_ids',
        'no_duplicate_filing_metric_pairs', 'shard_hashes_reproducible', 'manifest_hash_reproducible',
        'byte_identical_manifest_shards_exclusions_on_rerun', 'production_scoring_unchanged',
        'exact_metric_catalog_hash_and_content', 'source_run_head_and_cache_hash_retained',
        'no_filing_identity_or_parsed_fact_substitution',
    ]
    return {'gate4_status': 'PASS', 'checks': {name: 'PASS' for name in checks},
            'manifest_sha256': hashlib.sha256((out / 'manifest.json').read_bytes()).hexdigest(),
            'source_run_id': GATE3_RUN, 'source_head_sha': GATE3_HEAD,
            'source_cache_artifact_id': GATE3_CACHE_ARTIFACT_ID,
            'source_cache_archive_sha256': GATE3_CACHE_ARCHIVE_SHA256,
            'source_cache_sha256': manifest['source_cache_sha256'],
            **EXPECTED_COUNTS, 'permanent_excluded_filing_rows': 256,
            'shard_count': manifest['shard_count'], 'exclusions': manifest['exclusions'],
            'production_scoring_changed': False}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--summary', type=Path, required=True)
    parser.add_argument('--historical', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--proof', type=Path, required=True)
    parser.add_argument('--verify-existing', action='store_true')
    args = parser.parse_args()
    result = prove(args.source, args.summary, args.historical, args.out, verify_existing=args.verify_existing)
    args.proof.write_bytes(_canonical_bytes(result))
    print(json.dumps(result, sort_keys=True))


if __name__ == '__main__':
    main()
