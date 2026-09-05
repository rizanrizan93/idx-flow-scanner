-- PENDING production bootstrap for dedicated IDX Flow Scanner only.
-- Target project ref: djqvhbeonmicztxfisav
--
-- This file intentionally lives outside supabase/migrations while production
-- migration history is not in parity with the repository. Apply with execute_sql
-- only after the target project is verified, run smoke queries, then convert the
-- verified DDL into a canonical migration after migration-history repair.
--
-- Evidence policy: factual cache rows only. No synthetic foreign flow, free float,
-- ownership, or corporate-action rows are created.

create extension if not exists http with schema extensions;
create extension if not exists pg_cron;

create table if not exists public.flow_zapi_stock_summary (
    ticker text not null check (ticker = upper(ticker) and ticker ~ '^[A-Z0-9]{1,10}$'),
    trade_date date not null,
    foreign_buy numeric,
    foreign_sell numeric,
    foreign_net numeric,
    volume numeric,
    traded_value numeric,
    frequency numeric,
    bid numeric,
    offer numeric,
    bid_volume numeric,
    offer_volume numeric,
    listed_shares numeric not null check (listed_shares > 0),
    tradable_shares numeric not null check (tradable_shares > 0),
    source text not null,
    source_verified boolean not null default false,
    source_url text,
    provenance_state text not null,
    ingested_at timestamptz not null default now(),
    primary key (ticker, trade_date, source),
    check (tradable_shares <= listed_shares * 1.05)
);
create index if not exists flow_zapi_stock_summary_ticker_date_idx
    on public.flow_zapi_stock_summary (ticker, trade_date desc);

create table if not exists public.flow_zapi_ownership (
    ticker text not null check (ticker = upper(ticker) and ticker ~ '^[A-Z0-9]{1,10}$'),
    category text not null,
    holder_identity_hash text not null check (holder_identity_hash ~ '^[0-9a-f]{64}$'),
    holder_name text,
    shares_held numeric check (shares_held is null or shares_held >= 0),
    ownership_percentage numeric check (
        ownership_percentage is null or ownership_percentage between 0 and 100
    ),
    holder_classification text,
    holder_type text,
    local_foreign_state text,
    report_date date not null,
    report_date_kind text,
    publication_date date,
    source_url text,
    source_file_hash text,
    source_verified boolean not null default false,
    provenance_state text not null,
    ingested_at timestamptz not null default now(),
    primary key (ticker, report_date, category, holder_identity_hash)
);
create index if not exists flow_zapi_ownership_ticker_date_idx
    on public.flow_zapi_ownership (ticker, report_date desc);

create table if not exists public.flow_zapi_capital_actions (
    ticker text not null check (ticker = upper(ticker) and ticker ~ '^[A-Z0-9]{1,10}$'),
    event_type text not null,
    event_date date not null,
    event_start_date date,
    event_end_date date,
    publication_date date,
    pre_shares numeric,
    post_shares numeric,
    delta_shares numeric,
    delta_percent numeric,
    ratio_before numeric,
    ratio_after numeric,
    raw_action text,
    source_feed text not null,
    source text,
    source_url text,
    source_verified boolean not null default false,
    observed_on date,
    provenance_state text not null,
    ingested_at timestamptz not null default now(),
    primary key (ticker, event_type, event_date, source_feed)
);
create index if not exists flow_zapi_capital_actions_ticker_date_idx
    on public.flow_zapi_capital_actions (ticker, event_date desc);

alter table public.flow_zapi_stock_summary enable row level security;
alter table public.flow_zapi_ownership enable row level security;
alter table public.flow_zapi_capital_actions enable row level security;

revoke all on table public.flow_zapi_stock_summary from public, anon, authenticated;
revoke all on table public.flow_zapi_ownership from public, anon, authenticated;
revoke all on table public.flow_zapi_capital_actions from public, anon, authenticated;
grant select, insert, update, delete on table public.flow_zapi_stock_summary to service_role;
grant select, insert, update, delete on table public.flow_zapi_ownership to service_role;
grant select, insert, update, delete on table public.flow_zapi_capital_actions to service_role;

comment on table public.flow_zapi_stock_summary is
    'Authenticated ZAPI IDX stock-summary snapshot used for factual listed/tradable shares and free-float structure.';
comment on table public.flow_zapi_ownership is
    'Verified IDX/KSEI ownership evidence obtained through ZAPI ownership index or verified ZAPI IDX company-profile shareholders.';
comment on table public.flow_zapi_capital_actions is
    'Verified IDX capital-action datasets obtained through ZAPI; absence of a ticker row is not evidence of no event outside the retained horizon.';

create or replace function public.flow_sync_idx700_issuers()
returns integer
language plpgsql
security invoker
set search_path = public, extensions, pg_temp
as $$
declare
    v_status integer;
    v_content text;
    v_payload jsonb;
    v_count integer := 0;
begin
    select (r).status, (r).content into v_status, v_content
    from (
        select extensions.http_get(
            'https://raw.githubusercontent.com/rizanrizan93/idx-flow-scanner/refs/heads/main/data/universe/idx_700_all.json'
        ) as r
    ) s;
    if v_status <> 200 then
        raise exception 'IDX700 universe mirror HTTP status %', v_status;
    end if;
    v_payload := v_content::jsonb;
    if jsonb_typeof(v_payload) <> 'array' then
        raise exception 'IDX700 universe mirror root must be JSON array';
    end if;

    with eligible as (
        select
            upper(x->>'ticker') as ticker,
            nullif(btrim(x->>'sector'), '') as sector,
            coalesce((x->>'active')::boolean, true) as active
        from jsonb_array_elements(v_payload) x
        where x ? 'ticker'
          and upper(x->>'ticker') ~ '^[A-Z0-9]{1,10}$'
    ), upserted as (
        insert into public.flow_issuers (ticker, sector, active, updated_at)
        select ticker, coalesce(sector, 'UNKNOWN'), active, now()
        from eligible
        on conflict (ticker) do update set
            sector = excluded.sector,
            active = excluded.active,
            updated_at = now()
        returning 1
    )
    select count(*)::integer into v_count from upserted;
    return v_count;
end;
$$;

create or replace function public.flow_sync_canonical_ohlcv_recent()
returns integer
language plpgsql
security invoker
set search_path = public, extensions, pg_temp
as $$
declare
    v_status integer;
    v_content text;
    v_payload jsonb;
    v_count integer := 0;
begin
    select (r).status, (r).content into v_status, v_content
    from (
        select extensions.http_get(
            'https://raw.githubusercontent.com/rizanrizan93/idx-flow-scanner/refs/heads/main/data/cache/idx_700_ohlcv_recent.json'
        ) as r
    ) s;
    if v_status <> 200 then
        raise exception 'Canonical IDX700 OHLCV mirror HTTP status %', v_status;
    end if;
    v_payload := v_content::jsonb;
    if jsonb_typeof(v_payload) <> 'array' then
        raise exception 'Canonical IDX700 OHLCV mirror root must be JSON array';
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
        from jsonb_array_elements(v_payload) x
        where x ? 'ticker' and x ? 'date' and x ? 'close'
    ), eligible as (
        select * from normalized
        where ticker ~ '^[A-Z0-9]{1,10}$'
          and trade_date between current_date - 45 and current_date
          and open > 0 and high > 0 and low > 0 and close > 0
          and high >= greatest(open, close)
          and low <= least(open, close)
          and high >= low
    ), upserted as (
        insert into public.flow_daily_prices (
            ticker, trade_date, open, high, low, close, volume, source, source_timestamp
        )
        select ticker, trade_date, open, high, low, close, volume,
               'CANONICAL_GITHUB_EOD_SEED', null
        from eligible
        on conflict (ticker, trade_date, source) do update set
            open = excluded.open,
            high = excluded.high,
            low = excluded.low,
            close = excluded.close,
            volume = excluded.volume,
            ingested_at = now()
        returning 1
    )
    select count(*)::integer into v_count from upserted;
    return v_count;
end;
$$;

create or replace function public.flow_sync_zapi_stock_summary_cache()
returns integer
language plpgsql
security invoker
set search_path = public, extensions, pg_temp
as $$
declare
    v_status integer;
    v_content text;
    v_payload jsonb;
    v_count integer := 0;
begin
    select (r).status, (r).content into v_status, v_content
    from (
        select extensions.http_get(
            'https://raw.githubusercontent.com/rizanrizan93/idx-flow-scanner/refs/heads/main/data/cache/zapi_stock_summary_latest.json'
        ) as r
    ) s;
    if v_status <> 200 then
        raise exception 'ZAPI stock-summary mirror HTTP status %', v_status;
    end if;
    v_payload := v_content::jsonb;
    if jsonb_typeof(v_payload) <> 'array' then
        raise exception 'ZAPI stock-summary mirror root must be JSON array';
    end if;

    with normalized as (
        select
            upper(x->>'ticker') as ticker,
            (x->>'trade_date')::date as trade_date,
            nullif(x->>'foreign_buy','')::numeric as foreign_buy,
            nullif(x->>'foreign_sell','')::numeric as foreign_sell,
            nullif(x->>'foreign_net','')::numeric as foreign_net,
            nullif(x->>'volume','')::numeric as volume,
            nullif(x->>'traded_value','')::numeric as traded_value,
            nullif(x->>'frequency','')::numeric as frequency,
            nullif(x->>'bid','')::numeric as bid,
            nullif(x->>'offer','')::numeric as offer,
            nullif(x->>'bid_volume','')::numeric as bid_volume,
            nullif(x->>'offer_volume','')::numeric as offer_volume,
            (x->>'listed_shares')::numeric as listed_shares,
            (x->>'tradable_shares')::numeric as tradable_shares,
            x->>'source' as source,
            coalesce((x->>'source_verified')::boolean, false) as source_verified,
            x->>'source_url' as source_url,
            x->>'provenance_state' as provenance_state
        from jsonb_array_elements(v_payload) x
        where x ? 'ticker' and x ? 'trade_date'
    ), eligible as (
        select * from normalized
        where ticker ~ '^[A-Z0-9]{1,10}$'
          and trade_date between current_date - 60 and current_date
          and listed_shares > 0
          and tradable_shares > 0
          and tradable_shares <= listed_shares * 1.05
          and source = 'ZAPI_IDX_STOCK_SUMMARY'
          and source_verified = true
          and source_url = 'https://api.zpi.web.id/v1/finance:idx/stock-summary'
          and provenance_state = 'VERIFIED_ZAPI_IDX_STOCK_SUMMARY_NOT_BROKER_IDENTITY'
    ), upserted as (
        insert into public.flow_zapi_stock_summary (
            ticker, trade_date, foreign_buy, foreign_sell, foreign_net,
            volume, traded_value, frequency, bid, offer, bid_volume, offer_volume,
            listed_shares, tradable_shares, source, source_verified, source_url,
            provenance_state, ingested_at
        )
        select ticker, trade_date, foreign_buy, foreign_sell, foreign_net,
               volume, traded_value, frequency, bid, offer, bid_volume, offer_volume,
               listed_shares, tradable_shares, source, source_verified, source_url,
               provenance_state, now()
        from eligible
        on conflict (ticker, trade_date, source) do update set
            foreign_buy = excluded.foreign_buy,
            foreign_sell = excluded.foreign_sell,
            foreign_net = excluded.foreign_net,
            volume = excluded.volume,
            traded_value = excluded.traded_value,
            frequency = excluded.frequency,
            bid = excluded.bid,
            offer = excluded.offer,
            bid_volume = excluded.bid_volume,
            offer_volume = excluded.offer_volume,
            listed_shares = excluded.listed_shares,
            tradable_shares = excluded.tradable_shares,
            source_verified = excluded.source_verified,
            source_url = excluded.source_url,
            provenance_state = excluded.provenance_state,
            ingested_at = now()
        returning 1
    )
    select count(*)::integer into v_count from upserted;
    return v_count;
end;
$$;

create or replace function public.flow_sync_zapi_ownership_cache()
returns integer
language plpgsql
security invoker
set search_path = public, extensions, pg_temp
as $$
declare
    v_status integer;
    v_content text;
    v_payload jsonb;
    v_count integer := 0;
begin
    select (r).status, (r).content into v_status, v_content
    from (
        select extensions.http_get(
            'https://raw.githubusercontent.com/rizanrizan93/idx-flow-scanner/refs/heads/main/data/cache/zapi_ownership_latest.json'
        ) as r
    ) s;
    if v_status <> 200 then
        raise exception 'ZAPI ownership mirror HTTP status %', v_status;
    end if;
    v_payload := v_content::jsonb;
    if jsonb_typeof(v_payload) <> 'array' then
        raise exception 'ZAPI ownership mirror root must be JSON array';
    end if;

    with normalized as (
        select
            upper(x->>'ticker') as ticker,
            lower(x->>'category') as category,
            lower(x->>'holder_identity_hash') as holder_identity_hash,
            nullif(x->>'holder_name','') as holder_name,
            nullif(x->>'shares_held','')::numeric as shares_held,
            nullif(x->>'ownership_percentage','')::numeric as ownership_percentage,
            nullif(x->>'holder_classification','') as holder_classification,
            nullif(x->>'holder_type','') as holder_type,
            nullif(x->>'local_foreign_state','') as local_foreign_state,
            (x->>'report_date')::date as report_date,
            nullif(x->>'report_date_kind','') as report_date_kind,
            nullif(x->>'publication_date','')::date as publication_date,
            nullif(x->>'source_url','') as source_url,
            nullif(x->>'source_file_hash','') as source_file_hash,
            coalesce((x->>'source_verified')::boolean, false) as source_verified,
            x->>'provenance_state' as provenance_state
        from jsonb_array_elements(v_payload) x
        where x ? 'ticker' and x ? 'report_date'
    ), eligible as (
        select * from normalized
        where ticker ~ '^[A-Z0-9]{1,10}$'
          and holder_identity_hash ~ '^[0-9a-f]{64}$'
          and category <> ''
          and report_date between current_date - 730 and current_date
          and source_verified = true
          and provenance_state in (
              'VERIFIED_IDX_KSEI_FILE_VIA_ZAPI_INDEX',
              'VERIFIED_IDX_COMPANY_PROFILE_VIA_ZAPI'
          )
          and (shares_held is null or shares_held >= 0)
          and (ownership_percentage is null or ownership_percentage between 0 and 100)
    ), upserted as (
        insert into public.flow_zapi_ownership (
            ticker, category, holder_identity_hash, holder_name, shares_held,
            ownership_percentage, holder_classification, holder_type,
            local_foreign_state, report_date, report_date_kind, publication_date,
            source_url, source_file_hash, source_verified, provenance_state, ingested_at
        )
        select ticker, category, holder_identity_hash, holder_name, shares_held,
               ownership_percentage, holder_classification, holder_type,
               local_foreign_state, report_date, report_date_kind, publication_date,
               source_url, source_file_hash, source_verified, provenance_state, now()
        from eligible
        on conflict (ticker, report_date, category, holder_identity_hash) do update set
            holder_name = excluded.holder_name,
            shares_held = excluded.shares_held,
            ownership_percentage = excluded.ownership_percentage,
            holder_classification = excluded.holder_classification,
            holder_type = excluded.holder_type,
            local_foreign_state = excluded.local_foreign_state,
            report_date_kind = excluded.report_date_kind,
            publication_date = excluded.publication_date,
            source_url = excluded.source_url,
            source_file_hash = excluded.source_file_hash,
            source_verified = excluded.source_verified,
            provenance_state = excluded.provenance_state,
            ingested_at = now()
        returning 1
    )
    select count(*)::integer into v_count from upserted;
    return v_count;
end;
$$;

create or replace function public.flow_sync_zapi_capital_actions_cache()
returns integer
language plpgsql
security invoker
set search_path = public, extensions, pg_temp
as $$
declare
    v_status integer;
    v_content text;
    v_payload jsonb;
    v_count integer := 0;
begin
    select (r).status, (r).content into v_status, v_content
    from (
        select extensions.http_get(
            'https://raw.githubusercontent.com/rizanrizan93/idx-flow-scanner/refs/heads/main/data/cache/zapi_capital_actions.json'
        ) as r
    ) s;
    if v_status <> 200 then
        raise exception 'ZAPI capital-action mirror HTTP status %', v_status;
    end if;
    v_payload := v_content::jsonb;
    if jsonb_typeof(v_payload) <> 'array' then
        raise exception 'ZAPI capital-action mirror root must be JSON array';
    end if;

    with normalized as (
        select
            upper(x->>'ticker') as ticker,
            upper(x->>'event_type') as event_type,
            (x->>'event_date')::date as event_date,
            nullif(x->>'event_start_date','')::date as event_start_date,
            nullif(x->>'event_end_date','')::date as event_end_date,
            nullif(x->>'publication_date','')::date as publication_date,
            nullif(x->>'pre_shares','')::numeric as pre_shares,
            nullif(x->>'post_shares','')::numeric as post_shares,
            nullif(x->>'delta_shares','')::numeric as delta_shares,
            nullif(x->>'delta_percent','')::numeric as delta_percent,
            nullif(x->>'ratio_before','')::numeric as ratio_before,
            nullif(x->>'ratio_after','')::numeric as ratio_after,
            nullif(x->>'raw_action','') as raw_action,
            lower(x->>'source_feed') as source_feed,
            nullif(x->>'source','') as source,
            nullif(x->>'source_url','') as source_url,
            coalesce((x->>'source_verified')::boolean, false) as source_verified,
            nullif(x->>'observed_on','')::date as observed_on,
            x->>'provenance_state' as provenance_state
        from jsonb_array_elements(v_payload) x
        where x ? 'ticker' and x ? 'event_date' and x ? 'source_feed'
    ), eligible as (
        select * from normalized
        where ticker ~ '^[A-Z0-9]{1,10}$'
          and event_type <> ''
          and source_feed <> ''
          and event_date between current_date - 450 and current_date + 120
          and source_verified = true
          and provenance_state = 'VERIFIED_IDX_DATASET_VIA_ZAPI'
    ), upserted as (
        insert into public.flow_zapi_capital_actions (
            ticker, event_type, event_date, event_start_date, event_end_date,
            publication_date, pre_shares, post_shares, delta_shares, delta_percent,
            ratio_before, ratio_after, raw_action, source_feed, source, source_url,
            source_verified, observed_on, provenance_state, ingested_at
        )
        select ticker, event_type, event_date, event_start_date, event_end_date,
               publication_date, pre_shares, post_shares, delta_shares, delta_percent,
               ratio_before, ratio_after, raw_action, source_feed, source, source_url,
               source_verified, observed_on, provenance_state, now()
        from eligible
        on conflict (ticker, event_type, event_date, source_feed) do update set
            event_start_date = excluded.event_start_date,
            event_end_date = excluded.event_end_date,
            publication_date = excluded.publication_date,
            pre_shares = excluded.pre_shares,
            post_shares = excluded.post_shares,
            delta_shares = excluded.delta_shares,
            delta_percent = excluded.delta_percent,
            ratio_before = excluded.ratio_before,
            ratio_after = excluded.ratio_after,
            raw_action = excluded.raw_action,
            source = excluded.source,
            source_url = excluded.source_url,
            source_verified = excluded.source_verified,
            observed_on = excluded.observed_on,
            provenance_state = excluded.provenance_state,
            ingested_at = now()
        returning 1
    )
    select count(*)::integer into v_count from upserted;
    return v_count;
end;
$$;

create or replace function public.flow_sync_idx700_evidence()
returns jsonb
language plpgsql
security invoker
set search_path = public, extensions, pg_temp
as $$
declare
    v_result jsonb := '{}'::jsonb;
    v_count integer;
begin
    begin
        v_count := public.flow_sync_idx700_issuers();
        v_result := v_result || jsonb_build_object('issuers', v_count);
    exception when others then
        v_result := v_result || jsonb_build_object('issuers_error', sqlerrm);
    end;

    begin
        v_count := public.flow_sync_canonical_ohlcv_recent();
        v_result := v_result || jsonb_build_object('ohlcv', v_count);
    exception when others then
        v_result := v_result || jsonb_build_object('ohlcv_error', sqlerrm);
    end;

    if to_regprocedure('public.flow_sync_zapi_foreign_cache()') is not null then
        begin
            execute 'select public.flow_sync_zapi_foreign_cache()' into v_count;
            v_result := v_result || jsonb_build_object('foreign_flow', v_count);
        exception when others then
            v_result := v_result || jsonb_build_object('foreign_flow_error', sqlerrm);
        end;
    else
        v_result := v_result || jsonb_build_object('foreign_flow', 'existing sync function unavailable');
    end if;

    begin
        v_count := public.flow_sync_zapi_stock_summary_cache();
        v_result := v_result || jsonb_build_object('stock_summary', v_count);
    exception when others then
        v_result := v_result || jsonb_build_object('stock_summary_error', sqlerrm);
    end;

    begin
        v_count := public.flow_sync_zapi_ownership_cache();
        v_result := v_result || jsonb_build_object('ownership', v_count);
    exception when others then
        v_result := v_result || jsonb_build_object('ownership_error', sqlerrm);
    end;

    begin
        v_count := public.flow_sync_zapi_capital_actions_cache();
        v_result := v_result || jsonb_build_object('capital_actions', v_count);
    exception when others then
        v_result := v_result || jsonb_build_object('capital_actions_error', sqlerrm);
    end;

    return v_result;
end;
$$;

revoke all on function public.flow_sync_idx700_issuers() from public, anon, authenticated;
revoke all on function public.flow_sync_canonical_ohlcv_recent() from public, anon, authenticated;
revoke all on function public.flow_sync_zapi_stock_summary_cache() from public, anon, authenticated;
revoke all on function public.flow_sync_zapi_ownership_cache() from public, anon, authenticated;
revoke all on function public.flow_sync_zapi_capital_actions_cache() from public, anon, authenticated;
revoke all on function public.flow_sync_idx700_evidence() from public, anon, authenticated;

grant execute on function public.flow_sync_idx700_issuers() to service_role;
grant execute on function public.flow_sync_canonical_ohlcv_recent() to service_role;
grant execute on function public.flow_sync_zapi_stock_summary_cache() to service_role;
grant execute on function public.flow_sync_zapi_ownership_cache() to service_role;
grant execute on function public.flow_sync_zapi_capital_actions_cache() to service_role;
grant execute on function public.flow_sync_idx700_evidence() to service_role;

select cron.unschedule('flow-idx700-evidence-sync')
where exists (select 1 from cron.job where jobname = 'flow-idx700-evidence-sync');
select cron.schedule(
    'flow-idx700-evidence-sync',
    '25 13 * * 1-5',
    $cron$select public.flow_sync_idx700_evidence();$cron$
);

-- Run once when this bootstrap is explicitly applied after the JSON mirrors exist.
select public.flow_sync_idx700_evidence();
