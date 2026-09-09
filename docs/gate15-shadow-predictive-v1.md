# Gate 15 Shadow Predictive Model V1

SHADOW_PREDICTIVE_SCORE_V1 is a research-only comparison layer. It consumes the
same-date structured attribution snapshot and Top-900 snapshot. It never writes
production score, rank, action, authorization, execution readiness, or capital
allocation.

## Frozen score contract

The score uses the five frozen prospective components. Component weights are
50% FIN_BALANCE, 20% FLOW_FOREIGN_ACCUMULATION, 15% TECH_TREND_STRUCTURE,
10% PV_PRICE_VOLUME_CONFIRMATION, and 5% MKT_SECTOR_RELATIVE_STRENGTH_20D.
Reliability multipliers are 1.0 only for independently validated evidence, 0.5
for promising but unconfirmed evidence, and zero for weak, unstable,
unvalidated, or missing evidence. Missing reliable weight produces NULL, not a
neutral score. Coverage and current tradeability are explicit multipliers.

The exactly 12 Gate-13 interactions remain frozen and have zero score weight.
They are displayed and tracked prospectively until an independently confirmed
promotion assessment passes.

## Preregistered promotion boundary

GATE15_PROMOTION_POLICY_V1 contains FIN_BALANCE plus the exact 12 frozen
interactions. It is hard-locked to zero matured prospective outcomes at freeze.
Every candidate must pass minimum sample size, 20 independent signal dates,
coverage, mean and median alpha, directional consistency, three positive
horizons, discovery heldout/forward behavior, rank IC where applicable, regime
and liquidity consistency, excursion limits, and interaction incremental lift.
Missing robustness fails closed.

Even a passing assessment authorizes only a separately reviewed limited
promotion experiment, with a maximum initial production weight of 5% and
explicit rollback thresholds. It does not change production automatically.

## Evaluation

The outcome cycle uses the official COMPOSITE session calendar for 5D, 20D, and
60D horizons. It stores alpha, hit rate, MFE, MAE, Top-10/Top-20 overlap, rank
displacement, liquidity, sector concentration, turnover, false positives,
false-negative candidates, timing quality, and thesis failure rate. The first
available ranking date has NULL turnover because no prior shadow portfolio
exists.
