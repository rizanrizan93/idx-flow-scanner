from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MIGRATION = (
    ROOT
    / "supabase"
    / "migrations"
    / "20260910090000_vendor_foreign_canonical_view_v1.sql"
)


def _sql() -> str:
    return MIGRATION.read_text(encoding="utf-8")


def test_vendor_foreign_compaction_is_fail_closed():
    sql = _sql()
    required = [
        "vendor foreign compaction denied: % FK references exist",
        "vendor foreign compaction denied: % rows use unknown sources",
        "vendor foreign compaction denied: % overlapping official rows differ",
        "foreign_buy is distinct from s.foreign_buy",
        "foreign_sell is distinct from s.foreign_sell",
        "v.volume is distinct from s.volume",
        "v.traded_value is distinct from s.traded_value",
    ]
    for marker in required:
        assert marker in sql


def test_vendor_foreign_read_contract_is_preserved_as_security_invoker_view():
    sql = _sql()
    assert "alter table public.flow_vendor_foreign_flows\n  rename to flow_vendor_foreign_transport_v1;" in sql
    assert "create view public.flow_vendor_foreign_flows\nwith (security_invoker=true)" in sql
    assert "from public.flow_official_stock_summary s" in sql
    assert "from public.flow_vendor_foreign_transport_v1 t" in sql
    assert "grant select on table public.flow_vendor_foreign_flows to service_role;" in sql


def test_compaction_preserves_nonredundant_transport_and_exact_logical_row_count():
    sql = _sql()
    assert "where v.source<>'IDX_OFFICIAL_STOCK_SUMMARY'" in sql
    assert "source like 'ZAPI_%'" in sql
    assert "unmatched_official_transport_rows_preserved" in sql
    assert "if v_before<>v_logical then" in sql
    assert "logical compatibility row count changed" in sql
    assert "removed_redundant_rows" in sql
    assert "retained_sha256" in sql


def test_future_ingestion_does_not_rematerialize_official_duplicate_rows():
    sql = _sql()
    refresh_start = sql.index("create or replace function public.flow_refresh_official_idx_foreign(")
    zapi_start = sql.index("create or replace function public.flow_sync_zapi_foreign_cache()")
    refresh_sql = sql[refresh_start:zapi_start]
    assert "flow_official_stock_summary" in refresh_sql
    assert "flow_vendor_foreign_official_transport_meta_v1" in refresh_sql
    assert "insert into public.flow_vendor_foreign_transport_v1" not in refresh_sql

    zapi_sql = sql[zapi_start:]
    assert "insert into public.flow_vendor_foreign_transport_v1" in zapi_sql
    assert "source in('ZAPI_IDX_FOREIGN_FLOW','ZAPI_IDX_STOCK_SUMMARY')" in zapi_sql


def test_compaction_manifest_stays_shadow_safe_and_auditable():
    sql = _sql()
    assert "flow_vendor_foreign_compaction_manifest_v1" in sql
    assert "mismatch_rows bigint not null check(mismatch_rows=0)" in sql
    assert "production_influence_enabled boolean not null default false" in sql
    assert "check(production_influence_enabled=false)" in sql
    assert "foreign_values_exact_match_precondition',true" in sql
    assert "volume_value_exact_match_precondition',true" in sql
