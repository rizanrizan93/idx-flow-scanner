# KSEI ownership history

IDX Flow Scanner stores KSEI holding-composition evidence as canonical slow-moving ownership evidence.

- Source: official KSEI holding-composition archives (`BalanceposEfekYYYYMMDD.zip`).
- 2026 backfill: 2026-01-30 through 2026-08-31.
- Latest universe coverage: 700/700 tickers.
- Canonical rows per ticker/date: issued/security reference, scripless total, local scripless total, foreign scripless total.
- Local/foreign percentages use scripless total as denominator.
- KSEI registration composition is **not** a major-holder register and is never summed into `major_holder_pct`.
- KSEI ownership changes are slow-moving ownership evidence and are never relabelled as daily foreign trading flow.
- `TradebleShares` from IDX/ZAPI stock-summary is not treated as regulatory free float.

Generated mirrors:

- `data/cache/ksei_ownership_history_2026.csv.gz`
- `data/cache/ksei_ownership_history_2026.json`

Backfill script: `scripts/backfill_ksei_ownership_history.py`.
