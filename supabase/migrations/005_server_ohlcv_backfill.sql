-- Private, audited Yahoo chart backfill used to warm a cold Flow database.
-- This helper only writes public OHLCV. It never writes flow_broker_flows and
-- therefore cannot upgrade PRICE_PROXY evidence to BROKER_DIRECT.

create schema if not exists flow_private;
revoke all on schema flow_private from public, anon, authenticated;

create or replace function flow_private.backfill_yahoo_ohlcv(
  p_tickers text[],
  p_range text default '1y'
)
returns table(ticker text, http_status integer, rows_accepted integer, status text)
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_ticker text;
  v_url text;
  v_http_status integer;
  v_content text;
  v_payload jsonb;
  v_result jsonb;
  v_quote jsonb;
  v_rows integer;
  v_audit_id bigint;
begin
  foreach v_ticker in array p_tickers loop
    v_ticker := upper(trim(v_ticker));
    v_rows := 0;
    insert into public.flow_ingestion_audit(provider, dataset, ticker, status, details)
    values ('YAHOO_CHART', 'OHLCV_DAILY', v_ticker, 'RUNNING', jsonb_build_object('range', p_range, 'path', 'SUPABASE_HTTP'))
    returning id into v_audit_id;

    begin
      v_url := format(
        'https://query1.finance.yahoo.com/v8/finance/chart/%s.JK?range=%s&interval=1d&events=div%%2Csplits&includeAdjustedClose=true',
        v_ticker,
        case when p_range in ('6mo','1y','2y','5y') then p_range else '1y' end
      );

      select h.status, h.content
      into v_http_status, v_content
      from extensions.http_get(v_url) as h;

      if v_http_status <> 200 then
        update public.flow_ingestion_audit
        set completed_at = now(), status = 'HTTP_ERROR', error_code = 'HTTP_' || v_http_status::text
        where id = v_audit_id;
        ticker := v_ticker; http_status := v_http_status; rows_accepted := 0; status := 'HTTP_ERROR';
        return next;
        continue;
      end if;

      v_payload := v_content::jsonb;
      v_result := v_payload #> '{chart,result,0}';
      v_quote := v_result #> '{indicators,quote,0}';

      if v_result is null or jsonb_typeof(v_result->'timestamp') <> 'array' then
        update public.flow_ingestion_audit
        set completed_at = now(), status = 'NO_DATA', error_code = 'NO_CHART_RESULT'
        where id = v_audit_id;
        ticker := v_ticker; http_status := v_http_status; rows_accepted := 0; status := 'NO_DATA';
        return next;
        continue;
      end if;

      insert into public.flow_daily_prices(
        ticker, trade_date, open, high, low, close, volume, traded_value, source, source_timestamp
      )
      select
        v_ticker,
        (to_timestamp((ts.value::text)::bigint) at time zone 'UTC')::date,
        nullif(v_quote->'open'->>((ts.ord - 1)::int), 'null')::numeric,
        nullif(v_quote->'high'->>((ts.ord - 1)::int), 'null')::numeric,
        nullif(v_quote->'low'->>((ts.ord - 1)::int), 'null')::numeric,
        nullif(v_quote->'close'->>((ts.ord - 1)::int), 'null')::numeric,
        nullif(v_quote->'volume'->>((ts.ord - 1)::int), 'null')::numeric,
        case
          when nullif(v_quote->'close'->>((ts.ord - 1)::int), 'null') is not null
           and nullif(v_quote->'volume'->>((ts.ord - 1)::int), 'null') is not null
          then (v_quote->'close'->>((ts.ord - 1)::int))::numeric * (v_quote->'volume'->>((ts.ord - 1)::int))::numeric
          else null
        end,
        'YAHOO_CHART_DB',
        now()
      from jsonb_array_elements(v_result->'timestamp') with ordinality as ts(value, ord)
      where nullif(v_quote->'close'->>((ts.ord - 1)::int), 'null') is not null
        and (v_quote->'close'->>((ts.ord - 1)::int))::numeric > 0
      on conflict (ticker, trade_date, source) do update
      set open = excluded.open,
          high = excluded.high,
          low = excluded.low,
          close = excluded.close,
          volume = excluded.volume,
          traded_value = excluded.traded_value,
          source_timestamp = excluded.source_timestamp,
          ingested_at = now();

      get diagnostics v_rows = row_count;

      update public.flow_ingestion_audit
      set completed_at = now(),
          status = case when v_rows >= 80 then 'COMPLETED' else 'INSUFFICIENT' end,
          rows_received = v_rows,
          rows_accepted = v_rows,
          freshness_date = (select max(trade_date) from public.flow_daily_prices where ticker = v_ticker),
          details = details || jsonb_build_object('http_status', v_http_status, 'source', 'YAHOO_CHART_DB')
      where id = v_audit_id;

      ticker := v_ticker;
      http_status := v_http_status;
      rows_accepted := v_rows;
      status := case when v_rows >= 80 then 'COMPLETED' else 'INSUFFICIENT' end;
      return next;
    exception when others then
      update public.flow_ingestion_audit
      set completed_at = now(), status = 'FAILED', error_code = sqlstate,
          details = details || jsonb_build_object('error', sqlerrm)
      where id = v_audit_id;
      ticker := v_ticker; http_status := coalesce(v_http_status, 0); rows_accepted := 0; status := 'FAILED';
      return next;
    end;
  end loop;
end;
$$;

revoke all on function flow_private.backfill_yahoo_ohlcv(text[], text) from public, anon, authenticated;
