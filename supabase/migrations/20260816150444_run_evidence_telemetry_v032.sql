create or replace function public.flow_populate_run_evidence_telemetry()
returns trigger
language plpgsql
security invoker
set search_path=public
as $$
declare
  v_foreign_tickers integer := 0;
  v_foreign_days integer := 0;
  v_sources jsonb := '{}'::jsonb;
  v_asof date;
begin
  if new.status not in ('COMPLETED','FAILED','CANCELLED') then
    return new;
  end if;

  select
    count(*) filter (where coalesce((diagnostics->>'foreign_evidence_coverage_pct')::numeric,0) > 0),
    max(as_of_date)
  into v_foreign_tickers, v_asof
  from public.flow_scan_results
  where run_id=new.id;

  select coalesce(jsonb_object_agg(source_name, source_count), '{}'::jsonb)
  into v_sources
  from (
    select diagnostics->>'foreign_evidence_source' as source_name, count(*)::int as source_count
    from public.flow_scan_results
    where run_id=new.id
      and coalesce(diagnostics->>'foreign_evidence_source','') <> ''
      and coalesce((diagnostics->>'foreign_evidence_coverage_pct')::numeric,0) > 0
    group by diagnostics->>'foreign_evidence_source'
  ) s;

  if v_asof is not null then
    select count(distinct trade_date)::int
    into v_foreign_days
    from (
      select v.trade_date
      from public.flow_vendor_foreign_flows v
      where v.trade_date between (v_asof - 45) and v_asof
        and exists (select 1 from public.flow_scan_results r where r.run_id=new.id and r.ticker=v.ticker)
      union
      select o.trade_date
      from public.flow_official_stock_flows o
      where o.trade_date between (v_asof - 45) and v_asof
        and exists (select 1 from public.flow_scan_results r where r.run_id=new.id and r.ticker=o.ticker)
    ) d;
  end if;

  update public.flow_scan_runs
  set foreign_evidence_tickers=coalesce(v_foreign_tickers,0),
      foreign_evidence_days=coalesce(v_foreign_days,0),
      foreign_evidence_sources=coalesce(v_sources,'{}'::jsonb)
  where id=new.id;

  return new;
end;
$$;

revoke all on function public.flow_populate_run_evidence_telemetry() from public, anon, authenticated;
grant execute on function public.flow_populate_run_evidence_telemetry() to service_role;

drop trigger if exists flow_scan_runs_evidence_telemetry_trg on public.flow_scan_runs;
create trigger flow_scan_runs_evidence_telemetry_trg
after update of status on public.flow_scan_runs
for each row
when (old.status is distinct from new.status)
execute function public.flow_populate_run_evidence_telemetry();