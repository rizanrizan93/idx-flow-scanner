create or replace function public.flow_validate_indexalpha_broker_row()
returns trigger
language plpgsql
security invoker
set search_path = public, pg_temp
as $$
begin
    if new.source <> 'INDEX_ALPHA_BROKER_SUMMARY' then
        return new;
    end if;

    if new.market_type <> 'RG'
       or new.source_verified is not true
       or new.source_url <> 'https://api.indexalpha.id/stocks/broker-summary'
       or new.provenance_state <> 'VERIFIED_VENDOR_API_EXACT_DAY_ALL_RG_VOLUME_UNIT_PROVIDER_NATIVE'
    then
        raise exception 'Rejected Index Alpha broker row with invalid exact-day RG/all provenance';
    end if;

    return new;
end;
$$;

revoke execute on function public.flow_validate_indexalpha_broker_row() from public, anon, authenticated;

drop trigger if exists trg_flow_validate_indexalpha_broker_row on public.flow_broker_flows;
create trigger trg_flow_validate_indexalpha_broker_row
before insert or update on public.flow_broker_flows
for each row execute function public.flow_validate_indexalpha_broker_row();

create or replace function public.flow_validate_indexalpha_ticker_day_balance()
returns trigger
language plpgsql
security invoker
set search_path = public, pg_temp
as $$
declare
    v_brokers integer;
    v_buy numeric;
    v_sell numeric;
    v_error numeric;
begin
    if new.source <> 'INDEX_ALPHA_BROKER_SUMMARY' then
        return null;
    end if;

    select count(distinct broker_code), coalesce(sum(buy_value),0), coalesce(sum(sell_value),0)
      into v_brokers, v_buy, v_sell
    from public.flow_broker_flows
    where ticker = new.ticker
      and trade_date = new.trade_date
      and market_type = new.market_type
      and source = new.source;

    v_error := 100 * abs(v_buy - v_sell) / greatest((v_buy + v_sell) / 2, 1);

    if v_brokers < 2 or v_buy <= 0 or v_sell <= 0 or v_error > 10 then
        raise exception 'Rejected Index Alpha ticker-day % %: brokers %, closed-book balance error %%%',
            new.ticker, new.trade_date, v_brokers, round(v_error,4);
    end if;

    return null;
end;
$$;

revoke execute on function public.flow_validate_indexalpha_ticker_day_balance() from public, anon, authenticated;

drop trigger if exists trg_flow_validate_indexalpha_ticker_day_balance on public.flow_broker_flows;
create constraint trigger trg_flow_validate_indexalpha_ticker_day_balance
after insert or update on public.flow_broker_flows
deferrable initially deferred
for each row execute function public.flow_validate_indexalpha_ticker_day_balance();
