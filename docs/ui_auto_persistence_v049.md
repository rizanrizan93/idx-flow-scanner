# UI v0.4.9 — Automatic canonical persistence

## Runtime behavior

- Persistence no longer requires manual sidebar confirmation when the canonical IDX Flow Supabase credentials are present.
- Auto-persistence arms only when `SUPABASE_URL` exactly matches project `djqvhbeonmicztxfisav` and a non-empty `SUPABASE_SECRET_KEY` is available.
- Any other project, missing URL, or missing secret fails closed and leaves persistence disabled.
- `Managed auto-run` remains a separate operator choice; this change does not silently enable scheduled/managed scans.
- Scoring formulas, ranking thresholds, Top-900 membership, execution authorization, and Gate-15 lifecycle policy are unchanged.

## UX changes

- Replaced three legacy persistence checkboxes with one compact Auto Persistence status card.
- Refreshed the dark terminal shell with stronger visual hierarchy, glass-style decision cards, modern status chips, and a larger scan CTA.
- Improved segmented navigation, KPI cards, tables, alerts, and mobile spacing.
- Mobile layouts keep the decision funnel and priority board compact while preserving readability.

## Safety

The existing `app.py` canonical Supabase hard lock remains authoritative. UI auto-arming cannot redirect writes to another Supabase project.
