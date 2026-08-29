from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MIGRATION = ROOT / "supabase" / "migrations" / "20260829081500_canonical_cache_pull_sync.sql"


def test_canonical_cache_sync_is_backend_only_and_provenance_guarded():
    sql = MIGRATION.read_text(encoding="utf-8")
    for fn in ("flow_sync_canonical_ohlcv_recent", "flow_sync_zapi_foreign_cache"):
        assert f"security definer" in sql.lower()
        assert f"revoke all on function public.{fn}() from public;" in sql
        assert f"revoke all on function public.{fn}() from anon;" in sql
        assert f"revoke all on function public.{fn}() from authenticated;" in sql
        assert f"grant execute on function public.{fn}() to service_role;" in sql
    assert "VERIFIED_ZAPI_IDX_SHARE_FLOW_NOT_BROKER_IDENTITY" in sql
    assert "source in ('ZAPI_IDX_FOREIGN_FLOW','ZAPI_IDX_STOCK_SUMMARY')" in sql
    assert "'CANONICAL_GITHUB_EOD_SEED'" in sql
    assert "high >= greatest(open, close)" in sql
    assert "low <= least(open, close)" in sql
