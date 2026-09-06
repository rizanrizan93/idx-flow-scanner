from __future__ import annotations

import numpy as np
import pandas as pd

from idx_flow_scanner.authorization import derive_production_authorized
from idx_flow_scanner.broker_behavior_runtime import verified_daily_foreign_ready
from idx_flow_scanner.decision import select_zapi_decision_top


def _official_diagnostics(**overrides):
    diagnostics = {
        "foreign_provider_selected": "IDX_DIRECT",
        "foreign_provider_selection_state": "IDX_DIRECT",
        "foreign_provider_reconciliation_state": "SINGLE_PROVIDER",
        "foreign_window_state": "FULL",
        "foreign_data_freshness": "FRESH",
        "foreign_data_valid": np.bool_(True),
        "foreign_provider_conflict": np.bool_(False),
        "foreign_evidence_coverage_pct": 100.0,
        "foreign_window_coverage_ratio": 1.0,
        "price_staleness_days": 0,
        "execution_geometry_valid": np.bool_(True),
        "execution_levels_tradeable": np.bool_(True),
        "entry_within_next_session_price_band": np.bool_(True),
        "free_float_pct": 40.0,
        "slow_evidence_hard_block": np.bool_(False),
    }
    diagnostics.update(overrides)
    return diagnostics


def test_official_idx_numpy_boolean_evidence_is_runtime_ready():
    assert verified_daily_foreign_ready(_official_diagnostics()) is True


def test_official_idx_full_fresh_valid_flow_can_be_production_authorized():
    row = {
        "ticker": "BBCA",
        "evidence_tier": "OFFICIAL_IDX_FLOW",
        "real_money_state": "ELIGIBLE",
        "final_score": 90.0,
        "distribution_risk": 20.0,
        "price_data_quality_score": 95.0,
        "phase": "ACCUMULATION",
        "action": "BUY_ON_WEAKNESS",
        "diagnostics": _official_diagnostics(),
    }

    assert derive_production_authorized(row) is True


def test_official_idx_partial_flow_still_fails_closed():
    row = {
        "ticker": "BBCA",
        "evidence_tier": "OFFICIAL_IDX_FLOW",
        "real_money_state": "GUARDED",
        "final_score": 90.0,
        "distribution_risk": 20.0,
        "price_data_quality_score": 95.0,
        "phase": "ACCUMULATION",
        "action": "WATCHLIST",
        "diagnostics": _official_diagnostics(
            foreign_window_state="PARTIAL",
            foreign_evidence_coverage_pct=75.0,
        ),
    }

    assert derive_production_authorized(row) is False


def test_official_idx_tier_is_admitted_to_verified_flow_decision_lane():
    frame = pd.DataFrame(
        [
            {
                "ticker": "BBCA",
                "final_score": 82.0,
                "phase": "ACCUMULATION",
                "action": "BUY_ON_WEAKNESS",
                "evidence_tier": "OFFICIAL_IDX_FLOW",
                "distribution_risk": 20.0,
                "price_data_quality_score": 95.0,
                "accumulation_score": 80.0,
                "foreign_institutional_score": 75.0,
                "market_context_score": 70.0,
                "smc_execution_score": 70.0,
                "diagnostics": _official_diagnostics(),
            }
        ]
    )

    selected = select_zapi_decision_top(frame, top_n=20)
    assert selected["ticker"].tolist() == ["BBCA"]
