# Gate 11 — PIT Historical Driver Panel

Contract: `IDX_DRIVER_WEEKLY_PIT_PANEL_V1`

The panel reuses the canonical 59-date Financial Evidence v5 weekly sample and canonical daily market-memory features. It stores a ticker/date signal row plus long driver observations with explicit state, raw/transformed/normalized values, evidence/effective timestamps, source and revision identities, staleness, missingness, and provenance.

Market evidence is available only after the 16:15 WIB close cutoff. Financial evidence inherits Gate 8–9 `available_from_date` and zero-fact interval semantics. Normalization is cross-sectional within the same signal date; no full-sample statistic is used. Outcome fields are retained as labels and structurally marked as not used by feature engineering.

Historical issuer-sector membership is unavailable. Sector driver observations and sector-relative targets therefore fail closed; current registry classification is retained only as non-predictive metadata. Ownership/event drivers remain registry-only because their available history/publication timestamps do not support PIT evaluation.

Refresh is transactional, idempotent, deterministic with the Gate 10 freeze timestamp, RLS-protected, service-role-only, and research-only.
