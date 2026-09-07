-- Phase 4C closure cleanup.
-- The lean work table existed only to finish discovery under the bounded statement timeout.
-- No duplicated market-learning panel is retained after PHASE4C_READY.

drop table if exists public.flow_phase4c_work_base_v4;
