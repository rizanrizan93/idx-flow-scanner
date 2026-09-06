from __future__ import annotations

from idx_flow_scanner.run_metadata_guard import (
    PIPELINE_RUNTIME,
    RUN_METADATA_GUARD_REVISION,
    install_truthful_run_metadata,
)


def test_run_metadata_guard_records_official_idx_primary_runtime_and_persistence_revision():
    captured = {}

    class Store:
        _flow_bounded_result_persistence_revision = "v3.18-direct-postgrest-persistence"

        def create_run(self, run_id, universe_count, config):
            captured.update(
                {"run_id": run_id, "universe_count": universe_count, "config": config}
            )
            return "ok"

    install_truthful_run_metadata(Store)
    first = Store.create_run
    install_truthful_run_metadata(Store)

    result = Store().create_run(
        "run-1",
        700,
        {
            "version": "0.4.7",
            "broker_direct_enabled": True,
            "broker_provider": "legacy",
            "primary_flow_provider": "ZAPI",
        },
    )

    assert result == "ok"
    assert Store.create_run is first
    assert captured["universe_count"] == 700
    config = captured["config"]
    assert config["broker_direct_enabled"] is False
    assert config["broker_provider"] is None
    assert config["indexalpha_acquisition_mode"] == "DISABLED"
    assert config["pipeline"] == PIPELINE_RUNTIME
    assert config["pipeline_runtime"] == PIPELINE_RUNTIME
    assert config["primary_flow_provider"] == "IDX_OFFICIAL_STOCK_SUMMARY"
    assert config["fallback_flow_provider"] == "ZAPI_IDX_FOREIGN_FLOW"
    assert config["zapi_foreign_role"] == "FALLBACK_ONLY_WHEN_OFFICIAL_ABSENT"
    assert config["official_idx_foreign_primary"] is True
    assert config["official_idx_broker_overlay"] is True
    assert config["official_idx_index_overlay"] is True
    assert config["official_idx_risk_overlay"] is True
    assert config["official_idx_controller_overlay"] is True
    assert config["slow_evidence_sources"] == [
        "IDX_OFFICIAL_CONTROLLER_PROFILE",
        "CANONICAL_CAPITAL_ACTION_EVIDENCE",
        "BUNDLED_OR_VENDOR_SLOW_FALLBACK",
    ]
    assert config["result_persistence_revision"] == "v3.18-direct-postgrest-persistence"
    assert config["run_metadata_guard_revision"] == RUN_METADATA_GUARD_REVISION
