-- Object-specific storage classification after dependency and code-path review.
-- UNKNOWN_DO_NOT_TOUCH remains valid for objects whose semantics are not proven;
-- no registry row ever authorizes removal.
update public.flow_storage_object_registry_v1 set
  storage_class='COLD_RESEARCH',
  operational_dependency='RUNTIME_EXECUTION_REVOKED; EXPLICIT_RESTORE_ONLY',
  research_dependency='LOSSLESS_GATE11_OR_FINANCIAL_FACT_ARCHIVE',
  reproducibility_state='LOSSLESS_COMPRESSED_CHUNKS_WITH_SHA256_AND_ROW_COUNT_VERIFICATION',
  retention_requirement='RETAIN PERMANENTLY UNTIL EXTERNAL VERSIONED ARCHIVE IS VERIFIED',
  canonical_state='CANONICAL_IMMUTABLE_COLD_ARCHIVE',
  derivation_state='RESTORABLE_BY_SERVICE_REVOKED_ADMIN_FUNCTION',
  write_frequency='IMMUTABLE_AFTER_FINALIZATION',reviewed_at=statement_timestamp()
where object_name in('flow_cold_archive_chunk_v1','flow_cold_archive_contract_v1',
  'flow_cold_archive_manifest_v1');

update public.flow_storage_object_registry_v1 set
  storage_class='HOT_OPERATIONAL',
  operational_dependency='DIRECT_PRODUCTION_BROKER_OR_MARKET_MEMORY_DEPENDENCY',
  research_dependency='CALIBRATION_AND_PRODUCTION_AUDIT_DEPENDENCY',
  retention_requirement='RETAIN ACTIVE AND ROLLING CONTRACT HISTORY',
  canonical_state='CANONICAL_OPERATIONAL_EVIDENCE_OR_MODEL_STATE',
  derivation_state='NOT_PROVEN_DERIVABLE',reviewed_at=statement_timestamp()
where object_name in(
  'flow_broker_behavior_features_v2','flow_broker_ticker_affinity_v3',
  'flow_official_broker_activity','flow_ticker_affinity_consensus_v3',
  'flow_broker_adaptive_daily_observations','flow_broker_coalition_ticker_affinity_v3',
  'flow_ingestion_audit','flow_broker_adaptive_score_observations','flow_broker_flows',
  'flow_broker_coalition_sector_affinity_v3','flow_broker_market_regime_v2',
  'flow_official_broker_directory','flow_broker_coalition_edges_v3',
  'flow_broker_coalition_members_v3','flow_broker_coalitions_v3',
  'flow_market_memory_manifest_v4','flow_broker_ticker_affinity_snapshot_v3',
  'flow_broker_coalition_snapshot_v3','flow_ticker_affinity_consensus_snapshot_v3',
  'flow_broker_adaptive_calibration_history','flow_broker_adaptive_calibration_state');

update public.flow_storage_object_registry_v1 set
  storage_class='WARM_VALIDATION',
  operational_dependency='SCHEDULED_PROSPECTIVE_OR_POLICY_STATE_DEPENDENCY',
  research_dependency='FORWARD_CONFIRMATION_AND_PROMOTION_AUDIT_DEPENDENCY',
  reproducibility_state='CANONICAL_AUDIT_STATE_NOT_REPLAY_SUBSTITUTE',
  retention_requirement='RETAIN THROUGH PROMOTION AND POST_PROMOTION MONITORING',
  canonical_state='CANONICAL_CONTROL_OR_PROSPECTIVE_STATE',
  derivation_state='NOT_DISPOSABLE_DERIVED_DATA',reviewed_at=statement_timestamp()
where object_name in(
  'flow_strategy_lifecycle_policy_v3','flow_strategy_lifecycle_state_v3',
  'flow_strategy_lifecycle_history_v3','flow_prospective_pipeline_run_v2',
  'flow_data_gap_registry_v2','flow_operational_e2e_manifest_v1');

update public.flow_storage_object_registry_v1 set
  storage_class='COLD_RESEARCH',
  operational_dependency='SUPERSEDED_RUNTIME_EXECUTION_REVOKED',
  research_dependency='HISTORICAL_POLICY_TRANSITION_AUDIT_ONLY',
  reproducibility_state='IMMUTABLE_SUPERSEDED_CONTRACT',
  retention_requirement='RETAIN COMPACT AUDIT ROWS',
  canonical_state='SUPERSEDED_VERSIONED_CONTROL_STATE',
  derivation_state='NOT_CURRENT_RUNTIME',reviewed_at=statement_timestamp()
where object_name in('flow_strategy_lifecycle_policy_v2',
  'flow_strategy_lifecycle_state_v2','flow_strategy_lifecycle_history_v2');

update public.flow_storage_object_registry_v1 set
  storage_class='WARM_VALIDATION',
  operational_dependency='INCREMENTAL_FINANCIAL_FEATURE_REFRESH_SOURCE_OR_MANIFEST',
  research_dependency='PIT_FINANCIAL_LINEAGE_AND_EXCLUSION_AUDIT',
  reproducibility_state='CANONICAL_PIT_SOURCE_OR_LINEAGE_MANIFEST',
  retention_requirement='RETAIN; ARCHIVE ONLY WITH HASHED LOSSLESS COPY',
  canonical_state='CANONICAL_PIT_FINANCIAL_EVIDENCE',
  derivation_state='RAW_FILING_EVIDENCE_NOT_SAFELY_DISPOSABLE',reviewed_at=statement_timestamp()
where object_name in(
  'flow_financial_filing_evidence_v5','flow_financial_fact_manifest_filing_v5',
  'flow_financial_fact_manifest_exclusion_v5','flow_financial_fact_manifest_v5',
  'flow_financial_fact_shard_ingest_v5','flow_evidence_source_registry_v5',
  'flow_financial_metric_catalog_v5','flow_disclosure_evidence_v5',
  'flow_major_holder_ownership_evidence_v5');

update public.flow_storage_object_registry_v1 set
  storage_class='HOT_OPERATIONAL',
  operational_dependency='UNIVERSE_VERSION_OR_STORAGE_CONTROL_STATE',
  research_dependency='SURVIVORSHIP_OR_OPERATIONAL_AUDIT_DEPENDENCY',
  reproducibility_state='CANONICAL_CONTROL_STATE',
  retention_requirement='RETAIN PERMANENTLY',
  canonical_state='CANONICAL_CONTROL_OR_AUDIT_STATE',
  derivation_state='NOT_DISPOSABLE_DERIVED_DATA',reviewed_at=statement_timestamp()
where object_name in(
  'flow_universe_baseline_member_v1','flow_universe_contract_v1',
  'flow_storage_dependency_v1','flow_storage_relation_measurement_v1',
  'flow_storage_object_registry_v1','flow_storage_measurement_v1',
  'flow_storage_policy_v1');

insert into public.flow_storage_dependency_v1(
  object_name,dependency_type,dependent_name,dependency_detail
) values
  ('flow_universe_snapshot_v1','APPLICATION_CODE','operational_top900.py',
    'Canonical Top-900 membership and fail-closed runtime guards'),
  ('flow_official_stock_summary','APPLICATION_CODE','large_universe_prices.py',
    'Operational price RPC source consumed by scanner runtime'),
  ('flow_official_stock_summary','APPLICATION_CODE','verified_foreign_store.py',
    'Verified official IDX foreign evidence runtime'),
  ('flow_official_broker_activity','APPLICATION_CODE','broker_behavior.py',
    'Production broker behavior overlay'),
  ('flow_broker_flows','APPLICATION_CODE','storage.py',
    'Legacy compatible rolling broker persistence'),
  ('flow_scan_results','APPLICATION_CODE','runtime_persistence.py',
    'Production scan result persistence'),
  ('flow_universe_snapshot_v1','GITHUB_WORKFLOW','refresh-universe-900.yml',
    'Deterministic prospective Top-900 refresh workflow'),
  ('flow_official_stock_summary','TEST_CONTRACT','test_operational_top900_runtime.py',
    'Top-900 official source and insufficient-history regression contract')
on conflict(object_name,dependency_type,dependent_name) do update set
  dependency_detail=excluded.dependency_detail,captured_at=statement_timestamp();
