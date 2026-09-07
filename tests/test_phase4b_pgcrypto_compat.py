from pathlib import Path


def test_phase4b_manifest_function_can_resolve_pgcrypto_digest():
    sql = Path(
        "supabase/migrations/20260907065500_phase4b_pgcrypto_search_path.sql"
    ).read_text(encoding="utf-8")
    assert "flow_capture_market_memory_manifest_v4(date,text)" in sql
    assert "search_path=pg_catalog,public,extensions" in sql.replace(" ", "")
