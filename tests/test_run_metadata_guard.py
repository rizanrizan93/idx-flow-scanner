from __future__ import annotations

from idx_flow_scanner.run_metadata_guard import (
    RUN_METADATA_GUARD_REVISION,
    install_truthful_run_metadata,
)


def test_run_metadata_guard_records_zapi_only_runtime_and_persistence_revision():
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
        400,
        {
            "version": "0.4.0",
            "broker_direct_enabled": True,
            "broker_provider": "legacy",
        },
    )

    assert result == "ok"
    assert Store.create_run is first
    assert captured["universe_count"] == 400
    config = captured["config"]
    assert config["broker_direct_enabled"] is False
    assert config["broker_provider"] is None
    assert config["indexalpha_acquisition_mode"] == "DISABLED"
    assert config["pipeline_runtime"] == "OHLCV__ZAPI_FLOW__SECTOR__SLOW_EVIDENCE__SMC_ICT"
    assert config["primary_flow_provider"] == "ZAPI"
    assert config["slow_evidence_sources"] == [
        "ZAPI_STOCK_SUMMARY",
        "ZAPI_OWNERSHIP_FILES",
        "ZAPI_CAPITAL_ACTIONS",
    ]
    assert config["result_persistence_revision"] == "v3.18-direct-postgrest-persistence"
    assert config["run_metadata_guard_revision"] == RUN_METADATA_GUARD_REVISION
