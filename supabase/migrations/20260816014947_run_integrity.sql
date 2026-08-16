-- Run-state integrity hardening.
-- Historical zero-result COMPLETED rows are corrected before the constraint is added.

update public.flow_scan_runs
set status = 'FAILED',
    completed_at = coalesce(completed_at, now()),
    current_ticker = null,
    heartbeat_at = coalesce(heartbeat_at, now())
where status = 'COMPLETED'
  and processed_count = 0;

-- Old pre-managed RUNNING rows from v0.1.2 cannot make progress after the
-- deployment that superseded them. Close only that obsolete version.
update public.flow_scan_runs
set status = 'FAILED',
    completed_at = coalesce(completed_at, now()),
    current_ticker = null,
    heartbeat_at = coalesce(heartbeat_at, now())
where status = 'RUNNING'
  and coalesce(config->>'version', '') = '0.1.2';

alter table public.flow_scan_runs
  add constraint flow_scan_runs_completed_requires_results
  check (status <> 'COMPLETED' or processed_count > 0);
