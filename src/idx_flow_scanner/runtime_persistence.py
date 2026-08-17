from __future__ import annotations

import importlib
from typing import Any


def install_current_result_persistence(store_cls: type[Any], *, batch_size: int = 20) -> str:
    """Reload and install the current persistence guard in long-lived Streamlit runtimes.

    Streamlit Community Cloud can rerun a changed entrypoint while retaining already
    imported package modules in ``sys.modules``. That means a new ``app.py`` may be
    executing while ``idx_flow_scanner.persistence_guard`` still contains an older
    installer. The production symptom is a new scanner VERSION combined with an
    absent/old persistence revision and the historical 200-row write ceiling.

    Explicitly reload the module from the deployed source before installation. The
    installer itself is revision-aware, so a same-revision rerun remains idempotent
    while a deployment with newer source replaces any retained legacy writer.
    """
    from . import persistence_guard

    current = importlib.reload(persistence_guard)
    current.install_bounded_result_persistence(store_cls, batch_size=batch_size)
    return str(getattr(store_cls, "_flow_bounded_result_persistence_revision", "UNKNOWN"))
