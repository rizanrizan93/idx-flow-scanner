# IDX Flow Scanner — Gates 10–13 Phase 1 Handoff

## Executive summary

Gates 10–13 establish a frozen driver taxonomy, a leakage-safe point-in-time historical panel, purged expanding walk-forward single-driver validation, and bounded preregistered interaction validation. All research artifacts remain shadow-only and have no production score/rank/action/execution influence.

A Gate 11 remediation corrected an implementation-only coverage defect caused by the timeout-safe `reuse_only` refresh: 15 frozen PIT-safe rolling drivers were reconstructed from historical daily evidence without changing their preregistered definitions. After remediation, all 37 evaluation-eligible drivers have non-zero PIT coverage. Historical sector membership remains genuinely unavailable and fails closed.

## Gate 10 — Driver taxonomy

Contract: `IDX_DRIVER_REGISTRY_GATE10_V1`

- 69 registered drivers across 8 families
- 37 evaluation-eligible drivers
- 12 preregistered bounded interactions
- FIN_BALANCE preregistered before evaluation
- explicit AVAILABLE/MISSING/STALE/INVALID/NOT_APPLICABLE/INSUFFICIENT_HISTORY states
- production influence disabled

## Gate 11 — PIT historical driver panel

Contract: `IDX_DRIVER_WEEKLY_PIT_PANEL_V1`

- 56,552 ticker × signal-date rows
- 59 signal dates
- 967 tickers
- 2,092,424 logical driver observations
- 1,883,154 available observations after rolling-feature remediation
- 0 eligible drivers with 0% coverage
- future/leakage count: 0
- target leakage count: 0
- revision leakage count: 0
- normalization: same-signal-date cross-section only
- production influence: false

Historical issuer-sector membership is not available. Current sector classification is retained only as non-predictive metadata and is never backfilled into historical feature state.

## Gate 12 — Single-driver predictive validation

Contract: `IDX_DRIVER_PURGED_EXPANDING_WF_V1`

- 6 purged expanding folds
- TRAIN / VALIDATION / HELDOUT / FORWARD partitions
- horizons: 5D / 20D / 60D
- 37 / 37 evaluation-eligible drivers evaluated
- 888 metric cells
- invalid metric cells: 0
- panel leakage: 0
- training-target overlap leakage: 0
- promising drivers: 1
- Phase 2 eligible drivers: 0

### Strongest result

`FIN_BALANCE` remains the sole `PROMISING` single driver:

- valid OOS cells: 18
- positive cells: 16
- direction agreement: 88.89%
- mean OOS alpha spread: +1.2723%
- mean heldout alpha spread: +1.7850%
- mean forward alpha spread: +1.7582%
- mean rank IC: +0.0159
- coverage: 88.4885%
- regime consistency: 100%
- liquidity consistency: 80%

It is **not independently confirmed** because the Gate 9 discovery sample overlaps this evaluation. Confirmation state remains `DISCOVERY_REPLAY_NOT_INDEPENDENT_CONFIRMATION`; Phase 2 entry remains false pending untouched forward evidence.

### Technical/rolling findings after remediation

The restored PIT history changed several drivers from artificial `INSUFFICIENT_EVIDENCE` to measurable outcomes, without changing the frozen acceptance rules.

Notable results:

- `TECH_BOS_20D`: WEAK; mean OOS spread +2.8049%, but forward spread -2.3406%
- `TECH_TREND_STRUCTURE`: WEAK; mean OOS +0.9661%, forward -1.2497%
- `TECH_PULLBACK_CONTINUATION`: UNSTABLE; mean OOS +1.4000%, heldout +2.4189%, forward -0.0261%
- `TECH_DISPLACEMENT`: REJECTED; mean OOS -0.4233%
- `TECH_CHOCH`: REJECTED; mean OOS -0.9967%
- `TECH_LIQUIDITY_SWEEP_20D`: REJECTED; mean OOS -2.1297%
- `TECH_REVERSAL_ACCUMULATION`: REJECTED; mean OOS -0.9448%
- `TECH_FVG_BULLISH`: UNSTABLE; mean OOS -0.4457%
- `FLOW_ACCELERATION_5V20`: WEAK; mean OOS +0.3624%, forward +0.4209%
- `PV_VOLATILITY_CONTRACTION`: LIQUIDITY_SENSITIVE; mean OOS +0.4838%

These results support keeping the technical layer as contextual/confluence research rather than promoting any single technical driver to production.

## Gate 13 — Interaction / confluence validation

Contract: `IDX_DRIVER_BOUNDED_CONFLUENCE_WF_V1`

- 12 / 12 preregistered interactions evaluated
- 5 interactions with raw metrics after PIT remediation
- 120 metric cells
- 7 sector-dependent interactions fail closed
- validated interactions: 0
- Phase 2 interaction candidates: 0
- panel leakage: 0
- target leakage: 0
- post-hoc mining: 0
- interaction budget respected: true
- production influence: false

Five measurable confluences have positive raw alpha in parts of the sample, but all fail frozen coverage/sample validity and have negative mean incremental lift versus their strongest component. No threshold is relaxed after observing outcomes.

## Regime, liquidity, and sector robustness

- FIN_BALANCE shows the strongest regime and liquidity consistency among current research results.
- Several technical/rolling drivers show sign instability between heldout and forward partitions.
- PV_VOLATILITY_CONTRACTION is explicitly liquidity-sensitive rather than generally robust.
- Historical sector consistency cannot be tested fairly until genuine PIT issuer-sector membership is available.

## Phase 2 candidate state

Single-driver candidates eligible under the current Gate 12 finalizer: **0**.  
Interaction candidates eligible under Gate 13: **0**.

FIN_BALANCE is the only promising research signal, but must collect untouched forward data before independent confirmation.

## Next-phase handoff

1. Collect untouched forward observations for FIN_BALANCE without modifying its frozen definition or acceptance criteria.
2. Acquire or reconstruct genuine dated issuer-sector membership before rerunning sector-dependent interactions; never backfill current sector labels historically.
3. Preserve the restored PIT rolling feature materialization in every Gate 11 refresh.
4. Do not tune thresholds based on Gate 12/13 observed outcomes.
5. Keep all Gate 10–13 research artifacts out of production score/rank/action/execution until a later explicitly approved promotion gate.

## Production invariance

No Gate 10–13 migration writes to production scan-result or action/execution pathways. `production_influence_enabled=false` remains the enforced research contract.
