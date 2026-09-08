# Financial Evidence v5 — Gate 8 / Gate 9 acceptance

## Scope

Gate 8 integrates Financial Evidence v5 as a **PIT-safe shadow-only** evidence layer. Gate 9 evaluates the preregistered financial factor family with leakage-safe weekly walk-forward / OOS analysis. Neither gate authorizes production influence unless the preregistered promotion candidate passes its frozen acceptance criteria.

## Gate 8 canonical acceptance

Canonical project: `djqvhbeonmicztxfisav`.

Shadow policy contract: `FINANCIAL_EVIDENCE_V5_PIT_SHADOW_GATE8_1`.

Key controls:

- filing availability is point-in-time and publication-time verified;
- a filing published after 16:15 WIB becomes available from the following date;
- missingness is explicit: `AVAILABLE`, `MISSING`, `STALE`, `INVALID`, `INSUFFICIENT_HISTORY`, with feature-level `NOT_APPLICABLE` where semantics do not apply;
- financial-sector semantics do not force industrial gross-margin/current-ratio/cash-flow features;
- production influence is hard-locked `false`;
- no production scoring/ranking/decision module is modified.

Latest captured scan acceptance (`bf20b7e1-cfce-43af-853a-88a4430bbae2`):

- rows: 692
- AVAILABLE: 667
- scored: 665
- insufficient history: 14
- stale: 9
- invalid: 2
- evaluation-only weight: 10%
- Top-20 overlap vs production: 17 / 20
- max absolute evaluation rank shift: 163
- `production_scoring_changed=false`
- `production_influence_enabled=false`

The large possible rank shift is why Gate 8 remains shadow-only pending Gate 9 calibration.

## Gate 9 historical panel

Sample contract: `FINANCIAL_V5_WEEKLY_LAST_TRADING_DAY_PIT_1`.

Canonical panel:

- rows: 56,552
- weekly PIT dates: 59
- tickers: 967
- period: 2025-08-01 through 2026-09-08
- scored rows: 49,986
- coverage: 88.39%
- production influence: OFF

PIT integrity audit:

- current-filing future leaks: 0
- prior-filing future leaks: 0
- bad prior-year / same-period comparable pairs: 0

The filing-feature cache preserves all 12,029 manifest-parsed filings, including 74 filings with zero target facts. Those filings form PIT validity intervals and surface as missing/invalid semantics rather than silently falling back to an older filing.

## Gate 9 preregistration

Calibration contract: `FINANCIAL_V5_PURGED_EXPANDING_WF_1`.

Frozen candidates before OOS evaluation:

- `FIN_QUALITY` — diagnostic only
- `FIN_GROWTH` — diagnostic only
- `FIN_BALANCE` — diagnostic only
- `FIN_CASHFLOW` — diagnostic only
- `FIN_COMPOSITE` — the only promotion-eligible candidate, preregistered at a bounded 5% family weight

Thresholds are frozen at bottom 20 / top 80. Two expanding folds are evaluated for each 5D / 20D / 60D horizon with `PURGE_TRAIN_ROWS_UNLESS_TARGET_DATE_LE_TRAIN_END`.

Canonical result:

- folds: 6
- OOS metric cells: 120
- invalid metric cells: 0
- candidate registry frozen before OOS calculation: true
- promotion-ready factors: 0
- production influence: OFF

### OOS summary

| Factor | Positive OOS checks | Direction agreement | Mean OOS spread | Held-out spread | Forward spread | Positive horizons | Stable | Promotion ready |
|---|---:|---:|---:|---:|---:|---:|---|---|
| FIN_BALANCE | 16 / 18 | 88.89% | +1.2429% | +1.8919% | +1.6862% | 3 / 3 | Yes | No |
| FIN_CASHFLOW | 10 / 18 | 55.56% | +0.1742% | +0.2328% | +2.1892% | 3 / 3 | No | No |
| FIN_COMPOSITE | 9 / 18 | 50.00% | -1.5735% | -3.8718% | +1.8594% | 2 / 3 | No | No |
| FIN_GROWTH | 2 / 18 | 11.11% | -1.5616% | -1.3770% | -1.6999% | 0 / 3 | No | No |
| FIN_QUALITY | 2 / 18 | 11.11% | -1.6485% | -1.6419% | -1.5957% | 0 / 3 | No | No |

`FIN_BALANCE` is diagnostically interesting but was **not preregistered as promotion-eligible**. Promoting it after seeing these results would be post-hoc factor selection. Gate 9 therefore correctly closes with **NO PRODUCTION PROMOTION**.

## Final decision

- Gate 8: PASS — shadow integration accepted.
- Gate 9: PASS — leakage-safe calibration completed.
- Production financial influence: OFF.
- No financial factor is authorized to change production score, rank, action, or real-money authorization from these gates.
