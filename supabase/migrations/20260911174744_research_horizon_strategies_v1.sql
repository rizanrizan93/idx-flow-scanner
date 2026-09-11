create table if not exists public.flow_research_horizon_policy_v1 (
  strategy_contract text not null,
  strategy_id text primary key,
  display_name text not null,
  horizon_days integer not null check (horizon_days in (5,20,60)),
  description text not null,
  thresholds jsonb not null,
  policy_state text not null default 'FROZEN_RESEARCH',
  production_influence_enabled boolean not null default false,
  frozen_at timestamptz not null default now()
);

insert into public.flow_research_horizon_policy_v1
(strategy_contract,strategy_id,display_name,horizon_days,description,thresholds,policy_state,production_influence_enabled)
values
('RESEARCH_HORIZON_STRATEGIES_V1_1','BRFE_5','BRFE-5 · Bull-Regime Foreign Expansion',5,
 'IHSG 5D and 20D bullish; foreign burst with minimum liquidity and clean recent risk/capital-action state.',
 '{"ihsg_return_5d_min_pct":0,"ihsg_return_20d_min_pct":0,"foreign_net_volume_min_pct":15,"traded_value_min_idr":1000000000,"risk_event_20d_max":0,"capital_action_90d_max":0}'::jsonb,
 'FROZEN_RESEARCH',false),
('RESEARCH_HORIZON_STRATEGIES_V1_1','BPL_20','BPL-20 · Broad Participation Liquid',20,
 'Low Top-10 market value concentration regime with liquid/current-tradeable Top-900 stocks.',
 '{"top10_value_share_max_pct":59.5,"traded_value_min_idr":1000000000}'::jsonb,
 'FROZEN_RESEARCH',false),
('RESEARCH_HORIZON_STRATEGIES_V1_1','QBA_60','QBA-60 · Quiet Balance Accumulation',60,
 'Strong PIT balance-sheet score plus quiet residual activity while market activity is not depressed.',
 '{"fin_balance_min":80,"stock_residual_activity_max_z":-0.5,"market_activity_intensity_min_z":-0.26}'::jsonb,
 'FROZEN_RESEARCH',false)
on conflict (strategy_id) do update set
 strategy_contract=excluded.strategy_contract,
 display_name=excluded.display_name,
 horizon_days=excluded.horizon_days,
 description=excluded.description,
 thresholds=excluded.thresholds,
 policy_state=excluded.policy_state,
 production_influence_enabled=false;

create table if not exists public.flow_research_horizon_snapshot_v1 (
  strategy_contract text not null,
  strategy_id text not null,
  horizon_days integer not null,
  signal_date date not null,
  universe_snapshot_date date,
  market_gate_state text not null,
  signal_state text not null,
  ranked_count integer not null default 0,
  eligible_count integer not null default 0,
  components jsonb not null default '[]'::jsonb,
  market_context jsonb not null default '{}'::jsonb,
  thresholds jsonb not null default '{}'::jsonb,
  captured_at timestamptz not null default now(),
  production_influence_enabled boolean not null default false,
  primary key (strategy_contract,strategy_id,signal_date)
);

create index if not exists flow_research_horizon_snapshot_date_idx
  on public.flow_research_horizon_snapshot_v1(signal_date desc,strategy_id);

create table if not exists public.flow_research_horizon_outcome_v1 (
  strategy_contract text not null,
  strategy_id text not null,
  horizon_days integer not null,
  signal_date date not null,
  target_date date,
  maturity_state text not null,
  component_count integer not null default 0,
  valid_component_count integer not null default 0,
  excluded_component_count integer not null default 0,
  coverage_pct numeric,
  mean_return_pct numeric,
  median_return_pct numeric,
  win_rate_pct numeric,
  mean_alpha_vs_ihsg_pct numeric,
  mean_alpha_vs_sector_pct numeric,
  mean_mfe_pct numeric,
  mean_mae_pct numeric,
  evaluated_at timestamptz not null default now(),
  production_influence_enabled boolean not null default false,
  primary key (strategy_contract,strategy_id,signal_date)
);

create index if not exists flow_research_horizon_outcome_state_idx
  on public.flow_research_horizon_outcome_v1(maturity_state,signal_date,strategy_id);

create or replace function public.flow_research_horizon_rankings_v1(p_as_of_date date default null)
returns table(
  strategy_contract text,
  strategy_id text,
  display_name text,
  horizon_days integer,
  as_of_date date,
  universe_snapshot_date date,
  research_rank integer,
  ticker text,
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
  production_influence_enabled boolean
)
language sql
stable
set search_path=''
as $function$
with chosen as (
  select coalesce(p_as_of_date,(select max(as_of_date) from public.flow_market_learning_panel_v4)) d
), udate as (
  select max(m.snapshot_date) d
  from public.flow_universe_capture_manifest_v1 m, chosen c
  where m.universe_contract='TOP_900_UNIVERSE_V1'
    and m.capture_state='CAPTURED' and m.selected_count=900
    and m.snapshot_date<=c.d
), u as (
  select s.* from public.flow_universe_snapshot_v1 s, udate d
  where s.universe_contract='TOP_900_UNIVERSE_V1'
    and s.snapshot_date=d.d and s.selected_top900 and s.universe_rank between 1 and 900
), m as (
  select p.* from public.flow_market_learning_panel_v4 p, chosen c
  where p.as_of_date=c.d and p.source_verified
), o as (
  select s.* from public.flow_official_stock_summary_core_v1 s, chosen c
  where s.trade_date=c.d
), ix_arr as (
  select array_agg(x.close order by x.trade_date desc) closes
  from (
    select i.trade_date,i.close
    from public.flow_official_index_summary i, chosen c
    where i.index_code='COMPOSITE' and i.source_verified and i.trade_date<=c.d
    order by i.trade_date desc limit 21
  ) x
), market_ctx as (
  select c.d,
    case when cardinality(i.closes)>=6 and i.closes[6]<>0 then 100.0*(i.closes[1]/i.closes[6]-1) end r5,
    case when cardinality(i.closes)>=21 and i.closes[21]<>0 then 100.0*(i.closes[1]/i.closes[21]-1) end r20,
    (select max(top10_value_share_pct) from m) top10_share,
    (select max(market_activity_intensity_z) from m) market_activity
  from chosen c cross join ix_arr i
), fin as (
  select f.* from chosen c cross join lateral public.flow_financial_shadow_snapshot_v6(c.d) f
), base as (
  select c.d as as_of_date,ud.d as universe_snapshot_date,
    u.ticker,coalesce(o.stock_name,m.stock_name,u.issuer_name) stock_name,
    coalesce(m.sector,u.sector) sector,u.universe_rank,u.current_tradeable,u.production_actionable,
    o.close,o.traded_value,m.foreign_net_volume_pct,m.stock_residual_activity_z,
    f.balance_score as fin_balance_score,coalesce(m.risk_event_20d_count,0) risk_event_20d_count,
    coalesce(m.capital_action_90d_count,0) capital_action_90d_count,
    mc.r5,mc.r20,mc.top10_share,mc.market_activity
  from u
  cross join chosen c cross join udate ud cross join market_ctx mc
  left join m on m.ticker=u.ticker
  left join o on o.ticker=u.ticker
  left join fin f on f.ticker=u.ticker and f.financial_state='AVAILABLE'
), raw as (
  select 'RESEARCH_HORIZON_STRATEGIES_V1_1'::text contract,'BRFE_5'::text strategy_id,
    'BRFE-5 · Bull-Regime Foreign Expansion'::text display_name,5 horizon_days,b.*,
    case when b.r5>0 and b.r20>0 then 'BULL' else 'OFF_IHSG_TREND' end gate,
    case
      when not (b.r5>0 and b.r20>0) then 'WAIT_MARKET_GATE'
      when b.current_tradeable and b.close is not null and b.traded_value>=1000000000
        and b.foreign_net_volume_pct>=15 and b.risk_event_20d_count=0 and b.capital_action_90d_count=0 then 'ACTIVE'
      else 'FILTERED' end state,
    least(100::numeric,
      (case when b.current_tradeable then 20 else 0 end)+
      (case when b.traded_value>=1000000000 then 20 else 0 end)+
      (case when b.foreign_net_volume_pct>=15 then 20 else 0 end)+
      (case when b.risk_event_20d_count=0 then 15 else 0 end)+
      (case when b.capital_action_90d_count=0 then 15 else 0 end)+
      greatest(0::numeric,least(10::numeric,coalesce((b.foreign_net_volume_pct-15)/1.5,0)))
    ) score
  from base b
  union all
  select 'RESEARCH_HORIZON_STRATEGIES_V1_1','BPL_20','BPL-20 · Broad Participation Liquid',20,b.*,
    case when b.top10_share<=59.5 then 'BROAD_PARTICIPATION' else 'OFF_CONCENTRATED' end,
    case
      when not (b.top10_share<=59.5) then 'WAIT_MARKET_GATE'
      when b.current_tradeable and b.close is not null and b.traded_value>=1000000000 then 'ACTIVE'
      else 'FILTERED' end,
    least(100::numeric,
      (case when b.current_tradeable then 40 else 0 end)+
      (case when b.traded_value>=1000000000 then 40 else 0 end)+
      20.0*(1.0-least(900,greatest(1,b.universe_rank))/900.0)
    )
  from base b
  union all
  select 'RESEARCH_HORIZON_STRATEGIES_V1_1','QBA_60','QBA-60 · Quiet Balance Accumulation',60,b.*,
    case when b.market_activity>-0.26 then 'MARKET_OK' else 'OFF_MARKET_ACTIVITY' end,
    case
      when not (b.market_activity>-0.26) then 'WAIT_MARKET_GATE'
      when b.current_tradeable and b.close is not null and b.fin_balance_score>=80 and b.stock_residual_activity_z<=-0.5 then 'ACTIVE'
      else 'FILTERED' end,
    least(100::numeric,
      (case when b.current_tradeable then 20 else 0 end)+
      (case when b.fin_balance_score>=80 then 30 else 0 end)+
      greatest(0::numeric,least(25::numeric,coalesce((b.fin_balance_score-80)*1.25,0)))+
      (case when b.stock_residual_activity_z<=-0.5 then 15 else 0 end)+
      greatest(0::numeric,least(10::numeric,coalesce((-0.5-b.stock_residual_activity_z)*10,0)))
    )
  from base b
), ranked as (
  select r.*,row_number() over(partition by r.strategy_id order by (r.state='ACTIVE') desc,r.score desc,r.universe_rank,r.ticker) rn
  from raw r
)
select contract,strategy_id,display_name,horizon_days,as_of_date,universe_snapshot_date,rn::int,ticker,stock_name,sector,
 universe_rank,current_tradeable,production_actionable,close,traded_value,foreign_net_volume_pct,stock_residual_activity_z,
 fin_balance_score,risk_event_20d_count,capital_action_90d_count,r5,r20,top10_share,market_activity,gate,state,score,false
from ranked
order by horizon_days,rn;
$function$;

create or replace function public.flow_capture_research_horizon_signals_v1(p_signal_date date default null)
returns jsonb
language plpgsql
set search_path=''
as $function$
declare
  v_date date;
  v_rows integer;
begin
  select coalesce(p_signal_date,max(as_of_date)) into v_date from public.flow_market_learning_panel_v4;
  if v_date is null then
    return jsonb_build_object('status','SOURCE_NOT_READY','reason','NO_MARKET_PANEL');
  end if;
  if not exists(select 1 from public.flow_market_learning_panel_v4 where as_of_date=v_date) then
    return jsonb_build_object('status','SOURCE_NOT_READY','signal_date',v_date,'reason','MARKET_PANEL_MISSING');
  end if;

  with r as (
    select * from public.flow_research_horizon_rankings_v1(v_date)
  ), agg as (
    select strategy_contract,strategy_id,horizon_days,as_of_date,universe_snapshot_date,
      max(market_gate_state) market_gate_state,
      count(*) ranked_count,
      count(*) filter(where signal_state='ACTIVE') eligible_count,
      coalesce(jsonb_agg(jsonb_build_object(
        'ticker',ticker,'rank',research_rank,'close',close,'score',research_priority_score,
        'traded_value',traded_value,'foreign_net_volume_pct',foreign_net_volume_pct,
        'stock_residual_activity_z',stock_residual_activity_z,'fin_balance_score',fin_balance_score
      ) order by research_rank) filter(where signal_state='ACTIVE'),'[]'::jsonb) components,
      jsonb_build_object(
        'ihsg_return_5d_pct',max(ihsg_return_5d_pct),'ihsg_return_20d_pct',max(ihsg_return_20d_pct),
        'top10_value_share_pct',max(top10_value_share_pct),'market_activity_intensity_z',max(market_activity_intensity_z)
      ) market_context
    from r group by strategy_contract,strategy_id,horizon_days,as_of_date,universe_snapshot_date
  )
  insert into public.flow_research_horizon_snapshot_v1(
    strategy_contract,strategy_id,horizon_days,signal_date,universe_snapshot_date,market_gate_state,signal_state,
    ranked_count,eligible_count,components,market_context,thresholds,captured_at,production_influence_enabled
  )
  select a.strategy_contract,a.strategy_id,a.horizon_days,a.as_of_date,a.universe_snapshot_date,a.market_gate_state,
    case when a.eligible_count>0 then 'ACTIVE' when a.market_gate_state like 'OFF_%' then 'WAIT_MARKET_GATE' else 'NO_CANDIDATES' end,
    a.ranked_count,a.eligible_count,a.components,a.market_context,p.thresholds,now(),false
  from agg a join public.flow_research_horizon_policy_v1 p on p.strategy_id=a.strategy_id
  on conflict(strategy_contract,strategy_id,signal_date) do update set
    universe_snapshot_date=excluded.universe_snapshot_date,market_gate_state=excluded.market_gate_state,signal_state=excluded.signal_state,
    ranked_count=excluded.ranked_count,eligible_count=excluded.eligible_count,components=excluded.components,
    market_context=excluded.market_context,thresholds=excluded.thresholds,captured_at=excluded.captured_at,production_influence_enabled=false;
  get diagnostics v_rows=row_count;
  return jsonb_build_object('status','CAPTURED','signal_date',v_date,'strategy_rows',v_rows,'production_influence_enabled',false);
end;
$function$;

create or replace function public.flow_refresh_research_horizon_outcomes_v1()
returns jsonb
language plpgsql
set search_path=''
as $function$
declare v_rows integer;
begin
  with active as (
    select s.*,c.elem
    from public.flow_research_horizon_snapshot_v1 s
    cross join lateral jsonb_array_elements(s.components) c(elem)
    where s.signal_state='ACTIVE' and s.production_influence_enabled=false
  ), joined as (
    select a.strategy_contract,a.strategy_id,a.horizon_days,a.signal_date,a.eligible_count,
      a.elem->>'ticker' ticker,l.*,
      case a.horizon_days when 5 then l.target_date_5d when 20 then l.target_date_20d when 60 then l.target_date_60d end target_d,
      case a.horizon_days when 5 then l.clean_forward_return_5d_pct when 20 then l.clean_forward_return_20d_pct when 60 then l.clean_forward_return_60d_pct end ret,
      case a.horizon_days when 5 then l.clean_alpha_vs_ihsg_5d_pct when 20 then l.clean_alpha_vs_ihsg_20d_pct when 60 then l.clean_alpha_vs_ihsg_60d_pct end alpha_i,
      case a.horizon_days when 5 then l.clean_alpha_vs_sector_5d_pct when 20 then l.clean_alpha_vs_sector_20d_pct when 60 then l.clean_alpha_vs_sector_60d_pct end alpha_s,
      case a.horizon_days when 5 then l.clean_mfe_5d_pct when 20 then l.clean_mfe_20d_pct when 60 then l.clean_mfe_60d_pct end mfe,
      case a.horizon_days when 5 then l.clean_mae_5d_pct when 20 then l.clean_mae_20d_pct when 60 then l.clean_mae_60d_pct end mae
    from active a
    left join public.flow_market_learning_labels_clean_v4c l on l.as_of_date=a.signal_date and l.ticker=a.elem->>'ticker'
  ), agg as (
    select strategy_contract,strategy_id,horizon_days,signal_date,max(eligible_count) component_count,
      max(target_d) target_date,count(*) filter(where ret is not null) valid_count,
      count(*) filter(where target_d is not null) target_seen,
      avg(ret) mean_ret,percentile_cont(0.5) within group(order by ret) filter(where ret is not null) median_ret,
      100.0*avg(case when ret>0 then 1.0 else 0.0 end) filter(where ret is not null) win_rate,
      avg(alpha_i) filter(where ret is not null) mean_alpha_i,avg(alpha_s) filter(where ret is not null) mean_alpha_s,
      avg(mfe) filter(where ret is not null) mean_mfe,avg(mae) filter(where ret is not null) mean_mae
    from joined group by strategy_contract,strategy_id,horizon_days,signal_date
  )
  insert into public.flow_research_horizon_outcome_v1(
    strategy_contract,strategy_id,horizon_days,signal_date,target_date,maturity_state,component_count,valid_component_count,
    excluded_component_count,coverage_pct,mean_return_pct,median_return_pct,win_rate_pct,mean_alpha_vs_ihsg_pct,
    mean_alpha_vs_sector_pct,mean_mfe_pct,mean_mae_pct,evaluated_at,production_influence_enabled
  )
  select strategy_contract,strategy_id,horizon_days,signal_date,target_date,
    case when target_seen<component_count then 'SOURCE_NOT_READY'
         when valid_count=component_count then 'MATURE_CLEAN'
         when valid_count>0 then 'MATURE_WITH_EXCLUSIONS'
         else 'MATURE_NO_CLEAN_COMPONENTS' end,
    component_count,valid_count,greatest(component_count-valid_count,0),
    case when component_count>0 then 100.0*valid_count/component_count end,
    mean_ret,median_ret,win_rate,mean_alpha_i,mean_alpha_s,mean_mfe,mean_mae,now(),false
  from agg
  on conflict(strategy_contract,strategy_id,signal_date) do update set
    target_date=excluded.target_date,maturity_state=excluded.maturity_state,component_count=excluded.component_count,
    valid_component_count=excluded.valid_component_count,excluded_component_count=excluded.excluded_component_count,
    coverage_pct=excluded.coverage_pct,mean_return_pct=excluded.mean_return_pct,median_return_pct=excluded.median_return_pct,
    win_rate_pct=excluded.win_rate_pct,mean_alpha_vs_ihsg_pct=excluded.mean_alpha_vs_ihsg_pct,
    mean_alpha_vs_sector_pct=excluded.mean_alpha_vs_sector_pct,mean_mfe_pct=excluded.mean_mfe_pct,mean_mae_pct=excluded.mean_mae_pct,
    evaluated_at=excluded.evaluated_at,production_influence_enabled=false;
  get diagnostics v_rows=row_count;
  return jsonb_build_object('status','REFRESHED','outcome_rows',v_rows,'production_influence_enabled',false);
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
  v_outcomes jsonb;
begin
  select max(as_of_date) into v_latest from public.flow_market_learning_panel_v4;
  v_outcomes := public.flow_refresh_research_horizon_outcomes_v1();
  if v_latest is distinct from v_today then
    return jsonb_build_object('status','SOURCE_NOT_READY','jakarta_date',v_today,'latest_market_date',v_latest,'outcomes',v_outcomes);
  end if;
  v_capture := public.flow_capture_research_horizon_signals_v1(v_today);
  return jsonb_build_object('status','OK','signal_date',v_today,'capture',v_capture,'outcomes',v_outcomes,'production_influence_enabled',false);
end;
$function$;

do $do$
declare j bigint;
begin
  for j in select jobid from cron.job where jobname in ('flow-research-horizon-capture-v1','flow-research-horizon-retry-v1') loop
    perform cron.unschedule(j);
  end loop;
  perform cron.schedule('flow-research-horizon-capture-v1','55 11 * * 1-5','select public.flow_run_research_horizon_daily_v1();');
  perform cron.schedule('flow-research-horizon-retry-v1','25 12 * * 1-5','select public.flow_run_research_horizon_daily_v1();');
end;
$do$;

comment on function public.flow_research_horizon_rankings_v1(date) is 'Research-only current ranking for BRFE-5, BPL-20, and QBA-60. Never affects production scoring.';
comment on table public.flow_research_horizon_snapshot_v1 is 'Compact frozen research-only strategy basket snapshots for prospective forward validation.';
comment on table public.flow_research_horizon_outcome_v1 is 'Clean prospective OOS outcomes for frozen research horizon strategies; production influence always false.';
