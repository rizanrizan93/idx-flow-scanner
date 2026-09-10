from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MIGRATIONS = ROOT / "supabase" / "migrations"

EXPECTED_POST_TOP900 = [
    "20260909143859_storage_observability_v1.sql",
    "20260909144100_gate11_cold_archive_v1.sql",
    "20260909144632_fix_gate11_archive_qualification_v1.sql",
    "20260909150855_financial_fact_cold_archive_v1.sql",
    "20260909151721_prospective_pipeline_reliability_v2.sql",
    "20260909152916_prospective_stage_isolation_v2.sql",
    "20260909155028_strategy_lifecycle_automation_v2.sql",
    "20260909155327_fix_strategy_lifecycle_monitor_v2.sql",
    "20260909155937_operational_observability_v2.sql",
    "20260909160131_prospective_stage_lifecycle_v3.sql",
    "20260909232309_promotion_safety_hardening_v3.sql",
    "20260909232318_prospective_capture_scheduler_hardening_v4.sql",
    "20260909232758_cold_archive_runtime_resilience_v2.sql",
    "20260909233008_operational_observability_v3.sql",
    "20260909234423_promotion_policy_hash_scope_v3.sql",
    "20260909234425_thesis_terminal_retention_guard_v1.sql",
    "20260909234429_operational_top900_e2e_evidence_v1.sql",
    "20260909234902_storage_registry_classification_v2.sql",
    "20260909235454_remove_verified_duplicate_indexes_v1.sql",
]


def test_all_canonical_post_top900_migrations_are_mirrored():
    missing = [name for name in EXPECTED_POST_TOP900 if not (MIGRATIONS / name).is_file()]
    assert not missing, f"canonical post-Top900 migration drift: missing {missing}"
    assert EXPECTED_POST_TOP900 == sorted(EXPECTED_POST_TOP900)


def test_mirrored_contracts_preserve_fail_closed_and_shadow_safety():
    required_markers = {
        "20260909143859_storage_observability_v1.sql": [
            "flow_storage_status_v1",
            "UNKNOWN_DO_NOT_TOUCH",
            "removal_authorized=false",
        ],
        "20260909144100_gate11_cold_archive_v1.sql": [
            "LOSSLESS",
            "production_influence_enabled=false",
            "flow_restore_gate11_cold_archive_v1",
        ],
        "20260909150855_financial_fact_cold_archive_v1.sql": [
            "flow_financial_shadow_snapshot_v6",
            "FINANCIAL_FACT_EVIDENCE_ARCHIVE_V1",
            "production_influence_enabled", 
        ],
        "20260909151721_prospective_pipeline_reliability_v2.sql": [
            "SOURCE_NOT_READY_TO_CAPTURED_PROVEN",
            "driver_rows<>4500",
            "candidate_rows<>11700",
        ],
        "20260909232309_promotion_safety_hardening_v3.sql": [
            "LIMITED_PRODUCTION",
            "FULL_PRODUCTION",
            "FAIL_CLOSED",
            "frozen_before_first_matured_outcome",
            "production_influence_enabled=false",
        ],
        "20260909232318_prospective_capture_scheduler_hardening_v4.sql": [
            "NON_CURRENT_SESSION_CAPTURE_FORBIDDEN",
            "EOD_CUTOFF_NOT_REACHED",
            "PROSPECTIVE_TOP900_PIPELINE_V4",
            "SIGNAL_PREREQUISITE_NOT_CAPTURED",
        ],
        "20260909234429_operational_top900_e2e_evidence_v1.sql": [
            "selected_count integer not null check(selected_count=900)",
            "attempted_count integer not null check(attempted_count=900)",
            "production_scoring_contract_changed boolean not null default false",
            "experimental_production_influence_enabled boolean not null default false",
        ],
    }
    for name, markers in required_markers.items():
        text = (MIGRATIONS / name).read_text(encoding="utf-8")
        for marker in markers:
            assert marker in text, f"{name} lost canonical safety marker: {marker}"


def test_mirror_does_not_replace_existing_top900_history_aliases():
    # Canonical Supabase recorded Top-900 under 09:11/09:12 versions while the
    # source-controlled PR #97 used 09:30/09:35 filenames.  Reconciliation is
    # additive: do not rewrite the already-merged historical files.
    assert (MIGRATIONS / "20260909093000_operational_top900_runtime_v1.sql").is_file()
    assert (MIGRATIONS / "20260909093500_operational_top900_contract_fk_index_v1.sql").is_file()
