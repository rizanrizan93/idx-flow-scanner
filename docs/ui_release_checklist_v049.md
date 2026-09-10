# UI v0.4.9 release verification

- Canonical Supabase URL must equal `https://djqvhbeonmicztxfisav.supabase.co`.
- Secret key must be present; no secret value is rendered.
- Auto-persistence replaces the three legacy manual persistence checkboxes.
- Wrong/missing canonical credentials fail closed.
- Managed auto-run remains opt-in.
- Production scoring, ranking thresholds, execution authorization, Top-900 selection, and Gate-15 policy remain unchanged.
- Mobile CSS keeps the decision funnel and priority board readable at narrow widths.
- Full repository test suite must pass before merge.
