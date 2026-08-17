from __future__ import annotations

from idx_flow_scanner.run_metadata_guard import (
    RUN_METADATA_GUARD_REVISION,
    install_truthful_run_metadata,
)


def test_run_metadata_guard_reports_cache_only_indexalpha_and_persistence_revision():
    captured = {}

    class Store:
        _flow_bounded_result_persistence_revision = "v3.18-direct-postgrest-persistence"

        def create_run(self, run_id, universe_count, config):
            captured.update({"run_id": run_id, "universe_count": universe_count, "config": config})
            return "ok"

    install_truthful_run_metadata(Store)
    first = Store.create_run
    install_truthful_run_metadata(Store)

    result = Store().create_run(
        "run-1",
        400,
        {
            "version": "0.3.19",
            "indexalpha_live_pull_manual_only": True,
            "pipeline": "400_PROXY__ZAPI__GUARDED_TOP5__INDEX_ALPHA__BROKER_VERIFIED_TOP5",
        },
    )

    assert result == "ok"
    assert Store.create_run is first
    assert captured["universe_count"] == 400
    config = captured["config"]
    assert config["indexalpha_live_pull_manual_only"] is False
    assert config["indexalpha_acquisition_mode"] == "CACHE_ONLY_WARM_JOB_BUDGET"
    assert config["indexalpha_budget_owner"] == "GITHUB_WARM_FLOW_EVIDENCE"
    assert config["indexalpha_daily_request_budget"] == 5
    assert config["result_persistence_revision"] == "v3.18-direct-postgrest-persistence"
    assert config["run_metadata_guard_revision"] == RUN_METADATA_GUARD_REVISION
