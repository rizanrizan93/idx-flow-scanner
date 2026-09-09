from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MIG = ROOT / "supabase" / "migrations" / "20260909092000_gate15_shadow_predictive_v1.sql"


def sql() -> str:
    assert MIG.exists()
    return MIG.read_text(encoding="utf-8")


def test_promotion_policy_is_frozen_before_any_matured_outcome():
    text = sql()
    for token in (
        "GATE15_PROMOTION_POLICY_V1",
        "matured_outcomes_at_freeze integer not null check(matured_outcomes_at_freeze=0)",
        "frozen_before_first_matured_outcome boolean not null check(frozen_before_first_matured_outcome)",
        "must contain FIN_BALANCE plus exactly 12 frozen interactions",
        "interaction cohort must remain exactly 12",
    ):
        assert token in text


def test_preregistered_policy_contains_every_required_gate():
    text = sql()
    for token in (
        "minimum_sample_size_per_horizon",
        "minimum_independent_signal_dates",
        "minimum_forward_coverage_pct",
        "minimum_mean_alpha_pct",
        "minimum_median_alpha_pct",
        "minimum_direction_agreement_pct",
        "minimum_positive_horizons",
        "required_heldout_forward_behavior",
        "minimum_rank_ic",
        "minimum_regime_consistency_pct",
        "minimum_liquidity_consistency_pct",
        "minimum_incremental_lift_pct",
        "maximum_mean_adverse_excursion_abs_pct",
        "maximum_initial_production_weight",
        "rollback_rule",
    ):
        assert token in text
    assert "minimum_independent_signal_dates,minimum_forward_coverage_pct" in text
    assert "'FIN_BALANCE','DRIVER',500,20,90" in text
    assert "maximum_initial_production_weight between 0 and 0.05" in text
    assert "corr(a.signal_strength::double precision,o.alpha_vs_ihsg_pct::double precision) rank_ic" in text
    assert "'rank_ic_pass',coalesce(s.rank_ic_gate,false)" in text


def test_shadow_model_is_versioned_reliability_adjusted_and_fail_closed():
    text = sql()
    for token in (
        "SHADOW_PREDICTIVE_SCORE_V1",
        "UNCONFIRMED_SHADOW_ONLY",
        "reliability_adjusted_score",
        "evidence_coverage_pct",
        "tradeability_multiplier",
        "reliability_score is null then null",
        "not r.current_tradeable or r.technical_percentile is null then 'INVALID'",
        "exactly 12 frozen interactions are displayed and evaluated but receive zero model weight",
        "missing_robustness_fails_closed",
    ):
        assert token in text
    lower = text.lower()
    assert "coalesce(missing_robustness, 100)" not in lower
    assert "production_influence_enabled=true" not in lower


def test_shadow_evaluation_tracks_preregistered_rank_and_outcome_metrics():
    text = sql()
    for token in (
        "top10_overlap_pct",
        "top20_overlap_pct",
        "rank_displacement",
        "mean_alpha_pct",
        "hit_rate_pct",
        "max_favorable_excursion_pct",
        "max_adverse_excursion_pct",
        "active_liquidity_top20_pct",
        "maximum_sector_concentration_top20_pct",
        "top20_turnover_pct",
        "false_positive_rate_pct",
        "false_negative_candidate_count",
        "ideal_timing_hit_rate_pct",
        "thesis_failure_rate_pct",
    ):
        assert token in text
    assert "then null else" in text


def test_outcomes_use_official_composite_calendar_and_not_ticker_bar_offsets():
    text = sql()
    assert text.count("i.index_code='COMPOSITE'") >= 3
    assert text.count("order by i.trade_date offset(") >= 2
    assert "s.trade_date>o.signal_date" in text
    assert "s.trade_date<=o.target_date" in text


def test_gate15_security_scheduler_and_production_isolation():
    text = sql().lower()
    assert text.count("enable row level security") >= 7
    assert text.count("security invoker") >= 7
    assert text.count("set search_path=''") >= 7
    assert "from public,anon,authenticated" in text
    assert "to service_role" in text
    assert "flow-attribution-forward-outcomes-v1','50 11 * * 1-5'" in text
    assert "flow_run_gate15_outcome_cycle_v1()" in text
    for forbidden in (
        "update public.flow_scan_results",
        "insert into public.flow_scan_results",
        "delete from public.flow_scan_results",
        "update public.flow_driver_interaction_registry_v1",
        "insert into public.flow_driver_interaction_registry_v1",
    ):
        assert forbidden not in text
