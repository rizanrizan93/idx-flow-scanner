from __future__ import annotations

from types import SimpleNamespace

import pytest

from idx_flow_scanner import streamlit_app
from idx_flow_scanner.storage import (
    ACTIVE_UNIVERSE_RUN_CONSTRAINT,
    DuplicateActiveUniverseRunError,
    SupabaseStore,
    is_duplicate_active_run_error,
)


class DatabaseError(Exception):
    def __init__(self, message: str = "", code: str | None = None, details=None):
        super().__init__(message)
        self.message = message
        self.code = code
        self.details = details


def test_named_duplicate_active_run_is_recognized():
    error = DatabaseError(
        f'duplicate key violates unique constraint "{ACTIVE_UNIVERSE_RUN_CONSTRAINT}"',
        "23505",
    )
    assert is_duplicate_active_run_error(error)
    assert is_duplicate_active_run_error(
        RuntimeError(
            f'duplicate key violates unique constraint "{ACTIVE_UNIVERSE_RUN_CONSTRAINT}"'
        )
    )


def test_structured_exact_constraint_forms_are_recognized_without_code_or_message():
    assert is_duplicate_active_run_error(
        DatabaseError(details={"constraint": ACTIVE_UNIVERSE_RUN_CONSTRAINT})
    )
    assert is_duplicate_active_run_error(
        DatabaseError(details={"error": {"diagnostics": {"constraint": ACTIVE_UNIVERSE_RUN_CONSTRAINT}}})
    )

    direct = DatabaseError()
    direct.constraint = ACTIVE_UNIVERSE_RUN_CONSTRAINT
    assert is_duplicate_active_run_error(direct)

    assert is_duplicate_active_run_error(
        Exception({"constraint": ACTIVE_UNIVERSE_RUN_CONSTRAINT})
    )


@pytest.mark.parametrize(
    "error",
    [
        DatabaseError(code="23505"),
        DatabaseError('duplicate key violates unique constraint "some_other_idx"', "23505"),
        DatabaseError(details={"constraint": "some_other_unique_idx"}),
        DatabaseError(details={"constraint": None}),
        RuntimeError("duplicate key violates unique constraint"),
        TimeoutError("network timeout"),
        DatabaseError("authentication failed", "42501"),
        DatabaseError(f'permission denied for {ACTIVE_UNIVERSE_RUN_CONSTRAINT}', "42501"),
        RuntimeError(f"permission denied for {ACTIVE_UNIVERSE_RUN_CONSTRAINT}"),
        RuntimeError("database unavailable"),
        Exception(),
        DatabaseError(details=["malformed", 23505]),
        DatabaseError(details="malformed"),
        Exception({"code": "23505", "user_data": {"value": ACTIVE_UNIVERSE_RUN_CONSTRAINT}}),
    ],
)
def test_unrelated_database_errors_are_not_misclassified(error):
    assert not is_duplicate_active_run_error(error)


def test_storage_raises_dedicated_collision_without_touching_existing_run():
    calls = []
    collision = DatabaseError(
        f'duplicate key violates unique constraint "{ACTIVE_UNIVERSE_RUN_CONSTRAINT}"',
        "23505",
    )

    class Query:
        def upsert(self, payload):
            calls.append(("upsert", payload))
            return self

        def execute(self):
            calls.append(("execute", None))
            raise collision

    class Client:
        def table(self, name):
            calls.append(("table", name))
            return Query()

    store = SupabaseStore.__new__(SupabaseStore)
    store.client = Client()

    with pytest.raises(DuplicateActiveUniverseRunError):
        store.create_run("new-run", 400, {"mode": "managed"})

    assert [name for name, _ in calls] == ["table", "upsert", "execute"]
    assert calls[0][1] == "flow_scan_runs"


def test_duplicate_collision_stops_before_scan_body(monkeypatch):
    events = []

    class Store:
        def create_run(self, *_args, **_kwargs):
            raise DuplicateActiveUniverseRunError("owned")

        def update_run_progress(self, *_args, **_kwargs):
            events.append("updated")

    class StopExecution(RuntimeError):
        pass

    fake_st = SimpleNamespace(
        error=lambda message: events.append(("error", message)),
        warning=lambda message: events.append(("warning", message)),
        stop=lambda: (_ for _ in ()).throw(StopExecution()),
    )
    monkeypatch.setattr(streamlit_app, "st", fake_st)

    with pytest.raises(StopExecution):
        created = streamlit_app.create_durable_run_record(Store(), "new-run", 400, {})
        if created:
            events.append("scan-body")

    assert "updated" not in events
    assert "scan-body" not in events
    assert any(kind == "error" and "lock universe" in message for kind, message in events)


def test_unrelated_persistence_failure_remains_fail_soft(monkeypatch):
    warnings = []

    class Store:
        def create_run(self, *_args, **_kwargs):
            raise RuntimeError("database unavailable")

    fake_st = SimpleNamespace(warning=warnings.append)
    monkeypatch.setattr(streamlit_app, "st", fake_st)

    assert streamlit_app.create_durable_run_record(Store(), "new-run", 400, {}) is False
    assert warnings == ["Could not create RUNNING record in Supabase: database unavailable"]
