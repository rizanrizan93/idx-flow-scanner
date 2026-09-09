# Gate 12 — Single-Driver Predictive Validation

Validation contract: `IDX_DRIVER_PURGED_EXPANDING_WF_V1`

Registry: `IDX_DRIVER_REGISTRY_GATE10_V1`

Panel: `IDX_DRIVER_WEEKLY_PIT_PANEL_V1`

Gate 12 evaluates only the 37 Gate-10 drivers marked evaluation-eligible. The preregistered 5D/20D/60D horizons are evaluated with two purged expanding walk-forward folds and explicit `TRAIN`, `VALIDATION`, `HELDOUT`, and `FORWARD` segments. Training rows whose target date crosses the train cutoff are purged. Thresholds, directions, driver definitions, and acceptance logic remain frozen from Gate 10.

Canonical Supabase result after completing all eligible drivers:

- registered drivers: 69
- evaluation-eligible drivers: 37
- evaluated drivers: 37
- fold rows: 6
- metric cells: 888
- invalid metric cells: 0
- panel leakage count: 0
- training-target-overlap leaks: 0
- Gate state: `PASS`
- production influence: `false`

`FIN_BALANCE` is the only `PROMISING` single-driver result in this Phase-1 replay: 18 valid OOS cells, 88.89% positive-direction agreement, +1.2723 pp mean OOS alpha spread vs IHSG, +1.7850 pp held-out spread, +1.7582 pp forward spread, three positive horizons, 88.4885% panel coverage, 100% regime consistency, and 80% liquidity consistency. It is **not independent confirmation** because the sample overlaps Gate 9 discovery evidence. Its confirmation state is therefore `DISCOVERY_REPLAY_NOT_INDEPENDENT_CONFIRMATION`, and it is not eligible for production or direct Phase-2 promotion from this result alone.

Notable non-promoted findings include `FLOW_PARTICIPANT_DISTRIBUTION` as `LIQUIDITY_SENSITIVE`; several positive-but-unstable/weak drivers; and multiple rejected or insufficient-evidence drivers. Historical sector membership remains unavailable, so sector stability is fail-closed as `INSUFFICIENT_PIT_SECTOR_HISTORY` rather than substituted with current classifications.

All Gate-12 objects are research/calibration-only, RLS-enabled, service-role-only, use `SECURITY INVOKER` with explicit empty `search_path`, and retain `production_influence_enabled=false`. No production score, rank, action, decision, execution-readiness, or real-money authorization path is modified.
