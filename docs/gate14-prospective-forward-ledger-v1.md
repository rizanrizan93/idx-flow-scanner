# Gate 14 — Prospective Forward Ledger V1

## Purpose
Create genuinely untouched prospective observations for predictive attribution candidates beginning 2026-09-09. No production scoring, ranking, action, authorization, or execution influence is allowed.

## Frozen components
The ledger reconstructs only the existing frozen components required by FIN_BALANCE and the 12 bounded interactions:

- `FLOW_FOREIGN_ACCUMULATION` = `foreign_net_volume_pct`
- `PV_PRICE_VOLUME_CONFIRMATION` = `greatest(return_5d_pct,0) * greatest(volume_residual_z,0)`
- `TECH_TREND_STRUCTURE` = `0.5 * cross-sectional rank(return_20d_pct) + 0.5 * (close >= avg20(close))`
- `MKT_SECTOR_RELATIVE_STRENGTH_20D` = `sector_index_return_20d - IHSG_return_20d`
- `FIN_BALANCE` = Gate-8 PIT financial `balance_score`

All components are cross-sectionally normalized on the signal date. A confluence is active only when every required component is AVAILABLE and has percentile >= 0.80.

## Fail-closed source readiness
A signal date is not captured unless the EOD source state has at least:

- 800 verified stock-summary tickers;
- 800 verified residual/flow tickers;
- 12 verified index codes;
- 800 same-date prospective sector snapshots.

The untouched start date is 2026-09-09. Attempts before that date fail. If EOD sources are not ready, the manifest records `SOURCE_NOT_READY` before any driver/candidate rows are deleted or written.

## Prospective storage
- `flow_attribution_prospective_driver_v1` stores the five component raw values, PIT states and same-date normalized percentiles.
- `flow_attribution_prospective_candidate_v1` stores every registered candidate/ticker as ACTIVE, AVAILABLE_NOT_ACTIVE or COMPONENT_UNAVAILABLE, including base stock and IHSG closes.
- `flow_attribution_forward_outcome_v1` stores mature 5D/20D/60D returns and alpha vs IHSG.
- `flow_attribution_capture_manifest_v1` records source readiness and capture counts.

## Outcome calendar
Forward horizons use the official `COMPOSITE` trading calendar. The target is the 5th, 20th or 60th future IHSG trading session. A ticker outcome is only recorded if an official stock close exists on that exact target date. This avoids silently shifting horizons for suspended/missing ticker sessions.

## Scheduler
Post-close cron jobs run Monday-Friday (pg_cron UTC schedule shown; corresponding WIB times):

- `35 11 * * 1-5` — 18:35 WIB: capture sector/ownership PIT sources and refresh gap registry.
- `40 11 * * 1-5` — 18:40 WIB: capture prospective driver/candidate signals.
- `50 11 * * 1-5` — 18:50 WIB: evaluate newly matured forward outcomes.

These run after the existing official EOD/source refresh jobs.

## First live dry-run
Before 2026-09-09 EOD sources were ready, the manual call returned:

- stock rows: 0
- residual rows: 0
- index codes: 0
- same-date sector snapshots: 962
- status: `SOURCE_NOT_READY`
- production influence: OFF

No intraday/partial signal rows were captured.

## Security and isolation
All four new tables have RLS enabled and no anon/authenticated SELECT. New functions are SECURITY INVOKER with empty `search_path`; anon/authenticated EXECUTE is revoked and service_role is granted execution. All objects hard-code `production_influence_enabled=false`.
