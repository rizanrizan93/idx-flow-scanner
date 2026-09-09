from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MIG = ROOT / "supabase" / "migrations" / "20260909091000_gate14_structured_attribution_thesis_v1.sql"


def sql() -> str:
    assert MIG.exists()
    return MIG.read_text(encoding="utf-8")


def test_structured_attribution_has_every_canonical_section():
    text = sql()
    for token in (
        "primary_drivers",
        "supporting_drivers",
        "contradicting_drivers",
        "context_only_evidence",
        "missing_stale_unavailable_evidence",
        "attribution_confidence",
        "predictive_readiness",
        "data_coverage_pct",
        "evidence_freshness",
        "evidence_lineage",
        "frozen_historical_performance_metadata",
        "prospective_confirmation_status",
    ):
        assert token in text


def test_structured_source_of_truth_is_deterministic_not_black_box():
    text = sql()
    for token in (
        "IDX_STRUCTURED_ATTRIBUTION_SHADOW_V2",
        "IDX_PREDICTIVE_ATTRIBUTION_SHADOW_V1",
        "TOP_900_UNIVERSE_V1",
        "normalized_value>=0.80",
        "normalized_value>=0.65",
        "normalized_value<=0.20",
        "Canonical structured evidence is the source of truth",
        "never causal wording",
    ):
        assert token in text
    lower = text.lower()
    for forbidden in ("openai", "llm", "generate narrative", "this caused"):
        assert forbidden not in lower


def test_missingness_and_data_gap_registry_are_fail_closed():
    text = sql()
    for state in (
        "'AVAILABLE'",
        "'MISSING'",
        "'STALE'",
        "'INVALID'",
        "'NOT_APPLICABLE'",
        "'INSUFFICIENT_HISTORY'",
    ):
        assert state in text
    for domain in (
        "SECTOR",
        "OWNERSHIP_SHAREHOLDER",
        "OFFICIAL_FREE_FLOAT",
        "CORPORATE_ACTION",
        "DISCLOSURE_MATERIAL_EVENT",
        "FINANCIAL",
        "FOREIGN_FLOW",
        "TECHNICAL_PRICE_VOLUME",
        "LIQUIDITY",
        "MARKET_CONTEXT",
    ):
        assert domain in text
    assert "missing_is_zero',false" in text
    assert text.count("count(distinct snapshot_date)>=20") >= 2
    assert "coalesce(missing_robustness, 100)" not in text.lower()


def test_events_separate_occurrence_interpretation_and_validity():
    text = sql()
    assert text.count("'event_occurred',true") >= 2
    assert text.count("'event_interpretation','UNASSESSED_CONTEXT_ONLY'") >= 2
    assert text.count("'event_predictive_validity','NOT_ESTABLISHED'") >= 2
    assert "flow_capital_action_evidence" in text
    assert "flow_disclosure_evidence_v5" in text


def test_free_float_semantics_are_not_fabricated():
    text = sql()
    assert "No verified regulatory free-float history is available" in text
    assert "NOT_OFFICIAL_FREE_FLOAT" in text
    assert "unreported_float_upper_bound_pct" in text
    assert "tradable shares and residual disclosed ownership are not substituted" in text.lower()


def test_thesis_lifecycle_stores_signal_now_and_driver_changes():
    text = sql()
    for token in (
        "thesis_at_signal",
        "thesis_now",
        "changed_drivers",
        "STRENGTHENING",
        "INTACT",
        "WEAKENING",
        "BROKEN",
        "EXPIRED",
        "INVALID_DATA",
        "signal_percentile",
        "current_percentile",
        "structural_invalidation",
        "current_close<structural_invalidation",
        "sessions_elapsed>60",
    ):
        assert token in text


def test_signal_cycle_preserves_gate14_fail_closed_order():
    text = sql()
    assert "flow_capture_attribution_prospective_signals_v1(p_signal_date)" in text
    assert "coalesce(v_signal->>'status','')<>'CAPTURED'" in text
    assert "flow_capture_structured_attribution_v2(p_signal_date)" in text
    assert "flow_refresh_thesis_lifecycle_v1(p_signal_date)" in text
    assert "flow-attribution-forward-signals-v1','40 11 * * 1-5'" in text


def test_gate14_v2_security_and_no_production_writes():
    text = sql().lower()
    assert text.count("enable row level security") >= 6
    assert text.count("security invoker") >= 5
    assert text.count("set search_path=''") >= 5
    assert "from public,anon,authenticated" in text
    assert "to service_role" in text
    for forbidden in (
        "update public.flow_scan_results",
        "insert into public.flow_scan_results",
        "delete from public.flow_scan_results",
        "production_influence_enabled=true",
    ):
        assert forbidden not in text
