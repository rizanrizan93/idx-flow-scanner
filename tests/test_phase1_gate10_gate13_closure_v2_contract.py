from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MIG = ROOT / "supabase" / "migrations"
REGISTRY = MIG / "20260909032550_phase1_closure_registry_v2.sql"
GATE11_FOUNDATION = MIG / "20260909032806_phase1_closure_gate11_v2.sql"
GATE11_FEATURE = MIG / "20260909033152_optimize_phase1_closure_gate11_v2_source_path.sql"
GATE11_STAGED = MIG / "20260909050130_phase1_closure_gate11_v2_staged_lineage.sql"
GATE12 = MIG / "20260909050229_phase1_closure_gate12_v2.sql"
GATE13 = MIG / "20260909050320_phase1_closure_gate13_v2.sql"
FILES = (REGISTRY, GATE11_FOUNDATION, GATE11_FEATURE, GATE11_STAGED, GATE12, GATE13)


def text(path: Path) -> str:
    assert path.exists(), path
    return path.read_text(encoding="utf-8")


def all_sql() -> str:
    return "\n".join(text(path) for path in FILES)


def test_v2_contracts_supersede_v1_without_rewriting_history():
    registry = text(REGISTRY)
    for token in (
        "IDX_DRIVER_REGISTRY_GATE10_V2",
        "IDX_DRIVER_WEEKLY_PIT_PANEL_V2",
        "IDX_DRIVER_PURGED_EXPANDING_WF_V2",
        "flow_driver_contract_supersession_v1",
        "IDX_DRIVER_REGISTRY_GATE10_V1",
    ):
        assert token in registry
    assert "69,12" in registry
    assert "production_influence_enabled=false" in registry.lower()


def test_gate10_v2_fixes_market_rank_scope_and_choch_dependency():
    registry = text(REGISTRY)
    rollup = text(GATE11_STAGED)
    assert "trailing_252_session_percentile_rank(ihsg_return_20d)" in registry
    assert "flow_market_learning_panel_v4.return_20d_pct" in registry
    assert "x.trade_date<=h.trade_date" in rollup
    assert "order by x.trade_date desc limit 252" in rollup
    assert "TRAILING_UP_TO_252_OBSERVATIONS_NO_FUTURE_DATES" in rollup
    # The corrected market-level component must not be ranked across tickers on one signal date.
    assert "partition by as_of_date order by ihsg_return20" not in rollup


def test_gate11_v2_is_staged_source_rebuild_with_computed_audit():
    foundation = text(GATE11_FOUNDATION)
    feature = text(GATE11_FEATURE)
    staged = text(GATE11_STAGED)
    for token in (
        "flow_refresh_driver_signal_stage_v2",
        "flow_refresh_driver_feature_stage_v2",
        "flow_restore_gate11_pit_rollups_v2",
        "flow_refresh_driver_lineage_v2",
        "flow_finalize_driver_panel_v2",
    ):
        assert token in foundation + feature + staged
    assert "ONE_STAGE_PER_TRANSACTION" in staged
    assert "DIRECT_PIT_RESIDUAL_PLUS_FINANCIAL_NO_HEAVY_VIEW" in feature
    assert "COMPUTED_NOT_LITERAL" in foundation
    assert "panel_digest_md5" in foundation
    assert "financial_prior_available_from_date>signal_date" in foundation
    assert "market_source_max_date>signal_date" in foundation
    assert "normalization_scope<>'SAME_SIGNAL_DATE_ONLY'" in foundation
    assert "forward_or_outcome_key_used_in_features" in foundation


def test_gate12_v2_streams_oos_and_computes_training_purge_parity():
    gate12 = text(GATE12)
    for token in (
        "IDX_DRIVER_PURGED_EXPANDING_WF_V2",
        "IDX_DRIVER_REGISTRY_GATE10_V2",
        "IDX_DRIVER_WEEKLY_PIT_PANEL_V2",
        "TRAIN", "VALIDATION", "HELDOUT", "FORWARD",
        "h.target_date<=f.train_end",
        "o.distinct_u<>1 or o.min_u<>e.expected_rows or o.max_u<>e.expected_rows",
        "STREAMED_CTE_NO_TEMP_TABLE",
        "concat('F',fold_no,':',market_regime)",
        "concat('F',fold_no,':',least(5,floor(liquidity_rank*5)::int+1))",
    ):
        assert token in gate12
    assert "classification='PROMISING' and driver_id<>'FIN_BALANCE'" in gate12
    assert "DISCOVERY_REPLAY_NOT_INDEPENDENT_CONFIRMATION" in gate12
    assert "sl.regime_pct is null or sl.liq_pct is null" in gate12
    assert "coalesce(sl.regime_pct,100)" not in gate12.lower()
    assert "coalesce(sl.liq_pct,100)" not in gate12.lower()


def test_gate13_v2_computes_posthoc_target_leakage_and_hard_blocks_fin_balance_replay():
    gate13 = text(GATE13)
    for token in (
        "IDX_DRIVER_BOUNDED_CONFLUENCE_WF_V2",
        "IDX_DRIVER_PURGED_EXPANDING_WF_V2",
        "IDX_DRIVER_REGISTRY_GATE10_V2",
        "normalized_value>=0.80",
        "a.mean_alpha-sc.top_mean_alpha_vs_ihsg_pct",
        "count(*) into v_posthoc",
        "o.universe_count<>e.expected_rows",
        "v_target_leaks=0",
        "v_posthoc=0",
        "concat('F',fold_no,':',market_regime)",
    ):
        assert token in gate13
    assert "classification='VALIDATED_CONFLUENCE' and not ('FIN_BALANCE'=any(component_driver_ids))" in gate13
    assert "FIN_BALANCE_DISCOVERY_OVERLAP_REQUIRES_UNTOUCHED_FORWARD_CONFIRMATION" in gate13
    assert "independent untouched forward confirmation required" in gate13
    assert "coalesce(c.regime_pct,100)" not in gate13.lower()
    assert "coalesce(c.liq_pct,100)" not in gate13.lower()


def test_v2_research_functions_are_secured_and_production_isolated():
    sql = all_sql().lower()
    assert "security invoker" in sql
    assert "set search_path=''" in sql
    assert "revoke all on function public.flow_run_single_driver_oos_v2(text) from public,anon,authenticated" in sql
    assert "revoke all on function public.flow_run_interaction_oos_v2(text) from public,anon,authenticated" in sql
    for token in (
        "update public.flow_scan_results",
        "insert into public.flow_scan_results",
        "delete from public.flow_scan_results",
        "update public.flow_phase4e",
        "insert into public.flow_phase4e",
    ):
        assert token not in sql
