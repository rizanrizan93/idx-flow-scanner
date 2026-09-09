# Top 900 Universe V1

TOP_900_UNIVERSE_V1 is a prospective, current-membership research contract beginning
2026-09-09. It does not claim that today's Top 900 was the historical Top 900.

## Existing-universe audit

The operational application currently overrides its legacy default with the
bundled `data/universe/idx_700_all.csv`. That current-only file contains the
legacy 400 names plus 300 active additions. Its builder prefers official IDX
company profiles, then configured ZAPI company identities, then the
StockAnalysis active list; additions are ranked from available current
trade-value, frequency, volume, and market-rank evidence. The weekly refresh
and OHLCV cache seed workflows are also scoped to 700.

The old bundle does not reconstruct point-in-time historical membership and
does not retain inactive identities for historical research. Its exact 700
tickers are therefore frozen only as an overlap baseline, never presented as a
historical universe.

TOP_900_UNIVERSE_V1 began database-native and shadow-only. On 2026-09-09 the
separate `IDX_OPERATIONAL_TOP900_V1` contract switched Streamlit membership to
the latest fully captured 900-row snapshot. This changes universe routing only:
Gate-14 attribution and Gate-15 predictive scoring remain shadow with zero
production influence. Current-tradeability is an OHLCV/activity proxy because
a reliable PIT FCA/special-monitoring status feed is not presently available;
this limitation remains explicit.

## Selection

Candidates come from active official issuer identities. Invalid identities and
unusable price histories fail closed. Research eligibility requires at least 20
verified closes in the trailing 60 official source sessions. The deterministic
ranking freezes these PIT-safe inputs:

- 50%: percentile rank of log 60-session ADTV;
- 20%: percentile rank of traded sessions in 60;
- 10%: valid-close coverage in 60;
- 10%: verified-source coverage in 60;
- 10%: percentile rank of traded sessions in 252.

Ties use latest traded date descending and ticker ascending. No future return,
outcome, alpha, or current winner information enters selection.

## Three eligibility states

- research_universe_eligible preserves usable research identities, including
  suspended or illiquid names, to reduce survivorship bias.
- current_tradeable requires a selected member, a positive latest close, and
  at least five traded sessions in the latest 60.
- production_actionable is stricter: at least 50 valid closes, 20 traded
  sessions, 90% verified-source coverage, and source currency to official EOD.

Missing or untradeable evidence is never neutral-filled.

The 2026-09-09 canonical-source dry run found 962 eligible official identities,
selected 900, classified 873 as currently tradeable and 27 as research-only,
and overlapped 689 of the prior 700. These values are verification targets, not
hard-coded selection results; the canonical capture recomputes and digests the
snapshot deterministically.

## Versioning and security

All raw eligible identities are retained in the dated snapshot, including the
names below the Top-900 rank boundary. The exact prior 700-member bundle is
stored as a frozen overlap baseline. All new objects are service-role-only,
RLS-enabled, SECURITY INVOKER, empty-search-path, and hard-locked to
production_influence_enabled=false.

## Operational routing

The service-only runtime RPC returns exactly ranks 1 through 900 from the latest
manifest whose state is `CAPTURED` and whose selected count is exactly 900. A
partial response fails closed to an exact repository snapshot of the same dated
contract; it never falls back silently to 700.

The scanner attempts all 900 members and assigns `scanner_rank` across every
valid scored row. The canonical official-price RPC is queried in bounded
30-ticker batches with at most 120 observations per ticker. As of activation,
900/900 have official price history and 894/900 meet the unchanged 80-bar scan
minimum. The six shorter histories remain `INSUFFICIENT_HISTORY` until they
mature; they are not neutral-filled. Members with
`production_actionable=false` can remain visible in research ranking, but the
runtime forces `production_authorized=false` and `action=RESEARCH_ONLY`.
