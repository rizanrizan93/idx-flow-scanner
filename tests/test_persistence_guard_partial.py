from __future__ import annotations

import pandas as pd
import pytest

from idx_flow_scanner.persistence_guard import install_bounded_result_persistence


class _Query:
    def __init__(self, client, table):
        self.client = client
        self.table = table

    def upsert(self, rows, on_conflict=None):
        if self.table == "flow_scan_results":
            self.client.calls += 1
            if self.client.calls == 2:
                raise RuntimeError("simulated PostgREST failure")
            self.client.persisted.extend(row["ticker"] for row in rows)
        return self

    def update(self, payload):
        return self

    def eq(self, *args):
        return self

    def execute(self):
        return type("Response", (), {"data": []})()


class _Client:
    def __init__(self):
        self.calls = 0
        self.persisted = []

    def table(self, name):
        return _Query(self, name)


def _frame(n: int) -> pd.DataFrame:
    rows = []
    for i in range(n):
        rows.append({
            "ticker": f"T{i:03d}",
            "as_of_date": "2026-08-14",
            "final_score": 50.0,
            "phase": "NEUTRAL",
            "action": "RESEARCH_ONLY",
            "evidence_tier": "PRICE_PROXY",
            "evidence_coverage_pct": 0.0,
            "real_money_state": "GUARDED",
            "distribution_risk": 50.0,
            "estimated_smart_money_cost": None,
            "premium_to_cost_pct": None,
            "entry_low": 100.0,
            "entry_high": 101.0,
            "invalidation": 95.0,
            "tp1": 110.0,
            "tp2": 115.0,
            "accumulation_score": 50.0,
            "operator_dominance_score": 50.0,
            "cost_basis_score": 50.0,
            "retail_exhaustion_score": 50.0,
            "foreign_institutional_score": 50.0,
            "supply_concentration_score": 50.0,
            "price_flow_divergence_score": 50.0,
            "market_context_score": 50.0,
            "smc_execution_score": 50.0,
            "risk_liquidity_score": 50.0,
            "price_data_quality_score": 100.0,
            "diagnostics": {},
            "guardrail_reason": "test",
        })
    return pd.DataFrame(rows)


def test_partial_persistence_reports_only_completed_rows():
    class Store:
        def __init__(self):
            self.client = _Client()
            self._flow_persistence_client = self.client
            self.finished = None

        def save_results(self, run_id, frame):
            raise AssertionError("legacy persistence path must not be called")

        def finish_run(self, run_id, processed_count, error_count, *, status="COMPLETED", **kwargs):
            self.finished = {
                "run_id": run_id,
                "processed_count": processed_count,
                "error_count": error_count,
                "status": status,
            }

    install_bounded_result_persistence(Store, batch_size=20)
    store = Store()

    with pytest.raises(RuntimeError, match="simulated PostgREST failure"):
        store.save_results("run-1", _frame(45))

    assert len(store.client.persisted) == 20
    assert store.finished == {
        "run_id": "run-1",
        "processed_count": 20,
        "error_count": 1,
        "status": "FAILED",
    }
