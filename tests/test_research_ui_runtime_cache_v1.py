from __future__ import annotations

from pathlib import Path

from idx_flow_scanner import research_shadow


ROOT = Path(__file__).resolve().parents[1]
MIGRATION = ROOT / "supabase" / "migrations" / "20260912021940_research_ui_runtime_cache_v1.sql"
LOADER = ROOT / "src" / "idx_flow_scanner" / "research_shadow.py"


def test_runtime_cache_is_bounded_and_production_isolated() -> None:
    sql = MIGRATION.read_text(encoding="utf-8")
    assert "flow_research_horizon_ui_cache_v1" in sql
    assert "flow_financial_shadow_current_v6" in sql
    assert "r.research_rank<=250 or r.signal_state='ACTIVE'" in sql
    assert "x.financial_shadow_rank<=250" in sql
    assert "production_influence_enabled=false" in sql


def test_daily_research_runner_refreshes_ui_cache_after_capture() -> None:
    sql = MIGRATION.read_text(encoding="utf-8")
    capture_pos = sql.rfind("v_capture := public.flow_capture_research_horizon_signals_v1(v_today)")
    cache_pos = sql.rfind("v_cache := public.flow_refresh_research_ui_cache_v1(v_today)")
    assert capture_pos >= 0
    assert cache_pos > capture_pos


def test_dashboard_loader_uses_cache_instead_of_heavy_ranking_rpc() -> None:
    source = LOADER.read_text(encoding="utf-8")
    start = source.index("def load_research_horizon_rankings")
    end = source.index("def load_research_horizon_snapshots", start)
    function_source = source[start:end]
    assert "RESEARCH_HORIZON_UI_CACHE_TABLE" in function_source
    assert ".table(RESEARCH_HORIZON_UI_CACHE_TABLE)" in function_source
    assert ".rpc(" not in function_source
    assert research_shadow.RESEARCH_HORIZON_UI_CACHE_TABLE == "flow_research_horizon_ui_cache_v1"


def test_financial_shadow_prefers_latest_pit_cache_with_legacy_fallback() -> None:
    source = LOADER.read_text(encoding="utf-8")
    start = source.index("def load_latest_financial_shadow_scores")
    end = source.index("def load_shadow_strategy_lifecycle", start)
    function_source = source[start:end]
    assert "FINANCIAL_SHADOW_CURRENT_TABLE" in function_source
    assert "LATEST_PIT_CACHE" in function_source
    assert "LEGACY_COMPARISON" in function_source
    assert research_shadow.FINANCIAL_SHADOW_CURRENT_TABLE == "flow_financial_shadow_current_v6"
