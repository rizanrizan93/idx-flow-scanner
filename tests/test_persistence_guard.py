from __future__ import annotations

import json

import numpy as np
import pandas as pd
import pytest

from idx_flow_scanner.persistence_guard import (
    PERSISTENCE_GUARD_REVISION,
    _result_records,
    install_bounded_result_persistence,
)


class _FakeQuery:
    def __init__(self, client, table: str):
        self.client = client
        self.table = table
        self.count_requested = False
        self.run_id_filter: str | None = None

    def upsert(self, rows, on_conflict=None):
        self.client.write_calls.append((self.table, rows, on_conflict))
        if self.client.fail_on_call is not None and len(self.client.write_calls) == self.client.fail_on_call:
            raise TimeoutError("simulated PostgREST timeout")
        if self.client.strict_json:
            json.dumps(rows, allow_nan=False)
        if self.table == "flow_scan_results":
            for row in rows:
                if self.client.silent_persist_limit is not None and self.client.persisted_total >= self.client.silent_persist_limit:
                    continue
                run_id = str(row["run_id"])
                ticker = str(row["ticker"])
                self.client.persisted.setdefault(run_id, set()).add(ticker)
                self.client.persisted_total = sum(len(v) for v in self.client.persisted.values())
        return self

    def select(self, _columns, count=None):
        self.count_requested = count == "exact"
        return self

    def update(self, payload):
        self.client.heartbeats.append((self.table, payload))
        return self

    def eq(self, column, value):
        if column == "run_id":
            self.run_id_filter = str(value)
        return self

    def execute(self):
        count = None
        if self.count_requested:
            count = len(self.client.persisted.get(str(self.run_id_filter), set()))
        return type("Response", (), {"data": [], "count": count})()


class _FakeClient:
    def __init__(
        self,
        fail_on_call: int | None = None,
        strict_json: bool = False,
        silent_persist_limit: int | None = None,
    ):
        self.fail_on_call = fail_on_call
        self.strict_json = strict_json
        self.silent_persist_limit = silent_persist_limit
        self.write_calls: list[tuple[str, list[dict], str | None]] = []
        self.heartbeats: list[tuple[str, dict]] = []
        self.persisted: dict[str, set[str]] = {}
        self.persisted_total = 0

    def table(self, name: str):
        return _FakeQuery(self, name)


class _FakeStore:
    def __init__(
        self,
        fail_on_call: int | None = None,
        strict_json: bool = False,
        silent_persist_limit: int | None = None,
    ):
        self.client = _FakeClient(
            fail_on_call=fail_on_call,
            strict_json=strict_json,
            silent_persist_limit=silent_persist_limit,
        )
        self._flow_persistence_client = self.client
        self.finished: list[dict[str, object]] = []

    def save_results(self, run_id: str, frame: pd.DataFrame) -> None:
        raise AssertionError("legacy save_results must never be called")

    def finish_run(self, run_id: str, processed_count: int, error_count: int, *, status: str = "COMPLETED", **kwargs) -> None:
        self.finished.append({"run_id": run_id, "processed_count": processed_count, "error_count": error_count, "status": status})


def _frame(n: int) -> pd.DataFrame:
    rows=[]
    for i in range(n):
        rows.append({
            "ticker":f"T{i:03d}","as_of_date":"2026-08-14","final_score":50.0,"phase":"NEUTRAL",
            "action":"RESEARCH_ONLY","evidence_tier":"PRICE_PROXY","evidence_coverage_pct":0.0,
            "real_money_state":"GUARDED","distribution_risk":50.0,"estimated_smart_money_cost":None,
            "premium_to_cost_pct":None,"entry_low":100.0,"entry_high":101.0,"invalidation":95.0,"tp1":110.0,"tp2":115.0,
            "accumulation_score":50.0,"operator_dominance_score":50.0,"cost_basis_score":50.0,
            "retail_exhaustion_score":50.0,"foreign_institutional_score":50.0,"supply_concentration_score":50.0,
            "price_flow_divergence_score":50.0,"market_context_score":50.0,"smc_execution_score":50.0,
            "risk_liquidity_score":50.0,"price_data_quality_score":100.0,"diagnostics":{},"guardrail_reason":"test",
        })
    return pd.DataFrame(rows)


def test_result_persistence_is_bounded_into_small_batches():
    class Store(_FakeStore): pass
    install_bounded_result_persistence(Store, batch_size=25)
    store=Store(); store.save_results("run-1",_frame(63))
    assert [len(call[1]) for call in store.client.write_calls] == [25,25,13]
    assert all(call[0] == "flow_scan_results" for call in store.client.write_calls)
    assert len(store.client.persisted["run-1"]) == 63
    assert store.finished == []


def test_result_persistence_failure_closes_run_fail_closed():
    class Store(_FakeStore): pass
    install_bounded_result_persistence(Store,batch_size=25)
    store=Store(fail_on_call=2)
    with pytest.raises(TimeoutError): store.save_results("run-2",_frame(63))
    assert [len(call[1]) for call in store.client.write_calls] == [25,25]
    assert store.finished == [{"run_id":"run-2","processed_count":25,"error_count":1,"status":"FAILED"}]


def test_direct_path_bypasses_retained_legacy_wrapper_chain():
    class Store(_FakeStore): pass
    legacy_calls=[]
    def legacy_wrapper(self, run_id, frame):
        legacy_calls.append(len(frame)); raise AssertionError("retained wrapper called")
    Store.save_results=legacy_wrapper
    Store._flow_bounded_result_persistence_revision="legacy-revision"
    install_bounded_result_persistence(Store,batch_size=20)
    store=Store(); store.save_results("run-3",_frame(45))
    assert legacy_calls == []
    assert [len(call[1]) for call in store.client.write_calls] == [20,20,5]


def test_nested_pandas_numpy_diagnostics_are_strict_json_safe():
    class Store(_FakeStore): pass
    install_bounded_result_persistence(Store,batch_size=20)
    frame=_frame(2)
    frame.at[0,"diagnostics"]={"score":np.float64(1.25),"when":pd.Timestamp("2026-08-14")}
    frame.at[1,"diagnostics"]={"nested":[np.int64(7),np.float64(np.nan),np.float64(np.inf),pd.NA],"set_value":{"A","B"}}
    store=Store(strict_json=True); store.save_results("run-json",frame)
    payload=store.client.write_calls[0][1]
    assert payload[0]["diagnostics"]["score"] == 1.25
    assert payload[0]["diagnostics"]["when"] == "2026-08-14T00:00:00"
    assert payload[1]["diagnostics"]["nested"] == [7,None,None,None]
    assert sorted(payload[1]["diagnostics"]["set_value"]) == ["A","B"]


def test_persistence_mirrors_fail_closed_authorization_inside_existing_diagnostics_json():
    frame = _frame(1)
    frame["production_authorized"] = True
    records = _result_records("run-auth", frame)
    assert "production_authorized" not in records[0]
    assert records[0]["diagnostics"]["production_authorized"] is False


def test_silent_partial_persistence_is_detected_by_exact_database_count():
    class Store(_FakeStore): pass
    install_bounded_result_persistence(Store,batch_size=20)
    store=Store(silent_persist_limit=40)
    with pytest.raises(RuntimeError, match="expected 63 rows, found 40"):
        store.save_results("run-partial",_frame(63))
    assert [len(call[1]) for call in store.client.write_calls] == [20,20,20,3]
    assert store.finished == [{"run_id":"run-partial","processed_count":40,"error_count":1,"status":"FAILED"}]


def test_install_is_idempotent_same_revision_but_replaces_old_revision():
    class Store(_FakeStore): pass
    install_bounded_result_persistence(Store,batch_size=20)
    first=Store.save_results
    install_bounded_result_persistence(Store,batch_size=10)
    assert Store.save_results is first
    Store._flow_bounded_result_persistence_revision="legacy-revision"
    install_bounded_result_persistence(Store,batch_size=10)
    assert Store.save_results is not first
    assert Store._flow_result_persistence_batch_size == 10
    assert Store._flow_bounded_result_persistence_revision == PERSISTENCE_GUARD_REVISION
