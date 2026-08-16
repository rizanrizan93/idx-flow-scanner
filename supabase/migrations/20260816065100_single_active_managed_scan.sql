-- Prevent concurrent managed scans for the same bundled universe.
-- Streamlit already marks stale RUNNING rows as FAILED before attempting a new run;
-- this database guard closes the remaining race condition between concurrent app sessions.

create unique index if not exists flow_scan_runs_single_active_managed_idx
on public.flow_scan_runs ((config->>'universe_signature'))
where status = 'RUNNING' and config->>'mode' = 'managed';
