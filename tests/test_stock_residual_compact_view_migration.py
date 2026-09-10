from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MIGRATION = ROOT / "supabase/migrations/20260910044236_stock_residual_compact_view_v1.sql"


def _sql() -> str:
    return MIGRATION.read_text(encoding="utf-8")


def test_residual_compaction_fails_closed_on_integrity_drift() -> None:
    sql = _sql()
    for marker in (
        "residual compaction denied: % FK references exist",
        "residual compaction denied: % user triggers exist",
        "rows violate frozen provenance constants",
        "missing canonical %, raw mismatches %",
        "r.previous is distinct from s.previous",
        "r.foreign_net is distinct from (s.foreign_buy-s.foreign_sell)::numeric",
    ):
        assert marker in sql


def test_compact_physical_table_does_not_duplicate_canonical_raw_or_constant_provenance() -> None:
    sql = _sql()
    start = sql.index("create table public.flow_stock_residual_activity_compact_v1(")
    end = sql.index("create index flow_stock_residual_activity_compact_v1_date_quality_idx")
    compact_ddl = sql[start:end]
    for duplicated in (
        "previous numeric",
        "close numeric",
        "high numeric",
        "low numeric",
        "traded_value numeric",
        "volume numeric",
        "frequency numeric",
        "foreign_buy numeric",
        "foreign_sell numeric",
        "foreign_net numeric",
        "residualization_basis",
        "source_verified",
        "source_dataset",
        "provenance_state",
    ):
        assert duplicated not in compact_ddl
    for retained in (
        "sector text",
        "subsector text",
        "return_pct numeric",
        "stock_residual_activity_z numeric",
        "residual_quality_state text",
        "computed_at timestamptz",
    ):
        assert retained in compact_ddl


def test_compatibility_view_reconstructs_exact_raw_contract_from_official_source() -> None:
    sql = _sql()
    assert "create view public.flow_stock_residual_activity_v2\nwith (security_invoker=true)" in sql
    assert "from public.flow_stock_residual_activity_compact_v1 c" in sql
    assert "join public.flow_official_stock_summary s" in sql
    assert "and s.source='IDX_OFFICIAL_STOCK_SUMMARY' and s.source_verified" in sql
    assert "'DERIVED_IDX_OFFICIAL_STOCK_RESIDUAL_V2'::text as source" in sql
    assert "'SHADOW_DERIVED_FROM_VERIFIED_OFFICIAL_IDX_STOCK_SUMMARY'::text as provenance_state" in sql


def test_existing_refresh_writer_is_supported_by_guarded_view_trigger() -> None:
    sql = _sql()
    assert "create function public.flow_stock_residual_activity_v2_compat_iud_v1()" in sql
    assert "if tg_op='DELETE' then" in sql
    assert "residual compatibility insert denied: canonical official row missing" in sql
    assert "residual compatibility insert denied: raw official fields differ" in sql
    assert "residual compatibility insert denied: provenance contract mismatch" in sql
    assert "insert into public.flow_stock_residual_activity_compact_v1(" in sql
    assert "instead of insert or delete on public.flow_stock_residual_activity_v2" in sql


def test_dependent_views_are_rebound_before_restrict_drop() -> None:
    sql = _sql()
    save = sql.index("create temporary table flow_stock_residual_dependent_views_v1")
    rename = sql.index("rename to flow_stock_residual_activity_legacy_v2")
    rebind = sql.index("for r in select * from flow_stock_residual_dependent_views_v1")
    drop = sql.index("drop table public.flow_stock_residual_activity_legacy_v2 restrict")
    assert save < rename < rebind < drop
    assert "alter view %I.%I set (security_invoker=true)" in sql


def test_dynamic_digest_and_manifest_preserve_full_pit_panel() -> None:
    sql = _sql()
    assert "dynamic_sha256" in sql
    assert "dynamic_sha256_before" in sql
    assert "dynamic_sha256_after" in sql
    assert "full_pit_row_count_preserved',true" in sql
    assert "derived_metrics_retained_physically_without_recomputation',true" in sql
    assert "production_influence_enabled boolean not null default false" in sql
    assert "check(production_influence_enabled=false)" in sql


def test_storage_registry_tracks_new_physical_backing_without_authorizing_removal() -> None:
    sql = _sql()
    assert "object_name='flow_stock_residual_activity_compact_v1'" in sql
    assert "storage_class='DERIVABLE'" in sql
    assert "RETAIN_FULL_PIT_DERIVED_PANEL; DO NOT REMOVE WITHOUT OBJECT_SPECIFIC_PROOF" in sql
    assert "select public.flow_refresh_storage_registry_v1();" in sql
    assert "select public.flow_refresh_storage_date_ranges_v1();" in sql
