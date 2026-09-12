from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def _text(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


def test_adaptive_router_schema_is_research_only_and_frozen() -> None:
    sql = _text("supabase/migrations/20260912085106_research_adaptive_router_v2_schema.sql")
    assert "ADAPTIVE_HORIZON_ROUTER_V2_1" in sql
    assert "AHR_V2_40_40_20" in sql
    assert '"BRFE_5":40.0' in sql
    assert '"BPL_20":40.0' in sql
    assert '"QBA_60":20.0' in sql
    assert "FROZEN_RESEARCH" in sql
    assert "production_influence_enabled boolean not null default false" in sql
    assert "POST_HOC_RESEARCH_CHALLENGER_REQUIRES_PROSPECTIVE_OOS" in sql


def test_adaptive_router_capture_keeps_inactive_sleeves_in_cash() -> None:
    sql = _text("supabase/migrations/20260912085123_research_adaptive_router_v2_capture.sql")
    assert "when h.signal_state='ACTIVE'" in sql
    assert "else 0::numeric end allocated_weight_pct" in sql
    assert "100-a.active_weight_pct" in sql
    assert "ALL_CASH" in sql
    assert "ACTIVE_PARTIAL" in sql


def test_adaptive_router_outcome_requires_all_active_sleeves_to_mature() -> None:
    sql = _text("supabase/migrations/20260912085144_research_adaptive_router_v2_outcomes.sql")
    assert "mature_sleeve_count<active_sleeve_count" in sql
    assert "SOURCE_NOT_READY" in sql
    assert "mature_sleeve_count=active_sleeve_count" in sql
    assert "portfolio_return_pct" in sql
    assert "production_influence_enabled=false" in sql


def test_adaptive_runner_is_separate_from_existing_horizon_runner() -> None:
    runner = _text("supabase/migrations/20260912085207_research_adaptive_router_v2_runner.sql")
    cron = _text("supabase/migrations/20260912085320_research_adaptive_router_v2_cron.sql")
    assert "flow_run_research_adaptive_daily_v2" in runner
    assert "flow_run_research_horizon_daily_v1" not in runner
    assert "flow-research-adaptive-router-v2" in cron
    assert "5 12 * * 1-5" in cron
    assert "35 12 * * 1-5" in cron


def test_research_ui_exposes_adaptive_subtab_and_loader() -> None:
    page = _text("pages/5_Research_Shadow.py")
    loader = _text("src/idx_flow_scanner/research_adaptive.py")
    ui = _text("src/idx_flow_scanner/research_adaptive_ui.py")
    compile(page, "pages/5_Research_Shadow.py", "exec")
    compile(loader, "src/idx_flow_scanner/research_adaptive.py", "exec")
    compile(ui, "src/idx_flow_scanner/research_adaptive_ui.py", "exec")
    assert "Adaptive · 40/40/20" in page
    assert "load_adaptive_research_bundle" in page
    assert "render_adaptive_router" in page
    assert "flow_research_adaptive_snapshot_v2" in loader
    assert "Prospective Adaptive OOS" in ui
