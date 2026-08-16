from __future__ import annotations

import pandas as pd
import pytest

from idx_flow_scanner.persistence_guard import install_bounded_result_persistence


class _FakeStore:
    def __init__(self, fail_on_call: int | None = None):
        self.calls: list[int] = []
        self.fail_on_call = fail_on_call
        self.finished: list[dict[str, object]] = []

    def save_results(self, run_id: str, frame: pd.DataFrame) -> None:
        self.calls.append(len(frame))
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
            "processed_count": 63,
            "error_count": 1,
            "status": "FAILED",
        }
    ]


def test_install_is_idempotent_across_streamlit_reruns():
    class Store(_FakeStore):
        pass

    install_bounded_result_persistence(Store, batch_size=25)
    first = Store.save_results
    install_bounded_result_persistence(Store, batch_size=10)

    assert Store.save_results is first
    assert Store._flow_result_persistence_batch_size == 25
