from pathlib import Path


MIGRATION = Path(
    "supabase/migrations/20260907043000_phase3b_ticker_affinity_consensus_shadow.sql"
)


def _sql() -> str:
    return MIGRATION.read_text(encoding="utf-8")


def test_phase3b_counts_each_active_broker_once_across_lags():
    sql = _sql()
    assert "pair_agg" in sql
    assert "group by a.broker_code,a.ticker" in sql
    assert "count(distinct a.lag_sessions)" in sql
    assert "bool_or(a.lag_sessions=0)" in sql
    assert "bool_or(a.lag_sessions=1)" in sql
    assert "bool_or(a.lag_sessions=2)" in sql
    assert "bool_or(a.lag_sessions=5)" in sql


def test_phase3b_active_cohort_is_mature_residual_activity():
    sql = _sql()
    assert "feature_quality_state='MATURE'" in sql
    assert "residual_activity_z>=1.5" in sql
    assert "activity_share_pct" in sql
    assert "active_broker_activity_share_pct" in sql


def test_phase3b_uses_only_stable_or_recent_strengthening_affinity():
    sql = _sql()
    assert "stability_state in ('STABLE','RECENT_STRENGTHENING')" in sql
    assert "CO_ACTIVITY_AFFINITY_NOT_BUY_SELL" in sql
    assert "DECAYING" not in sql.replace("--", "")


def test_phase3b_has_count_and_activity_weighted_breadth():
    sql = _sql()
    assert "raw_affinity_breadth_pct" in sql
    assert "activity_weighted_breadth_pct" in sql
    assert "matched_activity_share" in sql
    assert "100::numeric*t.matched_brokers/active_n::numeric" in sql
    assert "100::numeric*t.matched_activity_share/nullif(active_share,0)" in sql


def test_phase3b_proxy_is_shadow_broker_affinity_only():
    sql = _sql()
    assert "broker_consensus_proxy_score" in sql
    assert "30_BREADTH_CAP40__25_WEIGHTED_BREADTH_CAP35__20_AFFINITY_QUALITY__15_MULTI_LAG__10_STABILITY" in sql
    assert "foreign_and_stock_fields_confirmation_only" in sql
    assert "Foreign/stock-flow fields are retained as confirmation evidence only" in sql
    assert "no_production_scoring_change" in sql
    assert "final_score" not in sql.replace("-- This remains SHADOW research. It does NOT change final_score, production scoring,", "")
    assert "production_authorized" not in sql
    assert "BROKER_BEHAVIOR_OVERLAY_WEIGHT" not in sql


def test_phase3b_retains_stock_and_foreign_confirmation_without_weighting_them():
    sql = _sql()
    assert "stock_residual_activity_z" in sql
    assert "turnover_residual_z" in sql
    assert "volume_residual_z" in sql
    assert "frequency_residual_z" in sql
    assert "foreign_net_volume_pct" in sql
    assert "return_pct" in sql
    score_section = sql.split("), scored as (", 1)[1].split("from metrics m", 1)[0]
    assert "foreign_net_volume_pct" not in score_section
    assert "return_pct" not in score_section
    assert "stock_residual_activity_z" not in score_section


def test_phase3b_quality_gate_requires_current_phase3a_and_private_tables():
    sql = _sql()
    assert "flow_phase3b_quality_summary" in sql
    assert "PHASE3B_READY" in sql
    assert "s.as_of_date=p.phase3a_as_of_date" in sql
    assert "s.active_broker_count between 10 and 60" in sql
    assert "s.consensus_ticker_count>=100" in sql
    assert "c.bad_semantics_rows=0" in sql
    assert "enable row level security" in sql
    assert "from public, anon, authenticated" in sql
    assert "to service_role" in sql


def test_phase3b_daily_refresh_runs_after_phase3a():
    sql = _sql()
    assert "flow-ticker-affinity-consensus-v3-shadow-daily" in sql
    assert "18 11 * * 1-5" in sql
    assert "flow_refresh_ticker_affinity_consensus_v3" in sql
