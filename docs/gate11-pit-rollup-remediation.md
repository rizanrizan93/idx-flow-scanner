# Gate 11 PIT Rollup Remediation

Contract remains `IDX_DRIVER_WEEKLY_PIT_PANEL_V1`; registry remains `IDX_DRIVER_REGISTRY_GATE10_V1`.

## Defect

The timeout-safe `reuse_only` Gate 11 refresh intentionally emitted rolling features as `NULL`. This was conservative, but it incorrectly left 15 evaluation-eligible, already-frozen PIT-safe drivers at 0% coverage even though their source history existed.

This remediation does **not** change driver definitions, direction hypotheses, thresholds, horizons, interaction registry, or production scoring. It reconstructs the original frozen formulas from verified daily evidence using trailing windows ending at the signal date.

## Restored drivers

- Flow: `FLOW_PERSISTENCE_20D`, `FLOW_ACCELERATION_5V20`
- Liquidity: `LIQ_ADTV20`
- Market: `MKT_BREADTH_20D`, `MKT_RISK_ON_CONTEXT`
- Price/volume: `PV_VOLUME_EXPANSION`, `PV_VOLATILITY_EXPANSION`, `PV_VOLATILITY_CONTRACTION`
- Technical: `TECH_BOS_20D`, `TECH_CHOCH`, `TECH_DISPLACEMENT`, `TECH_FVG_BULLISH`, `TECH_LIQUIDITY_SWEEP_20D`, `TECH_REVERSAL_ACCUMULATION`, `TECH_TREND_STRUCTURE`

`TECH_PULLBACK_CONTINUATION` was already materialized and was rerun in Gate 12 after the corrected history count.

## PIT controls

The remediation uses only verified `flow_market_learning_panel_v4`, `flow_official_stock_summary`, and verified COMPOSITE index history. Rolling windows use preceding/current rows only; BOS/sweep/CHOCH use strictly prior highs/lows; FVG uses `lag`; trend normalization is cross-sectional inside the same signal date. No future row, forward-return label, or global full-sample normalization is used.

Historical sector membership is **not** synthesized. Sector-dependent evidence remains fail-closed.

## Live evidence after remediation

- signal rows: 56,552
- logical observations: 2,092,424
- available observations: 1,883,154
- Gate 11 leakage count: 0
- target leakage count: 0
- revision leakage count: 0
- evaluation-eligible drivers with 0% coverage: **0 / 37**
- production influence: false

Selected restored coverage:

| Driver | Coverage |
|---|---:|
| TECH_FVG_BULLISH | 98.3024% |
| TECH_TREND_STRUCTURE | 93.1585% |
| TECH_BOS_20D | 91.4663% |
| TECH_CHOCH | 91.4663% |
| TECH_LIQUIDITY_SWEEP_20D | 91.4663% |
| TECH_REVERSAL_ACCUMULATION | 91.2912% |
| TECH_DISPLACEMENT | 83.6752% |
| FLOW_PERSISTENCE_20D | 93.1585% |
| LIQ_ADTV20 | 93.1585% |

The remaining unavailable sector interactions are a genuine historical-sector-membership limitation, not the prior rolling-feature materialization defect.
