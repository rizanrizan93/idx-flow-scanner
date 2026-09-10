# IDX Flow Scanner — Final Production Readiness Closure

Date: 2026-09-10

## Executive status

**Engineering closure: PASS.**

The canonical IDX Flow Scanner runtime is operational on the Top-900 universe, storage is below the configured Free-plan database quota, prospective/shadow orchestration is scheduled and fail-closed, and strategy lifecycle automation remains non-influential until genuine forward evidence matures.

This closure does **not** claim predictive validation that does not yet exist. The 5D/20D/60D forward horizons are trading-session horizons and the prospective cohort began on 2026-09-09. Accordingly, all 13 candidates correctly remain `EVIDENCE_ACCUMULATING` with zero production weight and zero production influence.

## Canonical identity

- Repository: `rizanrizan93/idx-flow-scanner`
- Default branch: `main`
- Canonical Supabase: `djqvhbeonmicztxfisav`
- Main baseline at closure start of this report: `81771616e079001aa2677891da36508d4401aff5`
- Latest canonical migration: `20260910062251_scan_results_run_archive_v1`

## Storage closure

Canonical storage observability originally measured:

- database bytes: **1,391,987,859**
- storage state: **CRITICAL**
- configured quota: **524,288,000 bytes**
- quota ratio: **2.6550**

Final verified snapshot after lossless remediation and physical bloat reclamation:

- database bytes: **521,047,187**
- configured quota: **524,288,000 bytes**
- under quota: **true**
- headroom: **3,240,813 bytes**
- latest policy state: **WARNING**, because policy intentionally warns from ratio 0.80 and becomes CRITICAL at 1.00
- observed quota ratio: **0.9937**

Total reduction from the original measured baseline is **870,940,672 bytes (~62.57%)**.

Major remediation included:

1. Vendor foreign-flow canonical compatibility-view compaction while preserving logical row parity and transport provenance.
2. Stock residual panel compatibility-view compaction while preserving all PIT-derived metrics.
3. Official stock-summary session metadata normalization while preserving all market-data fields and logical digest.
4. Lossless whole-run archive for superseded `flow_scan_results` snapshots.
5. `VACUUM FULL ANALYZE` reclamation for `flow_financial_filing_evidence_v5`, `flow_daily_prices`, and a high-bloat official risk-event relation; these maintenance operations did not change schemas or logical contents.

`flow_daily_prices` remains a physical upsert-compatible table with **180,860 rows**, its canonical primary key `(ticker, trade_date, source)`, its ticker/date index, RLS enabled, service-role-only ACL, and zero dead tuples after the final rewrite.

### Scan-result archive integrity

`flow_scan_results` before compaction contained 17,680 rows across 41 runs. Final layout:

- hot rows: **4,654**
- hot runs: **8**
- archived rows: **13,026**
- archived runs: **33**
- bad archive payload/hash checks: **0**
- rows lacking a newer hot `(ticker, as_of_date)` successor: **0**
- sample archived run expected/read-back rows: **398 / 398**
- adaptive-broker trigger preserved: **yes**
- production influence introduced: **no**

Archived runs are readable through `flow_read_scan_results_run_v1(uuid)` without rehydration side effects.

## Top-900 operational E2E

Live canonical RPC verification after all storage remediation:

- selected: **900**
- unique tickers: **900**
- rank range: **1–900**
- current tradeable: **873**
- production actionable: **834**
- price payloads returned: **900**
- history ready (`>=80` bars): **894**
- insufficient history: **6**

Fail-closed insufficient-history tickers and current bar counts:

- `BACH`: 44
- `EMMI`: 44
- `JECX`: 45
- `JELI`: 45
- `PRDL`: 43
- `RANS`: 42

These counts reproduce the pre-remediation Top-900 E2E result. Storage remediation therefore did not change operational universe membership or history-readiness semantics.

## Prospective 5D / 20D / 60D reliability pipeline

Latest canonical stage states:

| Stage | Session | State | Selected/Attempted | Output | Production influence |
|---|---|---|---:|---:|---|
| SIGNAL | 2026-09-09 | ALREADY_CAPTURED | 900 / 900 | 11,700 | false |
| STRUCTURED | 2026-09-09 | CAPTURED | 900 / 900 | 900 | false |
| THESIS | 2026-09-09 | COMPLETED | 900 / 900 | 264 | false |
| SHADOW | 2026-09-09 | CAPTURED | 900 / 900 | 900 | false |
| OUTCOMES | 2026-09-10 | COMPLETED | n/a | 0 | false |

`OUTCOMES=0` is expected at this date because no prospective 5D/20D/60D trading-session horizon has matured yet.

Latest-stage unresolved `FAILED` / `FAILED_CLOSED` count: **0**.

Core scheduled jobs are active for PIT capture, forward signals, structured attribution, thesis, shadow score, forward outcomes, Gate-15 lifecycle retry, and storage observability. Retry jobs for the prospective stages are also active.

## Gate-15 and automated strategy lifecycle

Canonical lifecycle v3 contains **13 candidates**.

- `EVIDENCE_ACCUMULATING`: **13 / 13**
- integrity `PASS`: **13 / 13**
- non-zero production weight: **0**
- `production_influence_enabled=true`: **0**
- maximum permitted limited-production weight: **0.10**

Gate-15 assessment v2:

- assessments: **13**
- `INSUFFICIENT_EVIDENCE`: **13**
- maximum independent matured signal dates: **0**
- maximum minimum-sample count across horizons: **0**
- production influence enabled: **0**

This is the required fail-closed state. No threshold was relaxed and no strategy was promoted merely to satisfy an engineering deadline.

## Security and performance review

Post-DDL Supabase security advisor returned only informational `RLS enabled, no policy` findings. The affected canonical tables are intentionally service-role-only: RLS is enabled and `anon` / `authenticated` table privileges are not granted.

Performance advisor returned informational findings for unindexed foreign keys and currently-unused indexes. These are not closure blockers. Additional indexes were deliberately not added during this storage closure because the database is operating near a strict Free-plan quota and several relations/indexes were freshly rebuilt, making immediate `idx_scan=0` observations insufficient evidence for deletion or addition decisions.

## Acceptance decision

| Workstream | Result |
|---|---|
| Top-900 deterministic operational universe | PASS |
| Top-900 bounded official price runtime | PASS |
| `<80 bars => INSUFFICIENT_HISTORY` fail-closed policy | PASS |
| Production scoring semantics unchanged | PASS |
| Storage below 500 MiB configured quota | PASS |
| Lossless evidence/archive integrity | PASS |
| Prospective scheduler + retries | PASS |
| Latest prospective stages free of unresolved failure | PASS |
| Automated lifecycle state machine | PASS |
| Experimental production influence remains OFF | PASS |
| Genuine 5D/20D/60D predictive maturity | PENDING BY TIME, NOT AN ENGINEERING FAILURE |

## Final operating policy

The scanner may operate using its existing production scoring path. Prospective candidates remain shadow/evidence-accumulating until actual forward trading sessions mature and the preregistered Gate-15 policy is satisfied. The lifecycle automation may transition candidates only according to the versioned policy; it must not relax thresholds, change methodology, mine new drivers automatically, or enable influence because of elapsed wall-clock time alone.

Storage observability remains scheduled. Because the final database is below quota but still in the policy WARNING band, any future growth should be handled through the existing retention/observability architecture and evidence-preserving compaction, not by deleting canonical PIT evidence or weakening research reproducibility.

**Final engineering disposition: READY FOR OPERATION WITH SHADOW VALIDATION CONTINUING AUTOMATICALLY; NO EXPERIMENTAL PRODUCTION PROMOTION AUTHORIZED YET.**
