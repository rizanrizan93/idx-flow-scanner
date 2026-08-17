from __future__ import annotations

from typing import Any, Callable


_GUARD_MARKER = "_flow_indexalpha_warm_budget_guard"


def install_cache_only_indexalpha_finalist_loader(module: Any) -> None:
    """Reserve Index Alpha network requests for the audited daily warm job.

    Streamlit may run repeatedly and manual reruns are not a reliable place to
    enforce the provider's global five-request/day free-tier budget. The warm job
    owns those five exact-day RG/all requests; the app consumes only persisted or
    bundled verified broker evidence.
    """
    original: Callable[..., tuple[Any, dict[str, object]]] = module._load_indexalpha_for_finalists
    if getattr(original, _GUARD_MARKER, False):
        return

    def cache_only(finalists, load_price, store, *, allow_live_pull: bool):
        frame, stats = original(
            finalists,
            load_price,
            store,
            allow_live_pull=False,
        )
        stats = dict(stats or {})
        stats["status"] = "CACHE_ONLY_WARM_JOB_BUDGET"
        stats["requests_attempted"] = 0
        stats["streamlit_live_pull_disabled"] = True
        return frame, stats

    setattr(cache_only, _GUARD_MARKER, True)
    module._load_indexalpha_for_finalists = cache_only
