from pathlib import Path

from idx_flow_scanner.providers.block_idx_financial_facts import (
    METRIC_CATALOG,
    METRIC_CATALOG_SHA256,
)


ROOT = Path(__file__).resolve().parents[1]
SCHEMA = ROOT / "supabase/migrations/20260908093000_block_idx_financial_fact_cache.sql"
MANIFEST = ROOT / "supabase/migrations/20260908093100_block_idx_financial_fact_manifest.sql"
INGEST = ROOT / "supabase/migrations/20260908093200_block_idx_financial_fact_shard_ingest.sql"
AUDIT = ROOT / "supabase/migrations/20260908093300_block_idx_financial_fact_audit.sql"
PUBLISHER = ROOT / ".github/workflows/publish-financial-facts-artifact.yml"


def _read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def test_metric_catalog_migration_matches_parser_catalog() -> None:
    sql = _read(SCHEMA)
    assert len(METRIC_CATALOG) == 19
    assert METRIC_CATALOG_SHA256 == "fdb22a134597d5161632aedef260fdaf9342f997aa55c4d11e670043a372b930"
    assert METRIC_CATALOG_SHA256 in sql
    for metric_key, config in METRIC_CATALOG.items():
        assert f"('{metric_key}'" in sql
        assert str(config["label"]).replace("'", "''") in sql
        for concept in config["concepts"]:
            assert f"'{concept}'" in sql


def test_ingest_is_sharded_content_addressed_and_not_main_cache() -> None:
    combined = "\n".join(_read(path) for path in (SCHEMA, MANIFEST, INGEST, AUDIT))
    assert "raw.githubusercontent.com/rizanrizan93/idx-flow-scanner/main/" not in combined
    assert "block_idx_financial_facts.json" not in combined
    assert "flow_financial_fact_manifest_v5" in combined
    assert "flow_financial_fact_shard_ingest_v5" in combined
    assert "flow_financial_fact_manifest_filing_v5" in combined
    assert "FINANCIAL_FACT_SHARD_SHA_MISMATCH" in combined
    assert "FINANCIAL_FACT_SHARD_BYTE_COUNT_MISMATCH" in combined
    assert "FINANCIAL_FACT_SHARD_EXISTING_FACT_CONFLICT" in combined
    assert "FINANCIAL_FACT_SHARD_FACT_ID_COLLISION" in combined
    assert "production_scoring_changed" in combined


def test_database_functions_are_invoker_only_with_empty_search_path() -> None:
    for path in (MANIFEST, INGEST, AUDIT):
        sql = _read(path).lower()
        assert "security definer" not in sql
        assert "security invoker" in sql
        assert "set search_path = ''" in sql
        assert "from public, anon, authenticated" in sql
        assert "to service_role" in sql


def test_manifest_requires_immutable_commit_and_source_run_provenance() -> None:
    sql = _read(MANIFEST)
    assert "raw\\.githubusercontent\\.com/rizanrizan93/idx-flow-scanner/[0-9a-f]{40}" in sql
    assert "artifact_meta.json" in sql
    assert "source_run_id" in sql
    assert "source_head_sha" in sql
    assert "FINANCIAL_FACT_ARTIFACT_META_CONTRACT_MISMATCH" in sql
    assert "FINANCIAL_FACT_MANIFEST_PROVENANCE_CONFLICT" in sql


def test_publisher_reverifies_artifact_before_artifact_branch_push() -> None:
    workflow = _read(PUBLISHER)
    assert "actions: read" in workflow
    assert "contents: write" in workflow
    assert "gh run download" in workflow
    assert "status=$STATUS conclusion=$CONCLUSION" in workflow
    assert "hashlib.sha256(data).hexdigest()" in workflow
    assert "aggregate filing count mismatch" in workflow
    assert "aggregate fact count mismatch" in workflow
    assert "evidence-v5/financial-facts-artifacts" in workflow
    assert "source_head_sha" in workflow


def test_audit_separates_revision_duplicates_from_key_corruption() -> None:
    sql = _read(AUDIT)
    assert "duplicate_filing_metric_rows" in sql
    assert "revision_period_metric_groups" in sql
    assert "equal_value_revision_groups" in sql
    assert "revision_groups_are_informational" in sql
    assert "publication_before_period_end_rows" in sql
    assert "bad_unit_rows" in sql
    assert "bad_catalog_rows" in sql
