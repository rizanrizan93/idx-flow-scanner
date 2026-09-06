from __future__ import annotations

from typing import Any


RUN_METADATA_GUARD_REVISION = "v0.4.7-official-idx-primary-runtime"
PIPELINE_RUNTIME = (
    "OHLCV__IDX_OFFICIAL_FLOW__ZAPI_FALLBACK__SECTOR__SLOW_EVIDENCE__SMC_ICT"
)


def install_truthful_run_metadata(store_cls: type[Any]) -> None:
    """Normalize persisted run metadata to the active official-first architecture."""
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
                "pipeline": PIPELINE_RUNTIME,
                "pipeline_runtime": PIPELINE_RUNTIME,
                "primary_flow_provider": "IDX_OFFICIAL_STOCK_SUMMARY",
                "fallback_flow_provider": "ZAPI_IDX_FOREIGN_FLOW",
                "zapi_foreign_role": "FALLBACK_ONLY_WHEN_OFFICIAL_ABSENT",
                "official_idx_foreign_primary": True,
                "official_idx_broker_overlay": True,
                "official_idx_index_overlay": True,
                "official_idx_risk_overlay": True,
                "official_idx_controller_overlay": True,
                "slow_evidence_sources": [
                    "IDX_OFFICIAL_CONTROLLER_PROFILE",
                    "CANONICAL_CAPITAL_ACTION_EVIDENCE",
                    "BUNDLED_OR_VENDOR_SLOW_FALLBACK",
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
