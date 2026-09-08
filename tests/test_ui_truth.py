from __future__ import annotations

from types import SimpleNamespace

import pandas as pd

from idx_flow_scanner.ui_truth import load_calibration_truth, summarize_effective_evidence


def test_summarize_effective_evidence_uses_scored_rows_not_raw_inputs():
    results = pd.DataFrame(
        [
            {
                "ticker": "AAAA",
                "evidence_tier": "OFFICIAL_IDX_FLOW",
                "diagnostics": {
                    "listed_shares": 1000,
                    "tradable_shares": 500,
                    "ownership_available": True,
                    "ownership_score_basis": "KSEI_60__IDX_CONTROLLER_PROFILE_40",
                    "official_controller_profile_available": True,
                    "corporate_action_available": True,
                    "recent_corporate_actions": [{"event_type": "RIGHTS_ISSUE"}],
                },
            },
            {
                "ticker": "BBBB",
                "evidence_tier": "OFFICIAL_IDX_FLOW",
                "diagnostics": {
                    "listed_shares": None,
                    "tradable_shares": None,
                    "ownership_available": True,
                    "ownership_score_basis": "IDX_CONTROLLER_PROFILE_ONLY",
                    "official_controller_profile_available": True,
                    "corporate_action_available": False,
                    "recent_corporate_actions": [],
                },
            },
            {
                "ticker": "CCCC",
                "evidence_tier": "PRICE_PROXY",
                "diagnostics": {
                    "listed_shares": 2000,
                    "tradable_shares": 1000,
                    "ownership_available": False,
                    "official_controller_profile_available": False,
                    "corporate_action_available": True,
                    "recent_corporate_actions": [],
                },
            },
        ]
    )

    truth = summarize_effective_evidence(results)
    assert truth == {
        "total": 3,
        "verified_flow": 2,
        "official_flow": 2,
        "fallback_flow": 0,
        "price_proxy": 1,
        "stock_structure": 2,
        "ownership": 2,
        "ownership_ksei_controller": 1,
        "ownership_controller_only": 1,
        "corporate_action_history": 2,
        "recent_corporate_actions": 1,
    }


class _FakeQuery:
    def __init__(self, rows):
        self.rows = rows
        self.start = 0
        self.end = 999

    def select(self, *_args, **_kwargs):
        return self

    def order(self, *_args, **_kwargs):
        return self

    def range(self, start, end):
        self.start = start
        self.end = end
        return self

    def execute(self):
        return SimpleNamespace(data=self.rows[self.start : self.end + 1])


class _FakeClient:
    def __init__(self, rows):
        self.rows = rows

    def table(self, name):
        assert name == "flow_signal_outcomes"
        return _FakeQuery(self.rows)


class _FakeStore:
    def __init__(self, rows):
        self.client = _FakeClient(rows)


def test_load_calibration_truth_counts_maturity_from_canonical_rows():
    rows = [
        {
            "as_of_date": "2026-08-01",
            "return_5d": 1.0,
            "return_20d": None,
            "return_60d": None,
            "evaluation_status": "PARTIAL",
        },
        {
            "as_of_date": "2026-08-02",
            "return_5d": 2.0,
            "return_20d": 3.0,
            "return_60d": None,
            "evaluation_status": "PARTIAL",
        },
        {
            "as_of_date": "2026-08-03",
            "return_5d": 1.0,
            "return_20d": 2.0,
            "return_60d": 4.0,
            "evaluation_status": "COMPLETE",
        },
        {
            "as_of_date": "2026-09-01",
            "return_5d": None,
            "return_20d": None,
            "return_60d": None,
            "evaluation_status": "PENDING",
        },
    ]

    truth = load_calibration_truth(_FakeStore(rows), page_size=2, max_rows=20)
    assert truth["available"] is True
    assert truth["total"] == 4
    assert truth["mature_5d"] == 3
    assert truth["mature_20d"] == 2
    assert truth["mature_60d"] == 1
    assert truth["pending"] == 1
    assert truth["partial"] == 2
    assert truth["complete"] == 1
    assert truth["excluded"] == 0
    assert truth["truncated"] is False
