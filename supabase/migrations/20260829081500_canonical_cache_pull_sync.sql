create extension if not exists http with schema extensions;
create extension if not exists pg_cron;

create or replace function public.flow_sync_canonical_ohlcv_recent()
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
            'https://raw.githubusercontent.com/rizanrizan93/idx-flow-scanner/refs/heads/main/data/cache/idx_400_ohlcv_recent.json'
        ) as r
    ) s;

    if v_status <> 200 then
        raise exception 'Canonical OHLCV mirror HTTP status %', v_status;
    end if;

    begin
        v_payload := v_content::jsonb;
    exception when others then
        raise exception 'Canonical OHLCV mirror is not valid JSON';
    end;

    if jsonb_typeof(v_payload) <> 'array' then
        raise exception 'Canonical OHLCV mirror root must be a JSON array';
    end if;

    with normalized as (
        select
            upper(x->>'ticker') as ticker,
            (x->>'date')::date as trade_date,
            (x->>'open')::numeric as open,
            (x->>'high')::numeric as high,
            (x->>'low')::numeric as low,
            (x->>'close')::numeric as close,
            greatest(coalesce((x->>'volume')::numeric, 0), 0) as volume
        from jsonb_array_elements(v_payload) as x
        where x ? 'ticker' and x ? 'date' and x ? 'close'
    ), eligible as (
        select *
        from normalized
        where ticker ~ '^[A-Z0-9]{1,10}$'
          and trade_date between (current_date - 45) and current_date
          and open > 0 and high > 0 and low > 0 and close > 0
          and high >= greatest(open, close)
          and low <= least(open, close)
          and high >= low
    ), upserted as (
        insert into public.flow_daily_prices (
            ticker, trade_date, open, high, low, close, volume,
            source, source_timestamp
        )
        select
            ticker, trade_date, open, high, low, close, volume,
            'CANONICAL_GITHUB_EOD_SEED', null
        from eligible
        on conflict (ticker, trade_date, source)
        do update set
            open = excluded.open,
            high = excluded.high,
            low = excluded.low,
            close = excluded.close,
            volume = excluded.volume,
            ingested_at = now()
        returning 1
    )
    select count(*)::integer into v_upserted from upserted;

    return v_upserted;
end;
$$;

revoke all on function public.flow_sync_canonical_ohlcv_recent() from public;
revoke all on function public.flow_sync_canonical_ohlcv_recent() from anon;
revoke all on function public.flow_sync_canonical_ohlcv_recent() from authenticated;
grant execute on function public.flow_sync_canonical_ohlcv_recent() to service_role;


create or replace function public.flow_sync_zapi_foreign_cache()
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
            'https://raw.githubusercontent.com/rizanrizan93/idx-flow-scanner/refs/heads/main/data/cache/zapi_idx_foreign_60d.json'
        ) as r
    ) s;

    if v_status <> 200 then
        raise exception 'ZAPI foreign mirror HTTP status %', v_status;
    end if;

    begin
        v_payload := v_content::jsonb;
    exception when others then
        raise exception 'ZAPI foreign mirror is not valid JSON';
    end;

    if jsonb_typeof(v_payload) <> 'array' then
        raise exception 'ZAPI foreign mirror root must be a JSON array';
    end if;

    with normalized as (
        select
            upper(x->>'ticker') as ticker,
            (x->>'trade_date')::date as trade_date,
            greatest(coalesce((x->>'foreign_buy')::numeric, 0), 0) as foreign_buy,
            greatest(coalesce((x->>'foreign_sell')::numeric, 0), 0) as foreign_sell,
            coalesce((x->>'foreign_net')::numeric, 0) as foreign_net,
            greatest(coalesce((x->>'volume')::numeric, 0), 0) as volume,
            greatest(coalesce((x->>'traded_value')::numeric, 0), 0) as traded_value,
            upper(coalesce(x->>'flow_unit','')) as flow_unit,
            upper(coalesce(x->>'market_type','ALL')) as market_type,
            x->>'source' as source,
            coalesce((x->>'source_verified')::boolean, false) as source_verified,
            x->>'source_url' as source_url,
            x->>'provenance_state' as provenance_state
        from jsonb_array_elements(v_payload) as x
        where x ? 'ticker' and x ? 'trade_date' and x ? 'source'
    ), eligible as (
        select *
        from normalized
        where ticker ~ '^[A-Z0-9]{1,10}$'
          and trade_date between (current_date - 120) and current_date
          and flow_unit = 'SHARES'
          and market_type = 'ALL'
          and source in ('ZAPI_IDX_FOREIGN_FLOW','ZAPI_IDX_STOCK_SUMMARY')
          and source_verified = true
          and provenance_state = 'VERIFIED_ZAPI_IDX_SHARE_FLOW_NOT_BROKER_IDENTITY'
          and source_url in (
              'https://api.zpi.web.id/v1/finance:idx/foreign-flow',
              'https://api.zpi.web.id/v1/finance:idx/stock-summary'
          )
    ), upserted as (
        insert into public.flow_vendor_foreign_flows (
            ticker, trade_date, foreign_buy, foreign_sell, foreign_net,
            volume, traded_value, flow_unit, market_type, source,
            source_verified, source_url, provenance_state, retrieved_at
        )
        select
            ticker, trade_date, foreign_buy, foreign_sell, foreign_net,
            volume, traded_value, flow_unit, market_type, source,
            source_verified, source_url, provenance_state, now()
        from eligible
        on conflict (ticker, trade_date, source, market_type)
        do update set
            foreign_buy = excluded.foreign_buy,
            foreign_sell = excluded.foreign_sell,
            foreign_net = excluded.foreign_net,
            volume = excluded.volume,
            traded_value = excluded.traded_value,
            source_verified = excluded.source_verified,
            source_url = excluded.source_url,
            provenance_state = excluded.provenance_state,
            retrieved_at = now()
        returning 1
    )
    select count(*)::integer into v_upserted from upserted;

    return v_upserted;
end;
$$;

revoke all on function public.flow_sync_zapi_foreign_cache() from public;
revoke all on function public.flow_sync_zapi_foreign_cache() from anon;
revoke all on function public.flow_sync_zapi_foreign_cache() from authenticated;
grant execute on function public.flow_sync_zapi_foreign_cache() to service_role;

select cron.unschedule('flow-zapi-foreign-pull-sync')
where exists (select 1 from cron.job where jobname = 'flow-zapi-foreign-pull-sync');

select cron.schedule(
    'flow-zapi-foreign-pull-sync',
    '10 13 * * 1-5',
    $cron$select public.flow_sync_zapi_foreign_cache();$cron$
);

select cron.unschedule('flow-canonical-ohlcv-pull-sync')
where exists (select 1 from cron.job where jobname = 'flow-canonical-ohlcv-pull-sync');

select cron.schedule(
    'flow-canonical-ohlcv-pull-sync',
    '15 13 * * 1-5',
    $cron$select public.flow_sync_canonical_ohlcv_recent();$cron$
);
