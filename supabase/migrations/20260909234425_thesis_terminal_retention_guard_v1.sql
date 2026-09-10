-- BROKEN and EXPIRED are terminal under the frozen V1 thesis contract.  Keep
-- their terminal observation but suppress unbounded identical daily history.
create or replace function public.flow_guard_terminal_thesis_history_v1()
returns trigger
language plpgsql
security invoker
set search_path=''
as $fn$
begin
  if exists(
    select 1
    from public.flow_thesis_signal_v1 t
    where t.thesis_contract=new.thesis_contract
      and t.signal_date=new.signal_date
      and t.ticker=new.ticker
      and t.lifecycle_state in('BROKEN','EXPIRED')
      and t.last_observation_date is not null
      and new.observation_date>t.last_observation_date
  ) then
    return null;
  end if;
  return new;
end
$fn$;

drop trigger if exists flow_guard_terminal_thesis_history_v1
  on public.flow_thesis_lifecycle_history_v1;
create trigger flow_guard_terminal_thesis_history_v1
before insert on public.flow_thesis_lifecycle_history_v1
for each row execute function public.flow_guard_terminal_thesis_history_v1();

revoke all on function public.flow_guard_terminal_thesis_history_v1()
  from public,anon,authenticated,service_role;
