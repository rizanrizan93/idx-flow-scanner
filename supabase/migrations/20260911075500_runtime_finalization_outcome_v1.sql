-- Runtime finalization/outcome v1.
--
-- 1. Compute forward outcomes once per (ticker, as_of_date), not once per run.
-- 2. Update only rows whose factual outcome state changed, limiting write amplification.
-- 3. Make stale-run recovery result-aware so fully-attempted scans with persisted
--    >=90% valid rows are finalized as COMPLETED/COMPLETED_PARTIAL rather than
--    being falsified as FAILED with processed_count=0.
-- 4. Preserve production scoring/ranking contracts; this migration only repairs
--    calibration maintenance and run-state observability.

create or replace function public.flow_refresh_signal_outcomes(p_limit integer default 30000)
returns integer
language plpgsql
security invoker
set search_path=''
as $function$
declare
  v_updated integer := 0;
begin
  with candidates as materialized (
    select o.run_id,o.ticker,o.as_of_date
    from public.flow_signal_outcomes o
    where o.evaluation_status in ('PENDING','PARTIAL')
      and exists (
        select 1 from public.flow_daily_prices ep
        where ep.ticker=o.ticker and ep.trade_date=o.as_of_date
      )
    order by o.as_of_date,o.ticker,o.run_id
    limit greatest(coalesce(p_limit,30000),0)
  ), pairs as materialized (
    select distinct ticker,as_of_date from candidates
  ), chosen_daily as materialized (
    select distinct on (c.ticker,c.as_of_date,p.trade_date)
      c.ticker,c.as_of_date,p.trade_date,p.open,p.high,p.low,p.close
    from pairs c
    join public.flow_daily_prices p
      on p.ticker=c.ticker and p.trade_date>=c.as_of_date
    order by c.ticker,c.as_of_date,p.trade_date,p.ingested_at desc,p.source
  ), ranked_base as materialized (
    select d.*,
      row_number() over(partition by d.ticker,d.as_of_date order by d.trade_date) rn,
      lag(d.close) over(partition by d.ticker,d.as_of_date order by d.trade_date) prev_close,
      max(d.trade_date) over(partition by d.ticker,d.as_of_date) evaluated_through
    from chosen_daily d
  ), ranked as materialized (
    select r.*,
      case when r.rn between 2 and 61
        and r.prev_close>0 and r.open>0
        and abs(r.open/r.prev_close-1.0)>=0.35
        and abs(r.close/r.open-1.0)<=0.25
        and least(
          abs((r.open/r.prev_close)-0.1)/0.1,
          abs((r.open/r.prev_close)-0.2)/0.2,
          abs((r.open/r.prev_close)-0.25)/0.25,
          abs((r.open/r.prev_close)-(1.0/3.0))/(1.0/3.0),
          abs((r.open/r.prev_close)-0.5)/0.5,
          abs((r.open/r.prev_close)-2.0)/2.0,
          abs((r.open/r.prev_close)-3.0)/3.0,
          abs((r.open/r.prev_close)-4.0)/4.0,
          abs((r.open/r.prev_close)-5.0)/5.0,
          abs((r.open/r.prev_close)-10.0)/10.0
        )<=0.06 then true else false end split_like_forward
    from ranked_base r
  ), agg as materialized (
    select ticker,as_of_date,
      max(close) filter(where rn=1) entry_close,
      max(close) filter(where rn=6) close_5d,
      max(close) filter(where rn=21) close_20d,
      max(close) filter(where rn=61) close_60d,
      max(high) filter(where rn between 2 and 21) max_high_20d,
      min(low) filter(where rn between 2 and 21) min_low_20d,
      bool_or(split_like_forward) has_forward_split_like,
      max(evaluated_through) evaluated_through
    from ranked group by ticker,as_of_date
  ), resolved as materialized (
    select a.ticker,a.as_of_date,a.entry_close,a.evaluated_through,
      case when a.has_forward_split_like then null
        when a.entry_close>0 and a.close_5d is not null
        then 100.0*(a.close_5d/a.entry_close-1.0) end return_5d,
      case when a.has_forward_split_like then null
        when a.entry_close>0 and a.close_20d is not null
        then 100.0*(a.close_20d/a.entry_close-1.0) end return_20d,
      case when a.has_forward_split_like then null
        when a.entry_close>0 and a.close_60d is not null
        then 100.0*(a.close_60d/a.entry_close-1.0) end return_60d,
      case when a.has_forward_split_like then null
        when a.entry_close>0 and a.max_high_20d is not null
        then 100.0*(a.max_high_20d/a.entry_close-1.0) end mfe_20d,
      case when a.has_forward_split_like then null
        when a.entry_close>0 and a.min_low_20d is not null
        then 100.0*(a.min_low_20d/a.entry_close-1.0) end mae_20d,
      case when a.has_forward_split_like then 'EXCLUDED'
        when a.close_60d is not null then 'COMPLETE'
        when a.close_5d is not null or a.close_20d is not null then 'PARTIAL'
        else 'PENDING' end evaluation_status,
      case when a.has_forward_split_like
        then 'CORPORATE_ACTION_LIKE_GAP_IN_FORWARD_WINDOW' end evaluation_note
    from agg a
  ), updated as (
    update public.flow_signal_outcomes o set
      entry_close=r.entry_close,
      return_5d=r.return_5d,
      return_20d=r.return_20d,
      return_60d=r.return_60d,
      mfe_20d=r.mfe_20d,
      mae_20d=r.mae_20d,
      evaluated_through=r.evaluated_through,
      evaluation_status=r.evaluation_status,
      evaluation_note=r.evaluation_note,
      evaluated_at=case when r.evaluation_status<>'PENDING' then now() else null end
    from candidates c
    join resolved r on r.ticker=c.ticker and r.as_of_date=c.as_of_date
    where o.run_id=c.run_id and o.ticker=c.ticker and o.as_of_date=c.as_of_date
      and r.entry_close is not null and r.entry_close>0
      and (o.entry_close,o.return_5d,o.return_20d,o.return_60d,o.mfe_20d,o.mae_20d,
           o.evaluated_through,o.evaluation_status,o.evaluation_note)
          is distinct from
          (r.entry_close,r.return_5d,r.return_20d,r.return_60d,r.mfe_20d,r.mae_20d,
           r.evaluated_through,r.evaluation_status,r.evaluation_note)
    returning 1
  )
  select count(*)::int into v_updated from updated;
  return v_updated;
end
$function$;

create or replace function public.flow_reap_stale_scan_runs(p_max_age_minutes integer default 45)
returns integer
language plpgsql
security invoker
set search_path=''
as $function$
declare
  v_changed integer:=0;
  v_age integer:=greatest(10,least(coalesce(p_max_age_minutes,45),120));
  v_result_rows integer;
  v_required_rows integer;
  v_terminal_status text;
  r record;
begin
  for r in
    select s.id,s.universe_count,s.attempted_count,s.error_count,s.config
    from public.flow_scan_runs s
    where s.status='RUNNING'
      and coalesce(s.heartbeat_at,s.started_at)<now()-make_interval(mins=>v_age)
    order by coalesce(s.heartbeat_at,s.started_at)
    for update skip locked
  loop
    select count(*)::int into v_result_rows
    from public.flow_scan_results x where x.run_id=r.id;
    v_required_rows:=ceil(0.90*greatest(coalesce(r.universe_count,0),0))::int;

    if coalesce(r.universe_count,0)>0
      and coalesce(r.attempted_count,0)>=r.universe_count
      and v_result_rows>=v_required_rows then
      v_terminal_status:=case when v_result_rows>=r.universe_count
        then 'COMPLETED' else 'COMPLETED_PARTIAL' end;
      update public.flow_scan_runs s set
        status=v_terminal_status,
        processed_count=v_result_rows,
        error_count=greatest(coalesce(s.error_count,0),greatest(s.universe_count-v_result_rows,0)),
        completed_at=now(),current_ticker=null,
        config=coalesce(s.config,'{}'::jsonb)||jsonb_build_object(
          'stale_recovery_reason','PERSISTED_RESULTS_PROVE_SCAN_COMPLETION',
          'stale_recovered_at',now(),'stale_max_age_minutes',v_age,
          'stale_recovered_result_rows',v_result_rows,
          'stale_recovered_status',v_terminal_status)
      where s.id=r.id;
    else
      update public.flow_scan_runs s set
        status='FAILED',completed_at=now(),current_ticker=null,
        error_count=greatest(coalesce(s.error_count,0),1),
        config=coalesce(s.config,'{}'::jsonb)||jsonb_build_object(
          'stale_failure_reason','SERVER_CRON_STALE_HEARTBEAT',
          'stale_reaped_at',now(),'stale_max_age_minutes',v_age,
          'stale_observed_result_rows',v_result_rows)
      where s.id=r.id;
    end if;
    v_changed:=v_changed+1;
  end loop;
  return v_changed;
end
$function$;

-- Reconcile only rows with explicit historical server-stale provenance.  This does
-- not rewrite arbitrary FAILED scans.
with recoverable as (
  select r.id,r.universe_count,count(s.ticker)::int result_rows
  from public.flow_scan_runs r
  join public.flow_scan_results s on s.run_id=r.id
  where r.status='FAILED'
    and r.config->>'stale_failure_reason'='SERVER_CRON_STALE_HEARTBEAT'
    and coalesce(r.attempted_count,0)>=r.universe_count
  group by r.id,r.universe_count
  having count(s.ticker)>=ceil(0.90*max(r.universe_count))
)
update public.flow_scan_runs r set
  status=case when x.result_rows>=r.universe_count then 'COMPLETED' else 'COMPLETED_PARTIAL' end,
  processed_count=x.result_rows,
  error_count=greatest(coalesce(r.error_count,0),greatest(r.universe_count-x.result_rows,0)),
  config=coalesce(r.config,'{}'::jsonb)||jsonb_build_object(
    'stale_failure_reconciled',true,
    'stale_failure_reconciled_at',now(),
    'stale_reconciled_result_rows',x.result_rows)
from recoverable x where r.id=x.id;
