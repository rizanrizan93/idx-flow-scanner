# Gate 14 — Predictive Attribution Shadow Foundation V1

## Intent
Build the attribution/explainability layer without allowing unconfirmed research evidence to change production score, rank, action, authorization, or execution.

Architecture target:

`Evidence -> Predictive Attribution -> Prediction -> Timing/Risk -> Decision`

This migration implements only the research/shadow foundation.

## Canonical contracts
- Attribution: `IDX_PREDICTIVE_ATTRIBUTION_SHADOW_V1`
- Driver registry: `IDX_DRIVER_REGISTRY_GATE10_V2`
- PIT panel: `IDX_DRIVER_WEEKLY_PIT_PANEL_V2`
- Single-driver OOS: `IDX_DRIVER_PURGED_EXPANDING_WF_V2`
- Interaction OOS: `IDX_DRIVER_BOUNDED_CONFLUENCE_WF_V2`

## Prospective PIT capture
Historical sector membership before 2026-09-09 remains unavailable and is not backfilled from current issuer metadata.

From 2026-09-09 forward, the research database captures:
- issuer sector/subsector snapshots;
- official shareholder-profile aggregates;
- source availability timestamps.

First capture:
- sector snapshots: 962 tickers;
- ownership snapshots: 958 tickers;
- production influence: OFF.

`unreported_float_upper_bound_pct` is explicitly a proxy upper bound derived from disclosed ownership. It is not official free float.

## Existing historical gaps
- Sector: prospective PIT history starts 2026-09-09; earlier historical membership remains unavailable.
- Ownership/free float: prospective PIT history starts 2026-09-09; earlier shareholder history is not available.
- Corporate actions: 144 verified records / 129 tickers from 2025-06-17 through 2026-09-08. Usable as PIT context but too sparse/heterogeneous for general predictive promotion.
- Disclosure v5: 24 verified PIT-eligible rows / 24 tickers from 2026-09-07 through 2026-09-09; too short for predictive validation.

## Forward tracking registry
Untouched signal start date: `2026-09-09`.

- `FIN_BALANCE`: `CONFIRMATION_CANDIDATE`; existing Gate 9/Gate 12 periods remain discovery and cannot count as independent confirmation.
- All 12 bounded interaction families: `FORWARD_TRACK_ONLY` using exactly the frozen component definitions; no brute-force additions and no post-hoc promotion.

Sector-containing interactions may only use sector membership captured point-in-time from the prospective snapshot table.

## Shadow attribution output
For each ticker/date, the layer separates:
- `dominant_observed_evidence`: currently only strong `PROMISING` evidence; it is still unconfirmed unless promotion eligibility is independently achieved;
- `supporting_diagnostic_evidence`: strong WEAK / UNSTABLE / LIQUIDITY_SENSITIVE evidence;
- `contradicting_evidence`: low-percentile evidence in the same research classes;
- verified recent corporate-event context;
- explicit data availability states.

Predictive readiness states:
- `VALIDATED_PREDICTIVE_EVIDENCE_PRESENT`
- `PROMISING_UNCONFIRMED_EVIDENCE_PRESENT`
- `NO_VALIDATED_PREDICTIVE_DRIVER`

No causal language is authorized.

## Initial shadow capture
Latest Phase-1 V2 signal date: 2026-09-08.

- shadow rows: 963 tickers;
- 172 tickers contain strong FIN_BALANCE evidence and are labeled `PROMISING_UNCONFIRMED_EVIDENCE_PRESENT`;
- 791 tickers remain `NO_VALIDATED_PREDICTIVE_DRIVER`;
- there are still zero production-validated drivers and zero production-validated interactions.

## Production isolation
All new tables are research-only with `production_influence_enabled=false`.
Functions are SECURITY INVOKER with empty `search_path`, and table/function access is revoked from public/anon/authenticated and granted only to service_role.

No production runtime source is changed by this foundation.
