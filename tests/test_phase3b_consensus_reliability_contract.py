from pathlib import Path


MIGRATION = Path(
    "supabase/migrations/20260907050000_phase3b_consensus_reliability_closure.sql"
)


def _sql() -> str:
    return MIGRATION.read_text(encoding="utf-8")


def test_phase3b_reliability_preserves_base_score_and_full_confidence_at_five():
    sql = _sql()
    assert "base_broker_consensus_proxy_score" in sql
    assert "consensus_reliability_factor" in sql
    assert "affinity_active_broker_count/5::numeric" in sql
    assert "least(1::numeric" in sql
    assert "LINEAR_MATCH_COUNT__20PCT_PER_BROKER__FULL_AT_5" in sql


def test_phase3b_adjusted_score_never_exceeds_base_score():
    sql = _sql()
    assert "broker_consensus_proxy_score <= base_broker_consensus_proxy_score + 0.000001" in sql
    assert "broker_consensus_proxy_score=coalesce(" in sql
    assert "* least(1::numeric,affinity_active_broker_count/5::numeric)" in sql


def test_phase3b_wrapper_always_finalizes_successful_base_refresh():
    sql = _sql()
    assert "rename to flow_refresh_ticker_affinity_consensus_v3_base" in sql
    assert "flow_refresh_ticker_affinity_consensus_v3_base(p_as_of_date)" in sql
    assert "flow_finalize_ticker_affinity_consensus_reliability_v3(p_as_of_date)" in sql
    assert "if coalesce(base_result->>'status','') <> 'OK'" in sql


def test_phase3b_quality_gate_requires_reliability_integrity():
    sql = _sql()
    assert "missing_reliability_rows=0" in sql
    assert "reliability_violation_rows=0" in sql
    assert "full_breadth_reliability_violation_rows=0" in sql
    assert "PHASE3B_READY" in sql


def test_phase3b_closure_remains_shadow_only():
    sql = _sql()
    assert "no_production_scoring_change" in sql
    assert "final_score" not in sql
    assert "production_authorized" not in sql
    assert "execution_ready" not in sql
