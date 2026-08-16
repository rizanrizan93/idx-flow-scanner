-- IDX Flow Scanner runtime/OOS hardening
-- Calculate walk-forward outcomes entirely inside PostgreSQL to avoid hundreds
-- of PostgREST round trips from Streamlit.

create or replace function public.flow_refresh_signal_outcomes(p_limit integer default 2000)
returns integer
language plpgsql
security invoker
set search_path = public
as $$
declare
    rec record;
    v_entry numeric;
    v_c5 numeric;
    v_c20 numeric;
    v_c60 numeric;
    v_h20 numeric;
    v_l20 numeric;
    v_through date;
    v_updated integer := 0;
begin
    for rec in
        select run_id, ticker, as_of_date
        from public.flow_signal_outcomes
        where evaluation_status <> 'COMPLETE'
        order by as_of_date asc, ticker
        limit greatest(coalesce(p_limit, 2000), 0)
    loop
        with daily as (
            select distinct on (trade_date)
                trade_date, close, high, low
            from public.flow_daily_prices
            where ticker = rec.ticker
              and trade_date >= rec.as_of_date
            order by trade_date, ingested_at desc, source
        )
        select close into v_entry
        from daily
        order by trade_date
        limit 1;

        if v_entry is null or v_entry <= 0 then
            continue;
        end if;

        with daily as (
            select distinct on (trade_date)
                trade_date, close
            from public.flow_daily_prices
            where ticker = rec.ticker
              and trade_date >= rec.as_of_date
            order by trade_date, ingested_at desc, source
        )
        select close into v_c5
        from daily
        order by trade_date
        offset 5 limit 1;

        with daily as (
            select distinct on (trade_date)
                trade_date, close
            from public.flow_daily_prices
            where ticker = rec.ticker
              and trade_date >= rec.as_of_date
            order by trade_date, ingested_at desc, source
        )
        select close into v_c20
        from daily
        order by trade_date
        offset 20 limit 1;

        with daily as (
            select distinct on (trade_date)
                trade_date, close
            from public.flow_daily_prices
            where ticker = rec.ticker
              and trade_date >= rec.as_of_date
            order by trade_date, ingested_at desc, source
        )
        select close into v_c60
        from daily
        order by trade_date
        offset 60 limit 1;

        with daily as (
            select distinct on (trade_date)
                trade_date, high, low
            from public.flow_daily_prices
            where ticker = rec.ticker
              and trade_date > rec.as_of_date
            order by trade_date, ingested_at desc, source
        ), next20 as (
            select * from daily order by trade_date limit 20
        )
        select max(high), min(low) into v_h20, v_l20 from next20;

        select max(trade_date) into v_through
        from public.flow_daily_prices
        where ticker = rec.ticker;

        update public.flow_signal_outcomes
        set entry_close = v_entry,
            return_5d = case when v_c5 is not null then 100.0 * (v_c5 / v_entry - 1.0) else null end,
            return_20d = case when v_c20 is not null then 100.0 * (v_c20 / v_entry - 1.0) else null end,
            return_60d = case when v_c60 is not null then 100.0 * (v_c60 / v_entry - 1.0) else null end,
            mfe_20d = case when v_h20 is not null then 100.0 * (v_h20 / v_entry - 1.0) else null end,
            mae_20d = case when v_l20 is not null then 100.0 * (v_l20 / v_entry - 1.0) else null end,
            evaluated_through = v_through,
            evaluation_status = case
                when v_c60 is not null then 'COMPLETE'
                when v_c5 is not null or v_c20 is not null then 'PARTIAL'
                else 'PENDING'
            end,
            evaluated_at = now()
        where run_id = rec.run_id and ticker = rec.ticker;

        v_updated := v_updated + 1;
    end loop;

    return v_updated;
end;
$$;

revoke all on function public.flow_refresh_signal_outcomes(integer) from public, anon, authenticated;
grant execute on function public.flow_refresh_signal_outcomes(integer) to service_role;

comment on function public.flow_refresh_signal_outcomes(integer) is
'Updates strictly forward +5D/+20D/+60D and MFE/MAE outcomes from persisted OHLCV. Never used to generate the originating signal.';
