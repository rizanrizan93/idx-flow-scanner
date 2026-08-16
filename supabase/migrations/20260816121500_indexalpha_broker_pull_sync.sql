create extension if not exists pg_cron;

create or replace function public.flow_sync_indexalpha_broker_cache()
returns integer
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
    v_status integer;
    v_content text;
    v_payload jsonb;
    v_upserted integer := 0;
begin
    select (r).status, (r).content
      into v_status, v_content
    from (
        select extensions.http_get(
            'https://raw.githubusercontent.com/rizanrizan93/idx-flow-scanner/refs/heads/main/data/cache/indexalpha_broker_60d.json'
        ) as r
    ) s;

    if v_status <> 200 then
        raise exception 'Index Alpha broker cache HTTP status %', v_status;
    end if;

    begin
        v_payload := v_content::jsonb;
    exception when others then
        raise exception 'Index Alpha broker cache is not valid JSON';
    end;

    if jsonb_typeof(v_payload) <> 'array' then
        raise exception 'Index Alpha broker cache root must be a JSON array';
    end if;

    with raw_rows as (
        select x
        from jsonb_array_elements(v_payload) as x
    ), normalized as (
        select
            upper(x->>'ticker') as ticker,
            (x->>'trade_date')::date as trade_date,
            upper(x->>'broker_code') as broker_code,
            upper(coalesce(nullif(x->>'market_type',''), 'RG')) as market_type,
            greatest(coalesce((x->>'buy_value')::numeric, 0), 0) as buy_value,
            greatest(coalesce((x->>'sell_value')::numeric, 0), 0) as sell_value,
            greatest(coalesce((x->>'buy_volume')::numeric, 0), 0) as buy_volume,
            greatest(coalesce((x->>'sell_volume')::numeric, 0), 0) as sell_volume,
            greatest(coalesce((x->>'buy_avg')::numeric, 0), 0) as buy_avg,
            greatest(coalesce((x->>'sell_avg')::numeric, 0), 0) as sell_avg,
            x->>'source' as source,
            coalesce((x->>'source_verified')::boolean, false) as source_verified,
            x->>'source_url' as source_url,
            x->>'provenance_state' as provenance_state
        from raw_rows
        where x ? 'ticker'
          and x ? 'trade_date'
          and x ? 'broker_code'
    ), eligible_rows as (
        select *
        from normalized
        where ticker ~ '^[A-Z0-9]{1,10}$'
          and broker_code ~ '^[A-Z0-9]{1,8}$'
          and trade_date between (current_date - 180) and current_date
          and market_type = 'RG'
          and source = 'INDEX_ALPHA_BROKER_SUMMARY'
          and source_verified = true
          and source_url = 'https://api.indexalpha.id/stocks/broker-summary'
          and provenance_state like 'VERIFIED_VENDOR_API_EXACT_DAY_%_RG_VOLUME_UNIT_PROVIDER_NATIVE'
          and (buy_value > 0 or sell_value > 0 or buy_volume > 0 or sell_volume > 0)
    ), valid_ticker_days as (
        select ticker, trade_date
        from eligible_rows
        group by ticker, trade_date
        having count(distinct broker_code) >= 2
           and sum(buy_value) > 0
           and sum(sell_value) > 0
           and 100 * abs(sum(buy_value) - sum(sell_value))
               / greatest((sum(buy_value) + sum(sell_value)) / 2, 1) <= 10
    ), upserted as (
        insert into public.flow_broker_flows (
            ticker, trade_date, broker_code, market_type,
            buy_value, sell_value, buy_volume, sell_volume,
            buy_avg, sell_avg, source, source_verified,
            source_url, provenance_state
        )
        select
            e.ticker, e.trade_date, e.broker_code, e.market_type,
            e.buy_value, e.sell_value, e.buy_volume, e.sell_volume,
            e.buy_avg, e.sell_avg, e.source, e.source_verified,
            e.source_url, e.provenance_state
        from eligible_rows e
        join valid_ticker_days v using (ticker, trade_date)
        on conflict (ticker, trade_date, broker_code, market_type, source)
        do update set
            buy_value = excluded.buy_value,
            sell_value = excluded.sell_value,
            buy_volume = excluded.buy_volume,
            sell_volume = excluded.sell_volume,
            buy_avg = excluded.buy_avg,
            sell_avg = excluded.sell_avg,
            source_verified = excluded.source_verified,
            source_url = excluded.source_url,
            provenance_state = excluded.provenance_state,
            ingested_at = now()
        returning 1
    )
    select count(*)::integer into v_upserted from upserted;

    return v_upserted;
end;
$$;

revoke all on function public.flow_sync_indexalpha_broker_cache() from public;
revoke all on function public.flow_sync_indexalpha_broker_cache() from anon;
revoke all on function public.flow_sync_indexalpha_broker_cache() from authenticated;
grant execute on function public.flow_sync_indexalpha_broker_cache() to service_role;

select cron.unschedule('flow-indexalpha-broker-pull-sync')
where exists (select 1 from cron.job where jobname = 'flow-indexalpha-broker-pull-sync');

select cron.schedule(
    'flow-indexalpha-broker-pull-sync',
    '0 13 * * *',
    $cron$select public.flow_sync_indexalpha_broker_cache();$cron$
);
