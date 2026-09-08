# Gate 10 — Driver Taxonomy & Attribution Contract

Contract: `IDX_DRIVER_REGISTRY_GATE10_V1`

This gate freezes the candidate driver universe, formulas, directions, thresholds, 5D/20D/60D horizons, IHSG-first benchmark policy, purged walk-forward rule, single-driver acceptance criteria, twelve interaction families, and the maximum interaction budget before Gate 11–13 outcome evaluation.

The registry reuses canonical `flow_*` evidence. Unsupported ownership, event, price-band, order-block, EMA, and historical-sector candidates fail closed as not evaluation-eligible; no proxy is silently substituted. In particular, `tradable_shares / listed_shares` is not treated as regulatory free float, and current issuer-sector classification is not treated as historical membership.

`FIN_BALANCE` is a preregistered Phase 1 research candidate. Gate 9 is explicitly treated as discovery evidence, not independent confirmation.

All objects are research-only, RLS-enabled, service-role-readable, and inaccessible to `PUBLIC`, `anon`, and `authenticated`. Registry tables are read-only to `service_role` after the migration. No production score, rank, action, decision, or execution object is written.
