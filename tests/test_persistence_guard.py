from __future__ import annotations

import json

import numpy as np
import pandas as pd
import pytest

from idx_flow_scanner.persistence_guard import (
    PERSISTENCE_GUARD_REVISION,
    install_bounded_result_persistence,
)


class _FakeStore:
    def __init__(self, fail_on_call: int | None = None, strict_json: bool = False):
        self.calls: list[int] = []
        self.clients_seen: list[object] = []
        self.fail_on_call = fail_on_call
        self.strict_json = strict_json
        self.frames_seen: list[pd.DataFrame] = []
        self.finished: list[dict[str, object]] = []

    def save_results(self, run_id: str, frame: pd.DataFrame) -> None:
        self.calls.append(len(frame))
        self.clients_seen.append(getattr(self, "client", None))
        self.frames_seen.append(frame.copy())
        if self.strict_json:
            json.dumps(frame.to_dict("records"), allow_nan=False)
        if self.fail_on_call is not None and len(self.calls) == self.fail_on_call:
            raise TimeoutError("simulated PostgREST timeout")

    def finish_run(self, run_id: str, processed_count: int, error_count: int, *, status: str = "COMPLETED", **kwargs) -> None:
        self.finished.append(
            {
                "run_id": run_id,
                "processed_count": processed_count,
                "error_count": error_count,
                "status": status,
            }
        )


def _frame(n: int) -> pd.DataFrame:
    return pd.DataFrame({"ticker": [f"T{i:03d}" for i in range(n)]})


def test_result_persistence_is_bounded_into_small_batches():
    class Store(_FakeStore):
        pass

    install_bounded_result_persistence(Store, batch_size=25)
    store = Store()
    store.save_results("run-1", _frame(63))

    assert store.calls == [25, 25, 13]
    assert Store._flow_result_persistence_batch_size == 25
    assert store.finished == []


def test_result_persistence_failure_closes_run_fail_closed():
    class Store(_FakeStore):
        pass

    install_bounded_result_persistence(Store, batch_size=25)
    store = Store(fail_on_call=2)

    with pytest.raises(TimeoutError):
        store.save_results("run-2", _frame(63))

    assert store.calls == [25, 25]
    assert store.finished == [
        {
            "run_id": "run-2",
            "processed_count": 25,
            "error_count": 1,
            "status": "FAILED",
        }
    ]


def test_dedicated_write_client_is_used_and_read_client_restored():
    class Store(_FakeStore):
        pass

    install_bounded_result_persistence(Store, batch_size=25)
    store = Store()
    read_client = object()
    write_client = object()
    store.client = read_client
    store._flow_persistence_client = write_client

    store.save_results("run-3", _frame(51))

    assert store.calls == [25, 25, 1]
    assert store.clients_seen == [write_client, write_client, write_client]
    assert store.client is read_client


def test_nested_pandas_numpy_diagnostics_are_made_strict_json_safe():
    class Store(_FakeStore):
        pass

    install_bounded_result_persistence(Store, batch_size=20)
    frame = pd.DataFrame(
        {
            "ticker": ["SAFE", "EDGE"],
            "diagnostics": [
                {"score": np.float64(1.25), "when": pd.Timestamp("2026-08-14")},
                {
                    "nested": [np.int64(7), np.float64(np.nan), np.float64(np.inf), pd.NA],
                    "set_value": {"A", "B"},
                },
            ],
        }
    )
    store = Store(strict_json=True)
    store.save_results("run-json", frame)

    assert store.calls == [2]
    seen = store.frames_seen[0].set_index("ticker")
    assert seen.loc["SAFE", "diagnostics"]["score"] == 1.25
    assert seen.loc["SAFE", "diagnostics"]["when"] == "2026-08-14T00:00:00"
    assert seen.loc["EDGE", "diagnostics"]["nested"] == [7, None, None, None]
    assert sorted(seen.loc["EDGE", "diagnostics"]["set_value"]) == ["A", "B"]


def test_install_is_idempotent_across_streamlit_reruns():
    class Store(_FakeStore):
        pass

    install_bounded_result_persistence(Store, batch_size=25)
    first = Store.save_results
    install_bounded_result_persistence(Store, batch_size=10)

    assert Store.save_results is first
    assert Store._flow_result_persistence_batch_size == 25
    assert Store._flow_bounded_result_persistence_revision == PERSISTENCE_GUARD_REVISION


def test_new_revision_reinstalls_over_hot_reloaded_legacy_wrapper():
    class Store(_FakeStore):
        pass

    install_bounded_result_persistence(Store, batch_size=25)
    legacy_wrapper = Store.save_results

    # Simulate a long-lived Streamlit process whose class retained an older
    # monkeypatch while the module source was redeployed.
    Store._flow_bounded_result_persistence_revision = "legacy-revision"
    install_bounded_result_persistence(Store, batch_size=20)

    assert Store.save_results is not legacy_wrapper
    assert Store._flow_result_persistence_batch_size == 20
    assert Store._flow_bounded_result_persistence_revision == PERSISTENCE_GUARD_REVISION
