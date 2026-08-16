from __future__ import annotations

import pandas as pd
import pytest

from idx_flow_scanner.persistence_guard import install_bounded_result_persistence


class _Query:
    def update(self, payload):
        self.payload = payload
        return self

    def eq(self, *args):
        return self

    def execute(self):
        return None


class _Client:
    def table(self, name):
        return _Query()


def test_partial_persistence_reports_only_completed_rows():
    class Store:
        def __init__(self):
            self.client = _Client()
            self.url = ""
            self.secret_key = ""
            self.calls = 0
            self.persisted = []
            self.finished = None

        def save_results(self, run_id, frame):
            self.calls += 1
            if self.calls == 2:
                raise RuntimeError("simulated PostgREST failure")
            self.persisted.extend(frame["ticker"].tolist())

        def finish_run(self, run_id, processed_count, error_count, *, status="COMPLETED", **kwargs):
            self.finished = {
                "run_id": run_id,
                "processed_count": processed_count,
                "error_count": error_count,
                "status": status,
            }

    install_bounded_result_persistence(Store, batch_size=20)
    store = Store()
    frame = pd.DataFrame({"ticker": [f"T{i:03d}" for i in range(45)]})

    with pytest.raises(RuntimeError, match="simulated PostgREST failure"):
        store.save_results("run-1", frame)

    assert len(store.persisted) == 20
    assert store.finished == {
        "run_id": "run-1",
        "processed_count": 20,
        "error_count": 1,
        "status": "FAILED",
    }
