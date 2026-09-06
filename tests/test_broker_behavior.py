from __future__ import annotations

import pandas as pd

from idx_flow_scanner.broker_behavior import (
    BROKER_BEHAVIOR_BASIS,
    compute_broker_market_regime,
    compute_ticker_broker_consensus,
)
from idx_flow_scanner.broker_behavior_runtime import (
    apply_broker_behavior_overlay,
    set_broker_activity_context,
    verified_daily_foreign_ready,
)
from idx_flow_scanner.models import ScanResult


def _activity_frame() -> pd.DataFrame:
    rows = []
    dates = pd.bdate_range("2026-08-03", periods=21)
    brokers = ["AK", "BK", "CC", "XL", "YP", "ZP"]
    for day_no, day in enumerate(dates):
        for idx, broker in enumerate(brokers):
            base = 100_000_000.0 * (idx + 1)
            multiplier = 1.0 + 0.01 * day_no
            if day_no == len(dates) - 1:
                multiplier *= 2.0
            rows.append(
                {
                    "trade_date": day,
                    "broker_code": broker,
                    "broker_name": broker,
                    "traded_value": base * multiplier,
                    "volume": 1_000_000.0 * (idx + 1) * multiplier,
                    "frequency": 1_000.0 * (idx + 1) * multiplier,
                    "source": "IDX_OFFICIAL_BROKER_SUMMARY",
                    "source_verified": True,
                }
            )
    return pd.DataFrame(rows)


def _price_frame() -> pd.DataFrame:
    dates = pd.bdate_range("2026-07-01", periods=30)
    return pd.DataFrame(
        {
            "date": dates,
            "open": [100.0] * len(dates),
            "high": [103.0] * len(dates),
            "low": [99.0] * len(dates),
            "close": [101.0 + 0.1 * i for i in range(len(dates))],
            "volume": [1_000_000.0] * 25 + [2_000_000.0] * 5,
        }
    )


def test_market_regime_is_official_market_wide_not_per_ticker_broker_flow():
    regime = compute_broker_market_regime(_activity_frame())
    assert regime["broker_behavior_available"] is True
    assert regime["broker_activity_sessions"] == 21
    assert regime["broker_latest_count"] == 6
    assert regime["broker_behavior_basis"] == BROKER_BEHAVIOR_BASIS
    assert 0.0 <= float(regime["broker_market_regime_score"]) <= 100.0


def test_consensus_cross_confirms_ticker_flow_without_claiming_direct_broker_trades():
    regime = compute_broker_market_regime(_activity_frame())
    positive = compute_ticker_broker_consensus(
        "BBCA",
        _price_frame(),
        {"foreign_institutional_score": 80.0},
        {"proxy_accumulation_score": 78.0, "proxy_absorption_score": 75.0},
        regime,
    )
    negative = compute_ticker_broker_consensus(
        "BBCA",
        _price_frame(),
        {"foreign_institutional_score": 25.0},
        {"proxy_accumulation_score": 30.0, "proxy_absorption_score": 30.0},
        regime,
    )
    assert float(positive["broker_behavior_consensus_score"]) > 50.0
    assert float(negative["broker_behavior_consensus_score"]) < 50.0
    assert positive["broker_behavior_basis"] == BROKER_BEHAVIOR_BASIS


def test_missing_broker_activity_is_neutral():
    regime = compute_broker_market_regime(pd.DataFrame())
    score = compute_ticker_broker_consensus(
        "BBCA",
        _price_frame(),
        {"foreign_institutional_score": 95.0},
        {"proxy_accumulation_score": 95.0, "proxy_absorption_score": 95.0},
        regime,
    )
    assert score["broker_behavior_available"] is False
    assert float(score["broker_behavior_consensus_score"]) == 50.0


def test_verified_foreign_readiness_accepts_official_idx_and_zapi_fallback():
    base = {
        "foreign_data_valid": True,
        "foreign_provider_reconciliation_state": "SINGLE_PROVIDER",
        "foreign_window_state": "FULL",
        "foreign_data_freshness": "FRESH",
        "foreign_provider_conflict": False,
    }
    assert verified_daily_foreign_ready(
        {**base, "foreign_provider_selected": "IDX_DIRECT", "foreign_provider_selection_state": "IDX_DIRECT"}
    )
    assert verified_daily_foreign_ready(
        {**base, "foreign_provider_selected": "ZAPI", "foreign_provider_selection_state": "ZAPI"}
    )


def test_overlay_changes_ranking_score_but_does_not_override_hard_gate_state():
    set_broker_activity_context(_activity_frame())

    def original(ticker, price, **kwargs):
        return ScanResult(
            ticker=ticker,
            as_of_date="2026-09-04",
            final_score=70.0,
            phase="ACCUMULATION",
            action="RESEARCH_ONLY",
            evidence_tier="PRICE_PROXY",
            evidence_coverage_pct=100.0,
            accumulation_score=80.0,
            operator_dominance_score=75.0,
            cost_basis_score=50.0,
            retail_exhaustion_score=60.0,
            foreign_institutional_score=82.0,
            supply_concentration_score=65.0,
            price_flow_divergence_score=70.0,
            market_context_score=60.0,
            smc_execution_score=65.0,
            risk_liquidity_score=70.0,
            price_data_quality_score=95.0,
            distribution_risk=30.0,
            estimated_smart_money_cost=None,
            premium_to_cost_pct=None,
            entry_low=None,
            entry_high=None,
            invalidation=None,
            tp1=None,
            tp2=None,
            real_money_state="GUARDED",
            guardrail_reason="execution geometry invalid",
            production_authorized=False,
            diagnostics={"proxy_accumulation_score": 80.0, "proxy_absorption_score": 75.0},
        )

    result = apply_broker_behavior_overlay(original, "BBCA", _price_frame())
    assert result.final_score > 70.0
    assert result.production_authorized is False
    assert result.real_money_state == "GUARDED"
    assert result.diagnostics["broker_behavior_can_override_hard_gates"] is False
