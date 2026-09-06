import pandas as pd

from idx_flow_scanner.official_controller_ownership import (
    apply_official_controller_overlay,
    compute_official_controller_features,
)


def _price(as_of="2026-09-04"):
    return pd.DataFrame(
        {
            "date": pd.bdate_range(end=as_of, periods=30),
            "open": 100.0,
            "high": 102.0,
            "low": 98.0,
            "close": 100.0,
            "volume": 1_000_000,
        }
    )


def _profiles(observed_on="2026-09-06"):
    return pd.DataFrame(
        [
            {
                "ticker": "ABCD",
                "observed_on": observed_on,
                "holder_name": "Controller Co",
                "ownership_percentage": 55.0,
                "holder_category": "Lebih dari 5%",
                "is_controller": True,
            },
            {
                "ticker": "ABCD",
                "observed_on": observed_on,
                "holder_name": "Masyarakat Non Warkat",
                "ownership_percentage": 40.0,
                "holder_category": "Masyarakat Non Warkat",
                "is_controller": False,
            },
            {
                "ticker": "ABCD",
                "observed_on": observed_on,
                "holder_name": "Director A",
                "ownership_percentage": 4.0,
                "holder_category": "Direksi",
                "is_controller": False,
            },
            {
                "ticker": "ABCD",
                "observed_on": observed_on,
                "holder_name": "Saham Treasury",
                "ownership_percentage": 1.0,
                "holder_category": "Saham Treasury",
                "is_controller": False,
            },
        ]
    )


def test_controller_profile_extracts_identity_without_fake_free_float():
    features = compute_official_controller_features("ABCD", _price(), _profiles())
    assert features["official_controller_profile_available"] is True
    assert features["official_controller_pct"] == 55.0
    assert features["official_controller_count"] == 1
    assert features["official_profile_major_holder_pct"] == 55.0
    assert features["official_insider_ownership_pct"] == 4.0
    assert features["official_treasury_pct"] == 1.0
    assert features["official_public_share_profile_pct"] == 40.0
    assert features["official_public_share_profile_basis"] == "PUBLIC_SHARE_PROFILE_NOT_REGULATORY_FREE_FLOAT"
    assert features["official_controller_holder_names"] == ["Controller Co"]


def test_controller_profile_blends_with_ksei_ownership_not_replaces_it():
    base = {
        "ownership_score": 70.0,
        "ownership_available": True,
        "slow_evidence_available": True,
        "ownership_report_date": "2026-08-31",
    }
    result = apply_official_controller_overlay("ABCD", _price(), base, profiles=_profiles())
    # Official structure score: 50 + 8 controller + 4 major holder = 62.
    assert result["official_controller_structure_score"] == 62.0
    assert result["ownership_score"] == 66.8
    assert result["ownership_score_basis"] == "KSEI_60__IDX_CONTROLLER_PROFILE_40"
    assert result["ownership_report_date"] == "2026-08-31"


def test_profile_only_can_supply_ownership_structure_when_ksei_missing():
    base = {"ownership_score": 50.0, "ownership_available": False, "slow_evidence_available": False}
    result = apply_official_controller_overlay("ABCD", _price(), base, profiles=_profiles())
    assert result["ownership_available"] is True
    assert result["ownership_score"] == 62.0
    assert result["ownership_score_basis"] == "IDX_CONTROLLER_PROFILE_ONLY"
    assert result["slow_evidence_available"] is True


def test_historical_scan_cannot_consume_future_observed_snapshot():
    base = {"ownership_score": 61.0, "ownership_available": True, "slow_evidence_available": True}
    result = apply_official_controller_overlay(
        "ABCD",
        _price("2026-08-01"),
        base,
        profiles=_profiles("2026-09-06"),
    )
    assert result["official_controller_profile_available"] is False
    assert result["ownership_score"] == 61.0


def test_extreme_controller_concentration_is_derated_not_hard_blocked():
    profiles = pd.DataFrame(
        [
            {
                "ticker": "ABCD",
                "observed_on": "2026-09-06",
                "holder_name": "Controller Co",
                "ownership_percentage": 96.0,
                "holder_category": "Lebih dari 5%",
                "is_controller": True,
            },
            {
                "ticker": "ABCD",
                "observed_on": "2026-09-06",
                "holder_name": "Masyarakat Non Warkat",
                "ownership_percentage": 4.0,
                "holder_category": "Masyarakat Non Warkat",
                "is_controller": False,
            },
        ]
    )
    features = compute_official_controller_features("ABCD", _price(), profiles)
    assert features["official_controller_structure_score"] == 22.0
    assert "official_controller_hard_block" not in features
