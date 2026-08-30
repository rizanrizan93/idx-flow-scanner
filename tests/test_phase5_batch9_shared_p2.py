import numpy as np
import pandas as pd
import pytest

from idx_flow_scanner.authorization import apply_production_authorization
from idx_flow_scanner.broker_freshness import evaluate_broker_freshness
from idx_flow_scanner.idx_trading_calendar import (
    CalendarCoverageError, CalendarState, calendar_state, is_idx_session, latest_expected_completed_session,
    n_idx_sessions_ago, previous_idx_session, trading_session_age,
)
from idx_flow_scanner.provider_semantics import (
    EvidenceProvenance, ProviderResult, ProviderStatus, aggregate_provenance,
    normalize_provider_result, normalize_provenance,
)


def test_typed_provider_result_matrix_is_fail_closed_and_zero_safe():
    cases = [
        ({"status": "SUCCESS", "value": 7}, ProviderStatus.SUCCESS),
        (0, ProviderStatus.SUCCESS),
        ({"status": "PARTIAL", "value": [1]}, ProviderStatus.PARTIAL),
        ({"status": "MISSING"}, ProviderStatus.MISSING),
        ({"status": "STALE", "value": 3}, ProviderStatus.STALE),
        ({"status": "INVALID", "value": "bad"}, ProviderStatus.INVALID),
        ({"status": "ERROR", "value": 0, "error": "provider timeout"}, ProviderStatus.PROVIDER_ERROR),
        ({"status": "mystery", "value": 1}, ProviderStatus.INVALID),
        ({"status": "NOT_APPLICABLE"}, ProviderStatus.NOT_APPLICABLE),
        ("unrecognized legacy payload", ProviderStatus.INVALID),
        (None, ProviderStatus.MISSING), (float("nan"), ProviderStatus.MISSING),
        (pd.NA, ProviderStatus.MISSING), (True, ProviderStatus.INVALID),
        ({"status": "SUCCESS", "value": 1, "freshness": "STALE"}, ProviderStatus.STALE),
    ]
    results = [normalize_provider_result(value, provider="FIXTURE") for value, _ in cases]
    assert [result.status for result in results] == [expected for _, expected in cases]
    assert results[1].value == 0 and results[6].value == 0
    assert results[6].status is ProviderStatus.PROVIDER_ERROR
    assert results[6].error_category.value == "TIMEOUT"
    assert all(results[index].value is None for index in (3, 10, 11, 12))

    for malformed in (
        {"status": "SUCCESS"},
        {"status": "SUCCESS", "value": None},
        {"status": "SUCCESS", "value": np.nan},
        {"status": "SUCCESS", "value": pd.NA},
    ):
        assert normalize_provider_result(malformed, provider="FIXTURE").status is ProviderStatus.INVALID
    zero = normalize_provider_result({"status": "SUCCESS", "value": 0}, provider="FIXTURE")
    assert zero.status is ProviderStatus.SUCCESS and zero.value == 0
    boolean = normalize_provider_result({"status": "SUCCESS", "value": False}, provider="FIXTURE")
    assert boolean.status is ProviderStatus.SUCCESS and boolean.value is False
    canonical = normalize_provider_result({"status": "SUCCESS", "value": 3}, provider="FIXTURE")
    assert normalize_provider_result(canonical) is canonical
    assert normalize_provider_result(canonical, provider="FIXTURE") is canonical
    conflict = normalize_provider_result(canonical, provider="OTHER")
    assert conflict.status is ProviderStatus.INVALID and conflict.provider == "FIXTURE"
    provider_error = normalize_provider_result(
        {"status": "ERROR", "value": 0, "error": "timeout"}, provider="FIXTURE"
    )
    assert normalize_provider_result(provider_error) is provider_error
    for provider_status in ProviderStatus:
        canonical_status = ProviderResult(status=provider_status, provider="FIXTURE", value=0)
        assert normalize_provider_result(canonical_status) is canonical_status


def test_calendar_and_provenance_contracts_match_shared_vocabulary():
    assert is_idx_session("2026-08-07") and not is_idx_session("2026-08-08")
    assert calendar_state("2026-08-17") is CalendarState.CLOSED
    assert calendar_state("2025-08-18") is CalendarState.CLOSED
    assert n_idx_sessions_ago("2026-08-10", 1).date().isoformat() == "2026-08-07"
    assert trading_session_age("2026-08-07", "2026-08-10") == 1
    assert trading_session_age("2026-03-17", "2026-03-25") == 1
    assert trading_session_age("2026-08-08", "2026-08-10") is None
    assert calendar_state("2027-01-04") is CalendarState.UNKNOWN
    assert calendar_state("2027-01-02") is CalendarState.UNKNOWN
    assert calendar_state("2099-01-01") is CalendarState.UNKNOWN
    assert trading_session_age("2025-12-30", "2026-01-02") == 1
    assert trading_session_age("2026-12-30", "2027-01-01") is None
    with pytest.raises(CalendarCoverageError):
        latest_expected_completed_session("2027-01-01")
    with pytest.raises(CalendarCoverageError):
        previous_idx_session("2027-01-02")
    with pytest.raises(CalendarCoverageError):
        n_idx_sessions_ago("2027-01-01", 1)
    assert latest_expected_completed_session("2026-08-10T08:30:00Z").date().isoformat() == "2026-08-07"
    assert latest_expected_completed_session("2026-08-10T09:30:00Z").date().isoformat() == "2026-08-10"
    expected = {
        "IDX_OFFICIAL_XBRL": EvidenceProvenance.DIRECT_OR_OFFICIAL,
        "VERIFIED_VENDOR_API": EvidenceProvenance.VERIFIED,
        "GOOGLE_NEWS_PUBLIC_RESEARCH": EvidenceProvenance.PUBLIC_RESEARCH,
        "MODEL_INFERRED": EvidenceProvenance.INFERRED,
        "OHLCV_PROXY": EvidenceProvenance.PROXY,
        "YFINANCE_PROXY_NOT_OFFICIAL_FILING": EvidenceProvenance.PROXY,
        "unknown": EvidenceProvenance.MISSING,
    }
    assert {key: normalize_provenance(key) for key in expected} == expected
    assert aggregate_provenance("DIRECT_OR_OFFICIAL", "PROXY") is EvidenceProvenance.PROXY
    assert aggregate_provenance("VERIFIED", None) is EvidenceProvenance.MISSING


def test_idx_flow_broker_freshness_is_session_based_and_row_local():
    price = pd.DataFrame({"date": [pd.Timestamp("2026-08-10")]})
    broker = pd.DataFrame({
        "ticker": ["AAA"], "trade_date": ["2026-08-07"], "broker_code": ["AA"],
        "buy_value": [0.0], "sell_value": [0.0], "source": ["INDEX_ALPHA_BROKER_SUMMARY"],
        "provenance_state": ["VERIFIED_VENDOR_API_EXACT_DAY_ALL_RG_VOLUME_UNIT_PROVIDER_NATIVE"],
    })
    result = evaluate_broker_freshness(broker, price, "AAA", max_age_days=1)
    assert result["broker_latest_age_sessions"] == 1
    assert result["broker_freshness_state"] == "FRESH"
    assert result["broker_provider_result_status"] == "SUCCESS"
    missing = evaluate_broker_freshness(pd.DataFrame(), price, "BBB", max_age_days=1)
    assert missing["broker_provider_result_status"] == "MISSING"

    future_broker = broker.copy()
    future_broker["trade_date"] = "2026-08-10"
    earlier_price = pd.DataFrame({"date": [pd.Timestamp("2026-08-07")]})
    future = evaluate_broker_freshness(future_broker, earlier_price, "AAA", max_age_days=1)
    assert future["broker_latest_age_sessions"] == -1
    assert future["broker_freshness_state"] == "UNKNOWN"
    assert future["broker_provider_result_status"] == "INVALID"
    assert future["broker_data_valid"] is False

    attacked = pd.DataFrame([{
        "ticker": "AAA",
        "broker_verification_status": "BROKER_VERIFIED",
        "evidence_tier": "BROKER_DIRECT",
        "real_money_state": "ELIGIBLE",
        "production_authorized": True,
        "diagnostics": {
            **future,
            "foreign_provider_selected": "IDX_DIRECT",
            "foreign_provider_selection_state": "IDX_DIRECT",
            "foreign_provider_reconciliation_state": "AGREED",
            "foreign_window_state": "FULL",
            "foreign_provider_conflict": False,
            "foreign_data_valid": True,
            "foreign_data_freshness": "FRESH",
        },
    }])
    assert bool(apply_production_authorization(attacked).iloc[0]["production_authorized"]) is False
