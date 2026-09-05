from __future__ import annotations

import pandas as pd

from idx_flow_scanner.canonical_slow_evidence import (
    KSEI_PROVENANCE,
    compute_slow_evidence_canonical,
)


def _price() -> pd.DataFrame:
    dates = pd.bdate_range("2026-04-01", periods=100)
    return pd.DataFrame(
        {
            "date": dates,
            "open": 100.0,
            "high": 102.0,
            "low": 99.0,
            "close": 101.0,
            "volume": 1_000_000.0,
        }
    )


def test_ksei_registration_composition_does_not_double_count_major_holder() -> None:
    ownership = pd.DataFrame(
        [
            {
                "ticker": "TEST",
                "category": "ksei-komposisi",
                "holder_identity_hash": "a" * 64,
                "holder_name": "issued reference",
                "shares_held": 1000,
                "ownership_percentage": None,
                "holder_classification": "KSEI_SECURITY_NUMBER",
                "local_foreign_state": None,
                "report_date": "2026-08-31",
                "source_verified": True,
                "provenance_state": KSEI_PROVENANCE,
            },
            {
                "ticker": "TEST",
                "category": "ksei-komposisi",
                "holder_identity_hash": "b" * 64,
                "holder_name": "scripless total",
                "shares_held": 700,
                "ownership_percentage": 70.0,
                "holder_classification": "KSEI_SCRIPLESS_TOTAL",
                "local_foreign_state": None,
                "report_date": "2026-08-31",
                "source_verified": True,
                "provenance_state": KSEI_PROVENANCE,
            },
            {
                "ticker": "TEST",
                "category": "ksei-komposisi",
                "holder_identity_hash": "c" * 64,
                "holder_name": "local",
                "shares_held": 280,
                "ownership_percentage": 40.0,
                "holder_classification": "KSEI_LOCAL_TOTAL",
                "local_foreign_state": "LOCAL",
                "report_date": "2026-08-31",
                "source_verified": True,
                "provenance_state": KSEI_PROVENANCE,
            },
            {
                "ticker": "TEST",
                "category": "ksei-komposisi",
                "holder_identity_hash": "d" * 64,
                "holder_name": "foreign",
                "shares_held": 420,
                "ownership_percentage": 60.0,
                "holder_classification": "KSEI_FOREIGN_TOTAL",
                "local_foreign_state": "FOREIGN",
                "report_date": "2026-08-31",
                "source_verified": True,
                "provenance_state": KSEI_PROVENANCE,
            },
        ]
    )

    result = compute_slow_evidence_canonical(
        "TEST",
        _price(),
        {"foreign_net_20d": 0.0},
        ownership=ownership,
    )

    assert result["ownership_available"] is True
    assert result["major_holder_pct"] is None
    assert result["reported_foreign_ownership_pct"] == 60.0
    assert result["ownership_basis"] == "KSEI_REGISTRATION_COMPOSITION"
    assert result["ownership_score"] == 50.0
