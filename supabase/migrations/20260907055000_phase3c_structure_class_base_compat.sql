-- Phase 3C runtime hotfix.
-- The base builder predates structure_class and inserts coalition rows before the
-- reliability finalizer runs. Keep structure_class nullable during the base build;
-- the finalizer fills it in the same wrapper transaction and the quality gate requires
-- zero missing/mismatched structure classes.

alter table public.flow_broker_coalitions_v3
  alter column structure_class drop not null;
