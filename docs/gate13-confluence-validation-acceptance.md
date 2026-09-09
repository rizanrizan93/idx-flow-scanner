# Gate 13 — Bounded Confluence Validation Acceptance

Validation contract: `IDX_DRIVER_BOUNDED_CONFLUENCE_WF_V1`  
Parent Gate 12 contract: `IDX_DRIVER_PURGED_EXPANDING_WF_V1`  
Registry: `IDX_DRIVER_REGISTRY_GATE10_V1`

## Scope

Gate 13 evaluates only the 12 Gate 10 preregistered interactions. No brute-force combination search, post-hoc interaction creation, production scoring change, or threshold relaxation is allowed.

After the Gate 11 PIT rollup remediation, five interactions have genuine raw OOS metrics. Seven sector-dependent interactions still fail closed because historical PIT issuer-sector membership is unavailable.

## Final manifest

- registered interactions: 12
- evaluated interactions: 12
- interactions with raw metrics: 5
- metric cells: 120
- validated interactions: 0
- rejected interactions: 0
- insufficient interactions: 12
- panel leakage: 0
- target leakage: 0
- post-hoc mining count: 0
- interaction budget respected: true
- gate state: PASS
- production influence: false

## Interactions with raw metrics

| Interaction | Coverage | Mean OOS alpha | Heldout alpha | Forward alpha | Mean incremental lift | Classification |
|---|---:|---:|---:|---:|---:|---|
| INT_FLOW_FIN_BALANCE | 3.3601% | +4.1437% | +3.7387% | +4.3102% | -0.6820% | INSUFFICIENT_EVIDENCE |
| INT_FLOW_PRICE_VOLUME | 3.5308% | +2.0289% | +1.6507% | +0.2716% | -1.2495% | INSUFFICIENT_EVIDENCE |
| INT_FLOW_TECHNICAL | 3.4774% | +3.3044% | +3.2855% | +1.2839% | -1.6145% | INSUFFICIENT_EVIDENCE |
| INT_FLOW_TECHNICAL_FIN_BALANCE | 0.7623% | +3.6169% | +3.6851% | +2.3269% | -1.8411% | INSUFFICIENT_EVIDENCE |
| INT_TECHNICAL_FIN_BALANCE | 3.4541% | +3.9265% | +3.9830% | +3.8272% | -1.5241% | INSUFFICIENT_EVIDENCE |

Raw positive alpha is not sufficient for validation. Every five-metric interaction remains below its frozen minimum confluence coverage/sample requirement, and mean incremental lift versus its strongest component is negative. No acceptance threshold was changed after observing these results.

## Sector-dependent fail-closed interactions

The following seven interactions have no valid PIT sector component and therefore produce no raw interaction metric:

- `INT_FLOW_SECTOR`
- `INT_FLOW_SECTOR_FIN_BALANCE`
- `INT_FLOW_SECTOR_PRICE_VOLUME`
- `INT_FLOW_SECTOR_TECHNICAL`
- `INT_FLOW_SECTOR_TECHNICAL_FIN_BALANCE`
- `INT_SECTOR_PRICE_VOLUME`
- `INT_SECTOR_TECHNICAL`

Current-sector classification is not substituted for historical membership.

## Security and isolation

All five Gate 13 research tables have RLS enabled. `anon` and `authenticated` have no SELECT privilege; `service_role` has research access. Gate 13 functions are `SECURITY INVOKER` with explicit empty `search_path`. `production_influence_enabled=false` throughout.

## Acceptance

Gate 13 infrastructure and bounded evaluation contract: **PASS**.  
Validated confluence candidates: **0**.  
Phase 2 interaction candidates: **0**.
