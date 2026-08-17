from __future__ import annotations

from typing import Any


RUN_METADATA_GUARD_REVISION = "v0.3.19-cache-only-indexalpha-audit"


def install_truthful_run_metadata(store_cls: type[Any]) -> None:
    """Normalize managed-run audit metadata to the actual production architecture.

    Streamlit has been cache-only for Index Alpha since v0.3.16, with the audited
    Warm Flow Evidence job owning the global five-request/day provider budget.
    Older UI code still writes the historical ``indexalpha_live_pull_manual_only``
    flag as true when creating a run. That does not affect scoring because the
    runtime budget guard forces cache-only behavior, but it makes the persistent
    audit trail materially misleading.

    Keep this as a narrow storage-boundary correction so evidence/scoring logic is
    untouched. The persistence revision is captured dynamically at run creation so
    a later runtime audit can prove which result writer was active for that run.
    """
    if getattr(store_cls, "_flow_run_metadata_guard_revision", None) == RUN_METADATA_GUARD_REVISION:
        return

    original_create_run = store_cls.create_run

    def create_run_with_truthful_metadata(store: Any, run_id: str, universe_count: int, config: dict[str, Any]) -> Any:
        normalized = dict(config or {})
        normalized["indexalpha_live_pull_manual_only"] = False
        normalized["indexalpha_acquisition_mode"] = "CACHE_ONLY_WARM_JOB_BUDGET"
        normalized["indexalpha_budget_owner"] = "GITHUB_WARM_FLOW_EVIDENCE"
        normalized["indexalpha_daily_request_budget"] = 5
        normalized["result_persistence_revision"] = str(
            getattr(store_cls, "_flow_bounded_result_persistence_revision", "UNKNOWN")
        )
        normalized["run_metadata_guard_revision"] = RUN_METADATA_GUARD_REVISION
        return original_create_run(store, run_id, universe_count, normalized)

    store_cls.create_run = create_run_with_truthful_metadata
    store_cls._flow_run_metadata_guard_revision = RUN_METADATA_GUARD_REVISION
