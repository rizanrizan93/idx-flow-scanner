# Evidence v5 equity ticker contract

The historical Block IDX financial filing cache is an equity evidence layer.

The source history can contain non-equity IDX instrument identifiers. During the 2023-09-08 through 2026-09-08 backfill, two such identifiers were observed: `R-ABFII` and `R-LQ45X`, totaling 18 structured filing rows. They remain represented in backfill telemetry as explicit exclusions but are not written to the equity filing cache.

The cache ticker contract is `^[A-Z0-9]{4,12}$`, matching the canonical `flow_financial_filing_evidence_v5` ingestion guard. Source-row accounting is enforced as:

`source filing rows = cache filing rows + explicitly excluded non-equity rows`

This exclusion does not change production scoring.
