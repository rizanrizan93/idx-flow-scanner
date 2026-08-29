alter table public.flow_scan_runs
  drop constraint if exists flow_scan_runs_status_check,
  drop constraint if exists flow_scan_runs_completed_requires_results;

alter table public.flow_scan_runs
  add constraint flow_scan_runs_status_check
  check (status in ('RUNNING','COMPLETED','COMPLETED_PARTIAL','FAILED','CANCELLED')),
  add constraint flow_scan_runs_completed_requires_results
  check (status not in ('COMPLETED','COMPLETED_PARTIAL') or processed_count > 0);
