from __future__ import annotations

from pathlib import Path

from idx_flow_scanner import research_shadow


ROOT = Path(__file__).resolve().parents[1]
MIGRATION = ROOT / "supabase" / "migrations" / "20260911174744_research_horizon_strategies_v1.sql"
MATURITY_MIGRATION = ROOT / "supabase" / "migrations" / "20260911175949_research_horizon_outcome_maturity_v1_1.sql"
PAGE = ROOT / "pages" / "5_Research_Shadow.py"


def test_research_horizon_contracts_are_frozen_and_production_isolated() -> None:
    sql = MIGRATION.read_text(encoding="utf-8")
    assert "RESEARCH_HORIZON_STRATEGIES_V1_1" in sql
    assert "BRFE_5" in sql
    assert "BPL_20" in sql
    assert "QBA_60" in sql
    assert "foreign_net_volume_pct>=15" in sql
    assert "b.top10_share<=59.5" in sql
    assert "b.fin_balance_score>=80" in sql
    assert "b.stock_residual_activity_z<=-0.5" in sql
    assert "b.market_activity>-0.26" in sql
    assert "production_influence_enabled=false" in sql
    assert "flow_research_horizon_rankings_v1" in sql
    assert "flow_capture_research_horizon_signals_v1" in sql
    assert "flow_refresh_research_horizon_outcomes_v1" in sql


def test_research_scheduler_has_primary_and_retry_capture() -> None:
    sql = MIGRATION.read_text(encoding="utf-8")
    assert "flow-research-horizon-capture-v1" in sql
    assert "55 11 * * 1-5" in sql
    assert "flow-research-horizon-retry-v1" in sql
    assert "25 12 * * 1-5" in sql
    assert "flow_run_research_horizon_daily_v1" in sql


def test_immature_outcomes_are_not_misclassified_as_exclusions() -> None:
    sql = MATURITY_MIGRATION.read_text(encoding="utf-8")
    assert "target_seen<component_count then 'SOURCE_NOT_READY'" in sql
    assert "target_seen<component_count then 0" in sql
    assert "target_seen<component_count then null" in sql
    assert "production_influence_enabled=false" in sql


def test_research_page_has_dedicated_5d_20d_60d_subtabs() -> None:
    page = PAGE.read_text(encoding="utf-8")
    assert "5D · BRFE-5" in page
    assert "20D · BPL-20" in page
    assert "60D · QBA-60" in page
    assert "Prospective OOS history" in page
    assert "Research Rank" in page
    assert "production influence=OFF" in page


def test_research_bundle_exposes_horizon_rankings_and_oos_state() -> None:
    fields = research_shadow.ShadowResearchBundle.__dataclass_fields__
    assert "horizon_rankings" in fields
    assert "horizon_snapshots" in fields
    assert "horizon_outcomes" in fields
    assert "horizon_policies" in fields
    assert research_shadow.RESEARCH_HORIZON_RANKING_RPC == "flow_research_horizon_rankings_v1"
