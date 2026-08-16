-- IDX Flow Scanner v0.2.0 OOS integrity/performance hardening.
-- Exact signal-date baseline only; no sliding to a later bar.
-- Set-based refresh scales to the full ~60 trading-day open-outcome working set.

create or replace function public.flow_refresh_signal_outcomes(p_limit integer default 30000)
returns integer
language plpgsql
security invoker
set search_path = public
as $$
declare
    v_updated integer := 0;
begin
    with candidates as materialized (
        select o.run_id, o.ticker, o.as_of_date
        from public.flow_signal_outcomes o
        where o.evaluation_status <> 'COMPLETE'
          and exists (
              select 1
              from public.flow_daily_prices ep
              where ep.ticker = o.ticker
                and ep.trade_date = o.as_of_date
          )
        order by o.as_of_date asc, o.ticker, o.run_id
        limit greatest(coalesce(p_limit, 30000), 0)
    ),
    chosen_daily as materialized (
        select distinct on (c.run_id, c.ticker, p.trade_date)
            c.run_id,
            c.ticker,
            c.as_of_date,
            p.trade_date,
            p.close,
            p.high,
            p.low
        from candidates c
        join public.flow_daily_prices p
          on p.ticker = c.ticker
         and p.trade_date >= c.as_of_date
        order by
            c.run_id,
            c.ticker,
            p.trade_date,
            p.ingested_at desc,
            p.source
    ),
    ranked as materialized (
        select
            d.*,
            row_number() over (
                partition by d.run_id, d.ticker
                order by d.trade_date
            ) as rn,
            max(d.trade_date) over (
                partition by d.run_id, d.ticker
            ) as evaluated_through
        from chosen_daily d
    ),
    agg as materialized (
        select
            run_id,
            ticker,
            max(close) filter (where rn = 1) as entry_close,
            max(close) filter (where rn = 6) as close_5d,
            max(close) filter (where rn = 21) as close_20d,
            max(close) filter (where rn = 61) as close_60d,
            max(high) filter (where rn between 2 and 21) as max_high_20d,
            min(low) filter (where rn between 2 and 21) as min_low_20d,
            max(evaluated_through) as evaluated_through
        from ranked
        group by run_id, ticker
    ),
    updated as (
        update public.flow_signal_outcomes o
        set
            entry_close = a.entry_close,
            return_5d = case
                when a.entry_close > 0 and a.close_5d is not null
                then 100.0 * (a.close_5d / a.entry_close - 1.0)
                else null
            end,
            return_20d = case
                when a.entry_close > 0 and a.close_20d is not null
                then 100.0 * (a.close_20d / a.entry_close - 1.0)
                else null
            end,
            return_60d = case
                when a.entry_close > 0 and a.close_60d is not null
                then 100.0 * (a.close_60d / a.entry_close - 1.0)
                else null
            end,
            mfe_20d = case
                when a.entry_close > 0 and a.max_high_20d is not null
                then 100.0 * (a.max_high_20d / a.entry_close - 1.0)
                else null
            end,
            mae_20d = case
                when a.entry_close > 0 and a.min_low_20d is not null
                then 100.0 * (a.min_low_20d / a.entry_close - 1.0)
                else null
            end,
            evaluated_through = a.evaluated_through,
            evaluation_status = case
                when a.close_60d is not null then 'COMPLETE'
                when a.close_5d is not null or a.close_20d is not null then 'PARTIAL'
                else 'PENDING'
            end,
            evaluated_at = case
                when a.close_5d is not null or a.close_20d is not null or a.close_60d is not null
                then now()
                else null
            end
        from agg a
        where o.run_id = a.run_id
          and o.ticker = a.ticker
          and a.entry_close is not null
          and a.entry_close > 0
        returning 1
    )
    select count(*) into v_updated from updated;

    return v_updated;
end;
$$;

revoke all on function public.flow_refresh_signal_outcomes(integer) from public, anon, authenticated;
grant execute on function public.flow_refresh_signal_outcomes(integer) to service_role;

comment on function public.flow_refresh_signal_outcomes(integer) is
'Exact-date, strictly forward +5D/+20D/+60D and MFE/MAE refresh from persisted raw OHLCV. Missing signal-date baselines are never shifted forward.';
