from pathlib import Path


MIGRATION = Path(
    "supabase/migrations/20260907031500_phase2c_stock_residualization_shadow.sql"
)


def _sql() -> str:
    return MIGRATION.read_text(encoding="utf-8")


def test_phase2c_is_shadow_and_official_stock_only():
    sql = _sql()
    assert "flow_stock_residual_activity_v2" in sql
    assert "IDX_OFFICIAL_STOCK_SUMMARY" in sql
    assert "SHADOW_DERIVED_FROM_VERIFIED_OFFICIAL_IDX_STOCK_SUMMARY" in sql
    assert "DAILY_SECTOR_X_VOLATILITY_QUINTILE_ROBUST_LOG_ACTIVITY" in sql
    assert "no_production_scoring_change" in sql


def test_phase2c_residualizes_market_sector_and_volatility_without_fabricating_sector():
    sql = _sql()
    assert "left join public.flow_issuers i on i.ticker=s.ticker" in sql
    assert "ntile(5) over(order by b.volatility_range_pct,b.ticker)" in sql
    assert "market_total_value" in sql
    assert "sector_total_value" in sql
    assert "bucket_stats" in sql
    assert "sector_stats" in sql
    assert "market_stats" in sql
    assert "MARKET_FALLBACK" in sql
    assert "SECTOR_FALLBACK" in sql
    assert "FULL" in sql


def test_phase2c_uses_robust_log_activity_residuals():
    sql = _sql()
    assert "ln(1::numeric+s.traded_value)" in sql
    assert "ln(1::numeric+s.volume)" in sql
    assert "ln(1::numeric+s.frequency)" in sql
    assert "flow_robust_z_from_stats" in sql
    assert "turnover_residual_z" in sql
    assert "volume_residual_z" in sql
    assert "frequency_residual_z" in sql
    assert "stock_residual_activity_z" in sql
    assert "-8::numeric" in sql
    assert "8::numeric" in sql


def test_phase2c_preserves_foreign_and_price_context_for_future_affinity():
    sql = _sql()
    for field in (
        "foreign_buy",
        "foreign_sell",
        "foreign_net",
        "foreign_net_volume_pct",
        "return_pct",
        "volatility_range_pct",
        "market_turnover_share_pct",
        "sector_turnover_share_pct",
    ):
        assert field in sql


def test_phase2c_backfill_and_quality_gate_are_bounded():
    sql = _sql()
    assert "flow_backfill_stock_residual_activity_v2" in sql
    assert "backfill window exceeds 31 calendar days" in sql
    assert "flow_phase2c_quality_summary" in sql
    assert "q.residual_sessions>=250" in sql
    assert "q.residual_rows>=240000" in sql
    assert "q.null_residual_rows=0" in sql
    assert "q.unverified_rows=0" in sql
    assert "<=1" in sql
    assert "PHASE2C_READY" in sql
    assert "flow_phase2_quality_summary" in sql
    assert "PHASE2_READY" in sql


def test_phase2c_daily_refresh_is_after_phase2ab_and_before_shareholder_job():
    sql = _sql()
    assert "flow-stock-residual-v2-shadow-daily" in sql
    assert "12 11 * * 1-5" in sql


def test_phase2c_does_not_touch_production_scoring_or_execution():
    sql = _sql()
    assert "final_score" not in sql
    assert "BROKER_BEHAVIOR_OVERLAY_WEIGHT" not in sql
    assert "production_authorized" not in sql
    assert "execution_ready" not in sql
