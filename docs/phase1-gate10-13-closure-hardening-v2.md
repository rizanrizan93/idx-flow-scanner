# IDX Flow Scanner — Phase 1 Gate 10–13 Closure Hardening V2

## Scope
This closure hardens Gate 10–13 research infrastructure only. Production scoring, ranking, action, authorization, and execution remain unchanged.

## Supersession
V1 research contracts are preserved as immutable history. V2 supersedes them for research closure:

- Registry: `IDX_DRIVER_REGISTRY_GATE10_V2`
- PIT panel: `IDX_DRIVER_WEEKLY_PIT_PANEL_V2`
- Single-driver validation: `IDX_DRIVER_PURGED_EXPANDING_WF_V2`
- Confluence validation: `IDX_DRIVER_BOUNDED_CONFLUENCE_WF_V2`

## Gate 10 V2
- 69 drivers
- 8 families
- 37 evaluation-eligible drivers
- 12 preregistered interactions
- `MKT_RISK_ON_CONTEXT` corrected from degenerate same-date IHSG ranking to trailing PIT market ranking using up to 252 historical observations and no future dates.
- `TECH_CHOCH` dependency metadata explicitly includes `return_20d_pct`.
- FIN_BALANCE discovery overlap remains explicit and non-promotable without untouched forward confirmation.
- Production influence: OFF.

## Gate 11 V2
Canonical staged refresh order:

1. `flow_refresh_driver_signal_stage_v2()`
2. `flow_refresh_driver_feature_stage_v2()`
3. `flow_restore_gate11_pit_rollups_v2()`
4. `flow_refresh_driver_lineage_v2()`
5. `flow_finalize_driver_panel_v2()`

The stages run one transaction at a time to remain below statement timeout while preserving source rebuild semantics.

Final canonical panel evidence:
- signal rows: 56,552
- feature rows: 56,552
- logical driver observations: 2,092,424
- available observations: 1,879,330
- eligible drivers with zero coverage: 0
- future evidence leakage: 0
- revision leakage: 0
- target leakage: 0
- panel digest: `6863141568e800b29fb82f9df7ef7d1e`
- second full rebuild produced the identical digest
- production influence: OFF

Historical sector membership remains unavailable and fail-closed. Current sector membership is not backfilled into historical PIT research.

## Gate 12 V2
- 6 frozen purged expanding walk-forward folds
- 37/37 evaluation-eligible drivers evaluated
- 888 metric cells
- invalid metric cells: 0
- computed training target overlap leaks: 0
- computed training universe mismatch cells: 0
- robustness slices span both folds
- missing robustness fails closed
- Phase 2 eligible drivers: 0

`FIN_BALANCE` remains the sole PROMISING single driver:
- valid OOS cells: 18
- positive OOS cells: 16
- direction agreement: 88.89%
- mean OOS alpha spread: +1.2723%
- heldout: +1.7850%
- forward: +1.7582%
- rank IC: +0.0159
- positive horizons: 3/3
- panel coverage: 88.4885%
- regime consistency: 94.44%
- liquidity consistency: 80.00%
- confirmation state: `DISCOVERY_REPLAY_NOT_INDEPENDENT_CONFIRMATION`
- eligible to enter Phase 2: false

The OOS runner uses streamed CTEs to avoid temporary-disk spill; there is no temporary 3-horizon materialization.

## Gate 13 V2
- 12/12 preregistered interactions represented in summary
- exactly 5 non-sector interactions have raw metrics
- 120 interaction metric cells
- 7 sector-dependent interactions fail closed
- validated interactions: 0
- Phase 2 eligible interactions: 0
- computed target leakage count: 0
- computed post-hoc mining count: 0
- interaction budget respected
- robustness slices span both folds
- production influence: OFF

Interactions containing `FIN_BALANCE` carry an executable eligibility hard block: even a future `VALIDATED_CONFLUENCE` classification cannot become Phase-2 eligible until independent untouched forward confirmation exists.

Raw positive interaction alpha is not interpreted as validated confluence. All five measurable interactions remain `INSUFFICIENT_EVIDENCE` because frozen sample/coverage/robustness/incremental-lift requirements are not met.

## Security
V2 research objects retain RLS and service-role-only access. V2 functions are SECURITY INVOKER, use explicit empty `search_path`, and revoke execute from public/anon/authenticated.

## Production isolation
No production Python runtime source is modified by this closure. No Gate 10–13 V2 result changes production final score, rank, action, real-money authorization, or execution readiness.

## Closure decision
Phase 1 may be considered formally CLOSED only after repository migration parity, regression CI, merge to `main`, and post-merge canonical readback are green.
