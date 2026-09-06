do $$
declare d date;
begin
  for d in
    select gs::date
    from generate_series(date '2026-07-20', date '2026-09-04', interval '1 day') gs
    where extract(isodow from gs) between 1 and 5
  loop
    perform public.flow_refresh_official_idx_broker_activity(d);
  end loop;
end $$;
