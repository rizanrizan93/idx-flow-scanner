from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MIGRATION = ROOT / "supabase/migrations/20260910123000_official_stock_summary_session_meta_v1.sql"


def _sql() -> str:
    return MIGRATION.read_text(encoding="utf-8")


def test_compaction_is_fail_closed_before_ddl() -> None:
    sql = _sql()
    for marker in (
        "expected physical table",
        "contract violations",
        "sessions have nonconstant source metadata",
        "% FK references exist",
        "% user triggers exist",
    ):
        assert marker in sql


def test_core_retains_all_market_fields_but_not_repeated_provenance() -> None:
    sql = _sql()
    start = sql.index("CREATE TABLE public.flow_official_stock_summary_core_v1(")
    end = sql.index("CREATE INDEX flow_official_stock_summary_core_v1_date_idx")
    ddl = sql[start:end]
    for retained in (
        "trade_date date NOT NULL",
        "ticker text NOT NULL",
        "stock_name text",
        "previous numeric",
        "open numeric",
        "high numeric",
        "low numeric",
        "close numeric NOT NULL",
        "foreign_buy numeric NOT NULL",
        "foreign_sell numeric NOT NULL",
        "non_regular_frequency numeric",
    ):
        assert retained in ddl
    for removed in ("source_url", "provenance_state", "ingested_at", "source_verified"):
        assert removed not in ddl


def test_session_metadata_is_one_row_per_trade_date() -> None:
    sql = _sql()
    assert "CREATE TABLE public.flow_official_stock_summary_session_meta_v1(" in sql
    assert "trade_date date PRIMARY KEY" in sql
    assert "source_url text NOT NULL" in sql
    assert "VERIFIED_OFFICIAL_IDX_STOCK_SUMMARY_RAW_PANEL" in sql


def test_compatibility_view_preserves_logical_name_and_provenance() -> None:
    sql = _sql()
    assert "CREATE VIEW public.flow_official_stock_summary\nWITH (security_invoker=true)" in sql
    assert "FROM public.flow_official_stock_summary_core_v1 c" in sql
    assert "JOIN public.flow_official_stock_summary_session_meta_v1 m USING(trade_date)" in sql
    assert "'IDX_OFFICIAL_STOCK_SUMMARY'::text AS source" in sql
    assert "true::boolean AS source_verified" in sql


def test_known_writer_is_rebound_to_physical_core_and_session_meta() -> None:
    sql = _sql()
    start = sql.index("CREATE OR REPLACE FUNCTION public.flow_refresh_official_idx_stock_summary(")
    end = sql.index("ALTER TABLE public.flow_official_stock_summary RENAME")
    writer = sql[start:end]
    assert "flow_official_stock_summary_session_meta_v1" in writer
    assert "flow_official_stock_summary_core_v1" in writer
    assert "INSERT INTO public.flow_official_stock_summary\n" not in writer
    assert "ON CONFLICT(trade_date,ticker) DO UPDATE" in writer


def test_generic_view_writes_are_guarded_and_dependent_views_rebound() -> None:
    sql = _sql()
    assert "flow_official_stock_summary_compat_iud_v1" in sql
    assert "session metadata differs" in sql
    assert "primary key change" in sql
    save = sql.index("CREATE TEMPORARY TABLE flow_official_stock_summary_dependent_views_v1")
    rename = sql.index("RENAME TO flow_official_stock_summary_legacy_v1")
    rebind = sql.index("FOR r IN SELECT * FROM flow_official_stock_summary_dependent_views_v1")
    drop = sql.index("DROP TABLE public.flow_official_stock_summary_legacy_v1 RESTRICT")
    assert save < rename < rebind < drop


def test_manifest_requires_exact_row_session_and_sha_parity() -> None:
    sql = _sql()
    assert "logical_sha256_before" in sql
    assert "logical_sha256_after" in sql
    assert "v_before<>v_after" in sql
    assert "v_expected_sessions<>v_sessions" in sql
    assert "v_sha_before IS DISTINCT FROM v_sha_after" in sql
    assert "production_influence_enabled boolean NOT NULL DEFAULT false" in sql
    assert "CHECK(production_influence_enabled=false)" in sql


def test_security_and_storage_registry_remain_fail_closed() -> None:
    sql = _sql()
    assert "ENABLE ROW LEVEL SECURITY" in sql
    assert "FROM public,anon,authenticated" in sql
    assert "RETAIN_CANONICAL_PIT_SOURCE; DO NOT REMOVE" in sql
    assert "LOSSLESS_NORMALIZED_REPRESENTATION" in sql
    assert "SELECT public.flow_refresh_storage_registry_v1();" in sql
    assert "SELECT public.flow_refresh_storage_date_ranges_v1();" in sql
