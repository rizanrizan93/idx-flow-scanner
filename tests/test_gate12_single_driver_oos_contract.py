from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MIG = ROOT / "supabase" / "migrations" / "20260908234608_gate12_single_driver_oos_v1.sql"


def sql() -> str:
    assert MIG.exists()
    return MIG.read_text(encoding="utf-8")


def test_gate12_uses_frozen_registry_panel_and_purged_walkforward():
    text = sql()
    for token in (
        "IDX_DRIVER_PURGED_EXPANDING_WF_V1",
        "IDX_DRIVER_REGISTRY_GATE10_V1",
        "IDX_DRIVER_WEEKLY_PIT_PANEL_V1",
        "TRAIN", "VALIDATION", "HELDOUT", "FORWARD",
        "PURGE_TRAIN_ROWS_UNLESS_TARGET_DATE_LE_TRAIN_END",
        "target_date<=f.train_end",
    ):
        assert token in text


def test_gate12_has_required_metrics_horizons_and_robustness_slices():
    text = sql()
    for horizon in (5, 20, 60):
        assert f"target_date_{horizon}d" in text
        assert f"forward_return_{horizon}d_pct" in text
        assert f"alpha_vs_ihsg_{horizon}d_pct" in text
    for token in (
        "median_return_pct", "hit_rate_pct", "top_bottom_return_spread_pct",
        "top_bottom_alpha_spread_pct", "rank_ic", "mean_mfe_pct", "mean_mae_pct",
        "MARKET_REGIME", "LIQUIDITY_QUINTILE", "missing_mean_alpha_pct",
    ):
        assert token in text


def test_gate12_fin_balance_is_discovery_aware_not_promoted():
    text = sql()
    assert "DISCOVERY_REPLAY_NOT_INDEPENDENT_CONFIRMATION" in text
    assert "Gate 9 overlap prevents independent confirmation" in text
    assert "classification='PROMISING' and driver_id<>'FIN_BALANCE'" in text


def test_gate12_is_research_only_secured_and_fail_closed():
    text = sql().lower()
    assert "security invoker" in text
    assert "set search_path=''" in text
    assert text.count("enable row level security") >= 6
    assert "production_influence_enabled boolean not null default false" in text
    assert "training_target_overlap_leaks integer not null check(training_target_overlap_leaks=0)" in text
    assert "panel_leakage_count integer not null check(panel_leakage_count=0)" in text
    for token in (
        "update public.flow_scan_results",
        "insert into public.flow_scan_results",
        "delete from public.flow_scan_results",
        "update public.flow_phase4e",
        "insert into public.flow_phase4e",
    ):
        assert token not in text
