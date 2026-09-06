from types import SimpleNamespace

import pandas as pd

from idx_flow_scanner.config import ZapiFlowConfig
from idx_flow_scanner.official_idx_risk import (
    apply_official_risk_overlay,
    compute_official_risk_features,
    set_official_risk_context,
)


def _price():
    dates = pd.bdate_range("2026-08-17", periods=15)
    return pd.DataFrame({"date": dates, "open": 100, "high": 102, "low": 98, "close": 100, "volume": 1_000_000})


def _event(ticker, day, event_type):
    return {
        "ticker": ticker,
        "event_date": pd.Timestamp(day),
        "event_type": event_type,
        "source": "IDX_OFFICIAL_RISK_EVENT",
        "source_verified": True,
        "provenance_state": "VERIFIED_OFFICIAL_IDX_MARKET_RISK_EVENT",
    }


def _dummy_scan(*args, **kwargs):
    return SimpleNamespace(
        final_score=80.0,
        production_authorized=True,
        real_money_state="ELIGIBLE",
        action="BUY_RETEST",
        guardrail_reason="base gates passed",
        diagnostics={},
    )


def test_unresolved_suspension_is_hard_block():
    price = _price()
    events = pd.DataFrame([_event("ABCD", "2026-08-26", "SUSPEND")])
    features = compute_official_risk_features("ABCD", price, events)
    assert features["official_risk_active_suspension"] is True
    assert features["official_risk_hard_block"] is True
    assert features["official_risk_penalty_points"] == 25.0


def test_later_unsuspend_clears_hard_block():
    price = _price()
    events = pd.DataFrame(
        [
            _event("ABCD", "2026-08-25", "SUSPEND"),
            _event("ABCD", "2026-08-27", "UNSUSPEND"),
        ]
    )
    features = compute_official_risk_features("ABCD", price, events)
    assert features["official_risk_active_suspension"] is False
    assert features["official_risk_latest_suspension_event"] == "UNSUSPEND"


def test_recent_uma_is_short_guard_not_suspension():
    price = _price()
    as_of = pd.to_datetime(price["date"]).max()
    prior = pd.bdate_range(end=as_of, periods=2)[0]
    events = pd.DataFrame([_event("ABCD", prior, "UMA")])
    features = compute_official_risk_features("ABCD", price, events)
    assert features["official_risk_hard_block"] is False
    assert features["official_risk_uma_guard"] is True
    assert features["official_risk_penalty_points"] == 6.0


def test_overlay_can_only_derate_and_revoke_authorization():
    price = _price()
    events = pd.DataFrame([_event("ABCD", "2026-08-26", "SUSPEND")])
    set_official_risk_context(events)
    result = apply_official_risk_overlay(
        _dummy_scan,
        "ABCD",
        price,
        config=ZapiFlowConfig(),
    )
    assert result.final_score == 55.0
    assert result.production_authorized is False
    assert result.real_money_state == "GUARDED"
    assert result.action == "REDUCE_AVOID"
    assert "unresolved suspension" in result.guardrail_reason


def test_missing_feed_is_fail_neutral():
    price = _price()
    set_official_risk_context(None)
    result = apply_official_risk_overlay(
        _dummy_scan,
        "ABCD",
        price,
        config=ZapiFlowConfig(),
    )
    assert result.final_score == 80.0
    assert result.production_authorized is True
    assert result.diagnostics["official_risk_feed_available"] is False
