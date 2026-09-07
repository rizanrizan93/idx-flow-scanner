from pathlib import Path


MIGRATION = Path(
    "supabase/migrations/20260907065000_phase4b_market_outcome_memory.sql"
)
SQL = MIGRATION.read_text(encoding="utf-8")


def test_phase4b_uses_storage_efficient_manifest_not_duplicate_panel():
    assert "flow_market_memory_manifest_v4" in SQL
    assert "MANIFEST_PLUS_VERSIONED_VIEWS_NO_RAW_PANEL_DUPLICATION" in SQL
    assert "flow_market_learning_panel_v4" in SQL
    assert "flow_market_learning_outcomes_v4" in SQL
    assert "create table if not exists public.flow_market_learning_panel_v4" not in SQL.lower()


def test_manifest_is_immutable_and_versioned():
    assert "primary key (as_of_date, feature_contract)" in SQL
    assert "MARKET_MEMORY_V4_1" in SQL
    assert "on conflict (as_of_date,feature_contract) do nothing" in SQL
    assert "HISTORICAL_RECONSTRUCTION" in SQL
    assert "LIVE_CAPTURE" in SQL


def test_core_market_memory_fails_closed_on_bad_official_evidence():
    assert "v_stock_rows < 800" in SQL
    assert "v_residual_rows < 800" in SQL
    assert "v_regime_rows <> 1" in SQL
    assert "source_url not like 'https://block.idx.id/%'" in SQL
    assert "CORE_NOT_READY" in SQL


def test_features_are_asof_only_and_future_data_lives_in_outcome_view():
    assert "p.observed_on<=m.as_of_date" in SQL
    assert "coalesce(a.publication_date,a.event_date) <= m.as_of_date" in SQL
    assert "e.event_date between m.as_of_date-30 and m.as_of_date" in SQL
    assert "OFFICIAL_IDX_FORWARD_OUTCOME_NOT_FEATURE" in SQL
    assert "Outcomes are targets only and must never feed the originating feature row" in SQL


def test_panel_contains_market_flow_broker_and_slow_evidence():
    required = [
        "stock_residual_activity_z",
        "foreign_net_volume_pct",
        "market_activity_intensity_z",
        "phase3a_score",
        "phase3b_score",
        "phase3c_score",
        "advanced_broker_score",
        "risk_event_20d_count",
        "capital_action_90d_count",
        "controller_ownership_pct",
    ]
    for name in required:
        assert name in SQL


def test_outcome_memory_has_multi_horizon_profit_loss_and_multibagger_labels():
    for horizon in ("1d", "5d", "10d", "20d", "60d", "120d", "250d"):
        assert f"forward_return_{horizon}_pct" in SQL
    assert "mfe_20d_pct" in SQL
    assert "mae_20d_pct" in SQL
    assert "mfe_250d_pct" in SQL
    assert "mae_250d_pct" in SQL
    assert "hit_up_100pct_250d" in SQL
    assert "close_multibagger_250d" in SQL
    assert "hit_down_30pct_120d" in SQL
    assert "alpha_vs_ihsg_250d_pct" in SQL
    assert "alpha_vs_sector_250d_pct" in SQL


def test_phase4b_keeps_semantics_and_current_sector_limitation_explicit():
    assert "STATISTICAL_CO_ACTIVITY_EVIDENCE_NOT_BUY_SELL" in SQL
    assert "CURRENT_REGISTRY_CLASSIFICATION_NOT_HISTORICAL" in SQL
    assert "no historical issuer-sector registry exists yet" in SQL


def test_phase4b_daily_job_runs_after_phase4a():
    assert "flow-market-memory-v4-daily" in SQL
    assert "'24 11 * * 1-5'" in SQL


def test_phase4b_quality_gate_requires_250_clean_sessions():
    assert "count(*)>=250" in SQL
    assert "min(stock_rows)>=800" in SQL
    assert "min(residual_rows)>=800" in SQL
    assert "PHASE4B_READY" in SQL
