from __future__ import annotations

import importlib

import idx_flow_scanner.persistence_guard as persistence_guard
from idx_flow_scanner.runtime_persistence import install_current_result_persistence


def test_runtime_installer_forces_reload_and_sets_current_revision(monkeypatch):
    reload_calls = []
    real_reload = importlib.reload

    def tracked_reload(module):
        reload_calls.append(module.__name__)
        return real_reload(module)

    monkeypatch.setattr(importlib, "reload", tracked_reload)

    class Store:
        save_results = lambda self, run_id, frame: None

    revision = install_current_result_persistence(Store, batch_size=20)

    assert reload_calls == ["idx_flow_scanner.persistence_guard"]
    assert revision == persistence_guard.PERSISTENCE_GUARD_REVISION
    assert Store._flow_bounded_result_persistence_revision == persistence_guard.PERSISTENCE_GUARD_REVISION
    assert Store._flow_result_persistence_batch_size == 20
