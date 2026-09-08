from pathlib import Path

MIGRATION = Path("supabase/migrations/20260908070500_block_idx_historical_financial_cache.sql")


def test_historical_financial_cache_ingest_is_fixed_url_and_fail_closed() -> None:
    sql = MIGRATION.read_text(encoding="utf-8")
    assert "flow_refresh_block_idx_historical_financial_cache_v5()" in sql
    assert "raw.githubusercontent.com/rizanrizan93/idx-flow-scanner/main/data/cache/evidence_v5/block_idx_historical_financial_filings.json" in sql
    assert "BLOCK_IDX_HISTORICAL_FINANCIAL_FILING_CACHE_V5_2" in sql
    assert "PROFILE_ANNOUNCEMENT_PIT_ATTACHMENT_IDENTITY_WITH_LATEST_REPORT_CORROBORATION" in sql
    assert "EVERY_FINANCIAL_ANNOUNCEMENT_REVISION_RETAINED_WHEN_PERIOD_IS_VERIFIABLE" in sql
    assert "public.flow_idx_official_url_v5" in sql
    assert "v_pub::date < v_period_end" in sql
    assert "'.xlsx','.xls','.zip','.xml','.xhtml'" in sql
    assert "production_scoring_changed',false" in sql


def test_historical_financial_ingest_is_service_role_only() -> None:
    sql = MIGRATION.read_text(encoding="utf-8")
    assert "security invoker" in sql.lower()
    assert "revoke all on function public.flow_refresh_block_idx_historical_financial_cache_v5() from public,anon,authenticated" in sql
    assert "grant execute on function public.flow_refresh_block_idx_historical_financial_cache_v5() to service_role" in sql


def test_ingest_preserves_parsed_state_on_refresh() -> None:
    sql = MIGRATION.read_text(encoding="utf-8")
    assert "('PARSED','FACTS_PARSED')" in sql
    assert "coalesce(excluded.content_hash,public.flow_financial_filing_evidence_v5.content_hash)" in sql
