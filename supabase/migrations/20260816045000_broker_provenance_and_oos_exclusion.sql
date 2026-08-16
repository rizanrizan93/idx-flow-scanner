-- IDX Flow Scanner v0.2.0 evidence/OOS integrity hardening.

alter table public.flow_broker_flows
    add column if not exists source_verified boolean not null default false,
    add column if not exists source_url text,
    add column if not exists provenance_state text;

comment on column public.flow_broker_flows.source_verified is
'Explicit provenance flag. BROKER_DIRECT must fail closed when source provenance is missing/unverified.';
comment on column public.flow_broker_flows.source_url is
'Optional auditable source URL for direct broker-summary evidence.';
comment on column public.flow_broker_flows.provenance_state is
'Optional provenance state such as DIRECT_SOURCE_VERIFIED; never inferred from OHLCV.';

alter table public.flow_signal_outcomes
    add column if not exists evaluation_note text;

alter table public.flow_signal_outcomes
    drop constraint if exists flow_signal_outcomes_evaluation_status_check;
alter table public.flow_signal_outcomes
    add constraint flow_signal_outcomes_evaluation_status_check
    check (evaluation_status in ('PENDING','PARTIAL','COMPLETE','EXCLUDED'));

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
        where o.evaluation_status in ('PENDING','PARTIAL')
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
            p.open,
            p.high,
            p.low,
            p.close
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
    ranked_base as materialized (
        select
            d.*,
            row_number() over (
                partition by d.run_id, d.ticker
                order by d.trade_date
            ) as rn,
            lag(d.close) over (
                partition by d.run_id, d.ticker
                order by d.trade_date
            ) as prev_close,
            max(d.trade_date) over (
                partition by d.run_id, d.ticker
            ) as evaluated_through
        from chosen_daily d
    ),
    ranked as materialized (
        select
            r.*,
            case
                when r.rn between 2 and 61
                 and r.prev_close > 0
                 and r.open > 0
                 and abs(r.open / r.prev_close - 1.0) >= 0.35
                 and abs(r.close / r.open - 1.0) <= 0.25
                 and least(
                    abs((r.open / r.prev_close) - 0.1) / 0.1,
                    abs((r.open / r.prev_close) - 0.2) / 0.2,
                    abs((r.open / r.prev_close) - 0.25) / 0.25,
                    abs((r.open / r.prev_close) - (1.0/3.0)) / (1.0/3.0),
                    abs((r.open / r.prev_close) - 0.5) / 0.5,
                    abs((r.open / r.prev_close) - 2.0) / 2.0,
                    abs((r.open / r.prev_close) - 3.0) / 3.0,
                    abs((r.open / r.prev_close) - 4.0) / 4.0,
                    abs((r.open / r.prev_close) - 5.0) / 5.0,
                    abs((r.open / r.prev_close) - 10.0) / 10.0
                 ) <= 0.06
                then true else false
            end as split_like_forward
        from ranked_base r
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
            bool_or(split_like_forward) as has_forward_split_like,
            max(evaluated_through) as evaluated_through
        from ranked
        group by run_id, ticker
    ),
    updated as (
        update public.flow_signal_outcomes o
        set
            entry_close = a.entry_close,
            return_5d = case
                when a.has_forward_split_like then null
                when a.entry_close > 0 and a.close_5d is not null
                then 100.0 * (a.close_5d / a.entry_close - 1.0)
                else null
            end,
            return_20d = case
                when a.has_forward_split_like then null
                when a.entry_close > 0 and a.close_20d is not null
                then 100.0 * (a.close_20d / a.entry_close - 1.0)
                else null
            end,
            return_60d = case
                when a.has_forward_split_like then null
                when a.entry_close > 0 and a.close_60d is not null
                then 100.0 * (a.close_60d / a.entry_close - 1.0)
                else null
            end,
            mfe_20d = case
                when a.has_forward_split_like then null
                when a.entry_close > 0 and a.max_high_20d is not null
                then 100.0 * (a.max_high_20d / a.entry_close - 1.0)
                else null
            end,
            mae_20d = case
                when a.has_forward_split_like then null
                when a.entry_close > 0 and a.min_low_20d is not null
                then 100.0 * (a.min_low_20d / a.entry_close - 1.0)
                else null
            end,
            evaluated_through = a.evaluated_through,
            evaluation_status = case
                when a.has_forward_split_like then 'EXCLUDED'
                when a.close_60d is not null then 'COMPLETE'
                when a.close_5d is not null or a.close_20d is not null then 'PARTIAL'
                else 'PENDING'
            end,
            evaluation_note = case
                when a.has_forward_split_like then 'CORPORATE_ACTION_LIKE_GAP_IN_FORWARD_WINDOW'
                else null
            end,
            evaluated_at = case
                when a.has_forward_split_like
                  or a.close_5d is not null
                  or a.close_20d is not null
                  or a.close_60d is not null
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
'Exact-date strictly-forward OOS refresh. Outcomes crossing a split/reverse-split-like raw-price discontinuity are EXCLUDED from calibration.';
