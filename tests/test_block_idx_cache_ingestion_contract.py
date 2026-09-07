from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MIGRATION = ROOT / "supabase" / "migrations" / "20260908033500_block_idx_cache_ingestion.sql"


def test_block_idx_cache_ingestion_is_fixed_repo_only_and_private() -> None:
    text = MIGRATION.read_text(encoding="utf-8")
    compact = "".join(text.split()).lower()
    assert "raw.githubusercontent.com/rizanrizan93/idx-flow-scanner/main/data/cache/evidence_v5" in text
    assert "flow_refresh_block_idx_cache_v5()" in text
    assert "flow_idx_official_url_v5" in text
    assert "^https://(www\\.)?idx\\.co\\.id/" in text
    assert "^https://block\\.idx\\.id/" in text
    assert "published_at" in text
    assert "report_period_end" in text
    assert "production_scoring_changed',false" in compact
    assert "frompublic,anon,authenticated" in compact
    # No caller-controlled URL parameter is accepted by the refresh function.
    assert "flow_refresh_block_idx_cache_v5(p_" not in text


def test_ingestion_targets_only_v5_evidence_tables() -> None:
    text = MIGRATION.read_text(encoding="utf-8")
    assert "flow_disclosure_evidence_v5" in text
    assert "flow_financial_filing_evidence_v5" in text
    assert "flow_scan_results" not in text
    assert "flow_phase4e_candidate_registry_v4" not in text
