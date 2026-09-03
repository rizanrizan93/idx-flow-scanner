from __future__ import annotations

from typing import Any


RUN_METADATA_GUARD_REVISION = "v0.4.0-zapi-only-runtime"


def install_truthful_run_metadata(store_cls: type[Any]) -> None:
    """Normalize persisted run metadata to the ZAPI-only production architecture."""
    if getattr(store_cls, "_flow_run_metadata_guard_revision", None) == RUN_METADATA_GUARD_REVISION:
        return

    original_create_run = store_cls.create_run

    def create_run_with_truthful_metadata(
        store: Any,
        run_id: str,
        universe_count: int,
        config: dict[str, Any],
    ) -> Any:
        normalized = dict(config or {})
        normalized.update(
            {
                "broker_direct_enabled": False,
                "broker_provider": None,
                "indexalpha_acquisition_mode": "DISABLED",
                "pipeline_runtime": "OHLCV__ZAPI_FLOW__SECTOR__SLOW_EVIDENCE__SMC_ICT",
                "primary_flow_provider": "ZAPI",
                "slow_evidence_sources": [
                    "ZAPI_STOCK_SUMMARY",
                    "ZAPI_OWNERSHIP_FILES",
                    "ZAPI_CAPITAL_ACTIONS",
                ],
                "result_persistence_revision": str(
                    getattr(store_cls, "_flow_bounded_result_persistence_revision", "UNKNOWN")
                ),
                "run_metadata_guard_revision": RUN_METADATA_GUARD_REVISION,
            }
        )
        return original_create_run(store, run_id, universe_count, normalized)

    store_cls.create_run = create_run_with_truthful_metadata
    store_cls._flow_run_metadata_guard_revision = RUN_METADATA_GUARD_REVISION
