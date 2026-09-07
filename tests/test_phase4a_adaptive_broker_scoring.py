from types import SimpleNamespace

from idx_flow_scanner.adaptive_broker_scoring import (
    AdaptiveBrokerState,
    apply_adaptive_broker_overlay,
    compute_advanced_evidence_score,
    set_adaptive_broker_context,
)


def _base_result():
    return SimpleNamespace(
        final_score=61.6,
        as_of_date="2026-09-04",
        diagnostics={
            "base_score_pre_broker_behavior": 60.0,
            "broker_behavior_consensus_score": 70.0,
            "broker_behavior_score_adjustment": 1.6,
        },
    )


def test_advanced_evidence_is_positive_only_and_requires_strong_contract():
    weak = compute_advanced_evidence_score(
        {
            "affinity_active_broker_count": 1,
            "weighted_affinity_score": 90,
            "consensus_reliability_factor": 0.2,
            "broker_consensus_proxy_score": 20,
            "breadth_state": "WEAK",
            "source_verified": True,
        },
        {},
    )
    assert weak["advanced_broker_score"] == 50.0
    assert weak["advanced_broker_evidence_eligible"] is False

    strong = compute_advanced_evidence_score(
        {
            "affinity_active_broker_count": 5,
            "weighted_affinity_score": 80,
            "consensus_reliability_factor": 1.0,
            "broker_consensus_proxy_score": 70,
            "breadth_state": "BROAD",
            "source_verified": True,
        },
        {"effective_profile_score": 80, "source_verified": True},
    )
    assert strong["advanced_broker_evidence_layer_count"] == 3
    assert strong["advanced_broker_score"] > 50
    assert strong["advanced_broker_score"] <= 100


def test_family_budget_stays_at_eight_percent_when_advanced_is_used():
    set_adaptive_broker_context(
        {
            "ready": True,
            "reason": "TEST_READY",
            "as_of_date": "2026-09-04",
            "state": AdaptiveBrokerState(
                family_budget=0.08,
                advanced_weight=0.02,
                max_advanced_weight=0.06,
                calibration_status="BOOTSTRAP",
            ),
            "tickers": {
                "ABCD": {
                    "advanced_broker_score": 80.0,
                    "advanced_broker_evidence_eligible": True,
                    "advanced_broker_evidence_layer_count": 3,
                    "phase3a_score": 80.0,
                    "phase3a_eligible": True,
                    "phase3b_score": 70.0,
                    "phase3b_eligible": True,
                    "phase3c_score": 80.0,
                    "phase3c_eligible": True,
                }
            },
        }
    )

    result = apply_adaptive_broker_overlay(
        lambda *_args, **_kwargs: _base_result(),
        "ABCD",
        None,
    )
    assert result.diagnostics["broker_family_budget"] == 0.08
    assert result.diagnostics["broker_v1_weight_effective"] == 0.06
    assert result.diagnostics["advanced_broker_weight_effective"] == 0.02
    assert (
        result.diagnostics["broker_v1_weight_effective"]
        + result.diagnostics["advanced_broker_weight_effective"]
        == 0.08
    )
    assert result.final_score == 61.8
    assert result.diagnostics["adaptive_broker_can_override_hard_gates"] is False


def test_no_advanced_evidence_keeps_existing_v1_eight_percent_behavior():
    set_adaptive_broker_context(
        {
            "ready": True,
            "reason": "TEST_READY",
            "as_of_date": "2026-09-04",
            "state": AdaptiveBrokerState(
                family_budget=0.08,
                advanced_weight=0.02,
                max_advanced_weight=0.06,
                calibration_status="BOOTSTRAP",
            ),
            "tickers": {},
        }
    )
    result = apply_adaptive_broker_overlay(
        lambda *_args, **_kwargs: _base_result(),
        "NONE",
        None,
    )
    assert result.diagnostics["advanced_broker_weight_effective"] == 0.0
    assert result.diagnostics["broker_v1_weight_effective"] == 0.08
    assert result.final_score == 61.6
