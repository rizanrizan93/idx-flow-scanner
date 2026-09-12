create table if not exists public.flow_research_horizon_ui_cache_v1 (
  strategy_contract text not null,
  strategy_id text not null,
  display_name text not null,
  horizon_days integer not null check (horizon_days in (5,20,60)),
  as_of_date date not null,
  universe_snapshot_date date,
  research_rank integer not null,
  ticker text not null,
  stock_name text,
  sector text,
  universe_rank integer,
  current_tradeable boolean,
  production_actionable boolean,
  close numeric,
  traded_value numeric,
  foreign_net_volume_pct numeric,
  stock_residual_activity_z numeric,
  fin_balance_score numeric,
  risk_event_20d_count integer,
  capital_action_90d_count integer,
  ihsg_return_5d_pct numeric,
  ihsg_return_20d_pct numeric,
  top10_value_share_pct numeric,
  market_activity_intensity_z numeric,
  market_gate_state text,
  signal_state text,
  research_priority_score numeric,
  production_influence_enabled boolean not null default false check (production_influence_enabled=false),
  refreshed_at timestamptz not null default now(),
  primary key (strategy_id,ticker)
);

create index if not exists flow_research_horizon_ui_cache_rank_idx
  on public.flow_research_horizon_ui_cache_v1(horizon_days,research_rank);

create table if not exists public.flow_financial_shadow_current_v6 (
  as_of_date date not null,
  ticker text primary key,
  sector text,
  financial_state text,
  report_year integer,
  report_period text,
  report_period_end date,
  published_at timestamptz,
  quality_score numeric,
  growth_score numeric,
  balance_score numeric,
  cashflow_score numeric,
  financial_shadow_score numeric,
  financial_shadow_rank integer not null,
  production_influence_enabled boolean not null default false check (production_influence_enabled=false),
  refreshed_at timestamptz not null default now()
);

create index if not exists flow_financial_shadow_current_v6_rank_idx
  on public.flow_financial_shadow_current_v6(financial_shadow_rank);

alter table public.flow_research_horizon_ui_cache_v1 enable row level security;
alter table public.flow_financial_shadow_current_v6 enable row level security;
revoke all on public.flow_research_horizon_ui_cache_v1 from anon, authenticated;
revoke all on public.flow_financial_shadow_current_v6 from anon, authenticated;
grant select on public.flow_research_horizon_ui_cache_v1 to service_role;
grant select on public.flow_financial_shadow_current_v6 to service_role;

create or replace function public.flow_refresh_research_ui_cache_v1(p_as_of_date date default null)
returns jsonb
language plpgsql
set search_path=''
as $function$
declare
  v_date date;
  v_horizon_rows integer := 0;
  v_financial_rows integer := 0;
begin
  select coalesce(p_as_of_date,max(as_of_date)) into v_date
  from public.flow_market_learning_panel_v4;

  if v_date is null then
    return jsonb_build_object('status','SOURCE_NOT_READY','reason','NO_MARKET_PANEL');
  end if;

  truncate table public.flow_research_horizon_ui_cache_v1;

  insert into public.flow_research_horizon_ui_cache_v1(
    strategy_contract,strategy_id,display_name,horizon_days,as_of_date,universe_snapshot_date,
    research_rank,ticker,stock_name,sector,universe_rank,current_tradeable,production_actionable,
    close,traded_value,foreign_net_volume_pct,stock_residual_activity_z,fin_balance_score,
    risk_event_20d_count,capital_action_90d_count,ihsg_return_5d_pct,ihsg_return_20d_pct,
    top10_value_share_pct,market_activity_intensity_z,market_gate_state,signal_state,
    research_priority_score,production_influence_enabled,refreshed_at
  )
  select
    r.strategy_contract,r.strategy_id,r.display_name,r.horizon_days,r.as_of_date,r.universe_snapshot_date,
    r.research_rank,r.ticker,r.stock_name,r.sector,r.universe_rank,r.current_tradeable,r.production_actionable,
    r.close,r.traded_value,r.foreign_net_volume_pct,r.stock_residual_activity_z,r.fin_balance_score,
    r.risk_event_20d_count,r.capital_action_90d_count,r.ihsg_return_5d_pct,r.ihsg_return_20d_pct,
    r.top10_value_share_pct,r.market_activity_intensity_z,r.market_gate_state,r.signal_state,
    r.research_priority_score,false,now()
  from public.flow_research_horizon_rankings_v1(v_date) r
  where r.production_influence_enabled=false
    and (r.research_rank<=250 or r.signal_state='ACTIVE');
  get diagnostics v_horizon_rows=row_count;

  truncate table public.flow_financial_shadow_current_v6;

  insert into public.flow_financial_shadow_current_v6(
    as_of_date,ticker,sector,financial_state,report_year,report_period,report_period_end,published_at,
    quality_score,growth_score,balance_score,cashflow_score,financial_shadow_score,financial_shadow_rank,
    production_influence_enabled,refreshed_at
  )
  select
    x.as_of_date,x.ticker,x.sector,x.financial_state,x.report_year,x.report_period,x.report_period_end,x.published_at,
    x.quality_score,x.growth_score,x.balance_score,x.cashflow_score,x.financial_shadow_score,x.financial_shadow_rank,
    false,now()
  from (
    select f.*,
      row_number() over(order by f.financial_shadow_score desc nulls last,f.ticker)::integer as financial_shadow_rank
    from public.flow_financial_shadow_snapshot_v6(v_date) f
    where f.production_influence_enabled=false
      and f.financial_state='AVAILABLE'
  ) x
  where x.financial_shadow_rank<=250;
  get diagnostics v_financial_rows=row_count;

  return jsonb_build_object(
    'status','REFRESHED',
    'as_of_date',v_date,
    'horizon_rows',v_horizon_rows,
    'financial_rows',v_financial_rows,
    'production_influence_enabled',false
  );
end;
$function$;

create or replace function public.flow_run_research_horizon_daily_v1()
returns jsonb
language plpgsql
set search_path=''
as $function$
declare
  v_today date := (now() at time zone 'Asia/Jakarta')::date;
  v_latest date;
  v_capture jsonb;
  v_cache jsonb;
  v_outcomes jsonb;
begin
  select max(as_of_date) into v_latest from public.flow_market_learning_panel_v4;
  v_outcomes := public.flow_refresh_research_horizon_outcomes_v1();
  if v_latest is distinct from v_today then
    return jsonb_build_object('status','SOURCE_NOT_READY','jakarta_date',v_today,'latest_market_date',v_latest,'outcomes',v_outcomes);
  end if;
  v_capture := public.flow_capture_research_horizon_signals_v1(v_today);
  v_cache := public.flow_refresh_research_ui_cache_v1(v_today);
  return jsonb_build_object('status','OK','signal_date',v_today,'capture',v_capture,'cache',v_cache,'outcomes',v_outcomes,'production_influence_enabled',false);
end;
$function$;

revoke all on function public.flow_refresh_research_ui_cache_v1(date) from public, anon, authenticated;
grant execute on function public.flow_refresh_research_ui_cache_v1(date) to service_role;
