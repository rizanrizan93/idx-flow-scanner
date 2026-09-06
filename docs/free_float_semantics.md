# Free-float evidence semantics

IDX Flow Scanner must not infer regulatory IDX free float from ZAPI/IDX `TradebleShares`.

Until a rule-complete verified regulatory free-float source is available:

- `free_float_pct = None`
- `free_float_structure_score = 50` (neutral)
- free-float is not a core-readiness requirement
- `TradebleShares` and `ListedShares` remain raw diagnostics only
- `PUBLIC_SHARE_PROXY` evidence remains separate and must not be promoted to exact free float

This prevents missing or semantically incompatible source fields from invalidating otherwise valid setups or creating false confidence.
