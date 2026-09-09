from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MIGRATIONS = (
    ROOT / "supabase" / "migrations" / "20260909015153_gate13_confluence_validation_v1.sql",
    ROOT / "supabase" / "migrations" / "20260909015227_fix_gate13_interaction_join_v1.sql",
    ROOT / "supabase" / "migrations" / "20260909015541_optimize_gate13_component_scan_v2.sql",
    ROOT / "supabase" / "migrations" / "20260909015703_fix_gate13_finalizer_cte_v1.sql",
    ROOT / "supabase" / "migrations" / "20260909015923_fix_gate13_summary_raw_metrics_v1.sql",
)


def sql() -> str:
    for migration in MIGRATIONS:
        assert migration.exists()
    return "\n".join(m.read_text(encoding="utf-8") for m in MIGRATIONS)


def final_runner_sql() -> str:
    return MIGRATIONS[2].read_text(encoding="utf-8")


def finalizer_sql() -> str:
    return MIGRATIONS[-1].read_text(encoding="utf-8")


def test_gate13_uses_only_frozen_bounded_registry_and_parent_oos_contract():
    text = sql()
    for token in (
        "IDX_DRIVER_BOUNDED_CONFLUENCE_WF_V1",
        "IDX_DRIVER_REGISTRY_GATE10_V1",
        "IDX_DRIVER_PURGED_EXPANDING_WF_V1",
        "flow_driver_interaction_registry_v1",
        "max_interaction_budget integer not null check(max_interaction_budget=12)",
        "registered_interactions<=max_interaction_budget",
        "posthoc_mining_count integer not null check(posthoc_mining_count=0)",
    ):
        assert token in text


def test_gate13_confluence_formula_and_incremental_lift_are_deterministic():
    text = final_runner_sql()
    for token in (
        "raw_value*direction_hypothesis",
        "percent_rank() over(partition by signal_date,driver_id,driver_state order by transformed_value)",
        "bool_and(driver_state='AVAILABLE' and normalized_value>=0.80)",
        "strongest_component_top_alpha_pct",
        "incremental_alpha_lift_pct",
        "a.mean_alpha-sc.top_mean_alpha_vs_ihsg_pct",
    ):
        assert token in text


def test_gate13_reuses_purged_folds_and_has_required_horizons_slices_and_excursions():
    text = final_runner_sql()
    for horizon in (5, 20, 60):
        assert f"target_date_{horizon}d" in text
        assert f"alpha_vs_ihsg_{horizon}d_pct" in text
    for token in (
        "TRAIN", "VALIDATION", "HELDOUT", "FORWARD",
        "target_date<=f.train_end",
        "MARKET_REGIME", "LIQUIDITY_QUINTILE",
        "mean_mfe", "mean_mae", "hit_rate",
    ):
        assert token in text


def test_gate13_frozen_acceptance_does_not_promote_low_coverage_raw_returns():
    text = finalizer_sql()
    for token in (
        "valid_cells>=12",
        "direction_pct>=66.67",
        "heldout_lift>0",
        "forward_lift>0",
        "horizon_days=5 and mean_lift>=0.25",
        "horizon_days=20 and mean_lift>=0.50",
        "horizon_days=60 and mean_lift>=1.00",
        "coverage_pct>=c.minimum_coverage_pct",
        "Raw OOS metrics exist, but frozen minimum coverage/sample validity is not met",
        "INSUFFICIENT_EVIDENCE",
    ):
        assert token in text


def test_gate13_fin_balance_overlap_remains_confirmation_guarded():
    text = finalizer_sql()
    assert "FIN_BALANCE_DISCOVERY_OVERLAP_REQUIRES_FORWARD_CONFIRMATION" in text
    assert "eligible_to_enter_phase2" not in text or "classification='VALIDATED_CONFLUENCE'" in text


def test_gate13_is_secured_and_production_isolated():
    text = sql().lower()
    assert "security invoker" in text
    assert "set search_path=''" in text
    assert text.count("enable row level security") >= 5
    assert "production_influence_enabled boolean not null default false" in text
    assert "panel_leakage_count integer not null check(panel_leakage_count=0)" in text
    assert "target_leakage_count integer not null check(target_leakage_count=0)" in text
    for token in (
        "update public.flow_scan_results",
        "insert into public.flow_scan_results",
        "delete from public.flow_scan_results",
        "update public.flow_phase4e",
        "insert into public.flow_phase4e",
    ):
        assert token not in text
