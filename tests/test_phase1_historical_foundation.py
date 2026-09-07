from pathlib import Path


MIGRATION = Path(
    "supabase/migrations/20260907003000_phase1_official_historical_foundation.sql"
)


def _sql() -> str:
    return MIGRATION.read_text(encoding="utf-8")


def test_phase1_migration_is_flow_namespaced_and_official_only():
    sql = _sql()
    assert "flow_official_stock_summary" in sql
    assert "flow_backfill_official_idx_phase1" in sql
    assert "flow_phase1_historical_coverage" in sql
    assert "https://block.idx.id/primary/TradingSummary/GetStockSummary" in sql
    assert "IDX_OFFICIAL_STOCK_SUMMARY" in sql
    assert "VERIFIED_OFFICIAL_IDX_STOCK_SUMMARY_RAW_PANEL" in sql
    assert "mbtsvflwszcgdtijdgas" not in sql


def test_raw_stock_panel_keeps_fields_needed_for_future_affinity_research():
    sql = _sql().lower()
    for field in (
        "previous numeric",
        "open numeric",
        "high numeric",
        "low numeric",
        "close numeric",
        "volume numeric",
        "traded_value numeric",
        "frequency numeric",
        "foreign_buy numeric",
        "foreign_sell numeric",
        "listed_shares numeric",
        "tradable_shares numeric",
    ):
        assert field in sql


def test_stock_refresh_fails_closed_on_incomplete_or_wrong_date_payload():
    sql = _sql()
    assert "api_rows <> records_total" in sql
    assert "api_rows < 800" in sql
    assert "payload_min is distinct from p_date" in sql
    assert "payload_max is distinct from p_date" in sql
    assert "source_verified boolean not null default true" in sql


def test_backfill_is_chunk_limited_and_audited():
    sql = _sql()
    assert "(p_end_date-p_start_date) > 31" in sql
    assert "flow_ingestion_audit" in sql
    assert "PHASE1_HISTORICAL_FOUNDATION" in sql
    assert "exception when others" in sql.lower()


def test_phase1_does_not_modify_scoring_contract():
    sql = _sql().lower()
    forbidden = (
        "broker_behavior_overlay_weight",
        "decision_score_floor",
        "production_authorized",
        "execution_ready",
        "final_score",
    )
    for token in forbidden:
        assert token not in sql


def test_raw_stock_daily_schedule_is_after_foreign_and_before_broker():
    sql = _sql()
    assert "flow-official-idx-stock-raw-daily" in sql
    assert "'48 10 * * 1-5'" in sql
