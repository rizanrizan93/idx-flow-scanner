-- v0.3.22: make stale scan cleanup independent of Streamlit lifecycle.
-- This function is intentionally SECURITY INVOKER and callable only by trusted backend roles.

create or replace function public.flow_reap_stale_scan_runs(p_max_age_minutes integer default 45)
returns integer
language plpgsql
security invoker
set search_path = public, pg_temp
as $$
declare
  v_changed integer := 0;
  v_age integer := greatest(15, least(coalesce(p_max_age_minutes, 45), 120));
begin
  update public.flow_scan_runs
  set status = 'FAILED',
      completed_at = now(),
      current_ticker = null,
      error_count = greatest(coalesce(error_count, 0), 1),
      config = coalesce(config, '{}'::jsonb) || jsonb_build_object(
        'stale_failure_reason', 'SERVER_CRON_STALE_HEARTBEAT',
        'stale_reaped_at', now(),
        'stale_max_age_minutes', v_age
      )
  where status = 'RUNNING'
    and coalesce(heartbeat_at, started_at) < now() - make_interval(mins => v_age);

  get diagnostics v_changed = row_count;
  return v_changed;
end;
$$;

revoke all on function public.flow_reap_stale_scan_runs(integer) from public, anon, authenticated;
grant execute on function public.flow_reap_stale_scan_runs(integer) to service_role, postgres;

do $$
declare
  v_jobid bigint;
begin
  select jobid into v_jobid
  from cron.job
  where jobname = 'flow-stale-run-reaper'
  limit 1;

  if v_jobid is not null then
    perform cron.unschedule(v_jobid);
  end if;
end;
$$;

select cron.schedule(
  'flow-stale-run-reaper',
  '*/10 * * * *',
  $cron$select public.flow_reap_stale_scan_runs(45);$cron$
);
