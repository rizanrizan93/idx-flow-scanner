-- Phase 3B runtime hotfix: PostgreSQL percent_rank() returns double precision.
-- Cast it explicitly to numeric before round(..., 2).
-- No scoring semantics or Phase 3B weights are changed.

create or replace function public.flow_refresh_ticker_affinity_consensus_v3(
  p_as_of_date date default ((now() at time zone 'Asia/Jakarta')::date)
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  phase3a_state text;
  phase3a_date date;
  active_n integer := 0;
  active_share numeric := 0;
  affinity_rows_n integer := 0;
  inserted_n integer := 0;
  broad_n integer := 0;
  strong_n integer := 0;
  moderate_n integer := 0;
  weak_n integer := 0;
  max_brokers integer := 0;
  max_weighted_breadth numeric := 0;
  max_proxy numeric := 0;
begin
  select phase3a_gate_state,as_of_date
    into phase3a_state,phase3a_date
  from public.flow_phase3a_quality_summary;

  if phase3a_state is distinct from 'PHASE3A_READY' then
    raise exception 'Phase3B requires PHASE3A_READY, got %',coalesce(phase3a_state,'NULL');
  end if;
  if phase3a_date is distinct from p_as_of_date then
    return jsonb_build_object(
      'as_of_date',p_as_of_date,
      'status','PHASE3A_AS_OF_MISMATCH',
      'phase3a_as_of_date',phase3a_date
    );
  end if;

  select count(*)::integer,coalesce(sum(activity_share_pct),0)::numeric
    into active_n,active_share
  from public.flow_broker_behavior_features_v2
  where trade_date=p_as_of_date
    and feature_quality_state='MATURE'
    and source_verified
    and residual_activity_z>=1.5;

  if active_n < 5 or active_share<=0 then
    return jsonb_build_object(
      'as_of_date',p_as_of_date,
      'status','INSUFFICIENT_ACTIVE_BROKER_COHORT',
      'active_brokers',active_n,
      'active_activity_share_pct',active_share
    );
  end if;

  select count(*)::integer into affinity_rows_n
  from public.flow_broker_ticker_affinity_v3
  where as_of_date=p_as_of_date
    and source_verified;

  delete from public.flow_ticker_affinity_consensus_v3 where as_of_date=p_as_of_date;
  delete from public.flow_ticker_affinity_consensus_snapshot_v3 where as_of_date=p_as_of_date;

  with active as (
    select broker_code,residual_activity_z,activity_share_pct
    from public.flow_broker_behavior_features_v2
    where trade_date=p_as_of_date
      and feature_quality_state='MATURE'
      and source_verified
      and residual_activity_z>=1.5
  ), affinity as (
    select broker_code,ticker,lag_sessions,stability_state,research_affinity_score
    from public.flow_broker_ticker_affinity_v3
    where as_of_date=p_as_of_date
      and source_verified
      and association_semantics='CO_ACTIVITY_AFFINITY_NOT_BUY_SELL'
      and stability_state in ('STABLE','RECENT_STRENGTHENING')
  ), pair_agg as (
    select
      a.broker_code,
      a.ticker,
      count(distinct a.lag_sessions)::integer lag_count,
      count(*) filter(where a.stability_state='STABLE')::integer stable_lag_count,
      count(*) filter(where a.stability_state='RECENT_STRENGTHENING')::integer recent_lag_count,
      bool_or(a.lag_sessions=0) lag0,
      bool_or(a.lag_sessions=1) lag1,
      bool_or(a.lag_sessions=2) lag2,
      bool_or(a.lag_sessions=5) lag5,
      max(a.research_affinity_score)::numeric best_affinity_score,
      avg(a.research_affinity_score)::numeric mean_pair_affinity_score
    from affinity a
    join active x using(broker_code)
    group by a.broker_code,a.ticker
  ), ticker_agg as (
    select
      p.ticker,
      count(*)::integer matched_brokers,
      count(*) filter(where p.stable_lag_count>0)::integer stable_brokers,
      count(*) filter(where p.recent_lag_count>0)::integer recent_brokers,
      count(*) filter(where p.lag_count>=2)::integer multi_lag_brokers,
      count(*) filter(where p.lag0)::integer lag0_brokers,
      count(*) filter(where p.lag1)::integer lag1_brokers,
      count(*) filter(where p.lag2)::integer lag2_brokers,
      count(*) filter(where p.lag5)::integer lag5_brokers,
      sum(x.activity_share_pct)::numeric matched_activity_share,
      coalesce(
        sum(x.activity_share_pct*p.best_affinity_score)/nullif(sum(x.activity_share_pct),0),
        avg(p.best_affinity_score)
      )::numeric weighted_affinity,
      avg(p.best_affinity_score)::numeric mean_affinity
    from pair_agg p
    join active x using(broker_code)
    group by p.ticker
  ), metrics as (
    select
      t.*,
      100::numeric*t.matched_brokers/active_n::numeric raw_breadth,
      100::numeric*t.matched_activity_share/nullif(active_share,0) weighted_breadth,
      100::numeric*t.multi_lag_brokers/nullif(t.matched_brokers,0) multi_lag_pct,
      100::numeric*t.stable_brokers/nullif(t.matched_brokers,0) stable_pct
    from ticker_agg t
  ), scored as (
    select
      m.*,
      greatest(0::numeric,least(100::numeric,100::numeric*m.raw_breadth/40::numeric)) breadth_component,
      greatest(0::numeric,least(100::numeric,100::numeric*m.weighted_breadth/35::numeric)) weighted_breadth_component,
      case
        when m.raw_breadth>=25 then 'BROAD'
        when m.raw_breadth>=15 then 'STRONG'
        when m.raw_breadth>=8 then 'MODERATE'
        else 'WEAK'
      end breadth_state,
      greatest(0::numeric,least(100::numeric,
        0.30*greatest(0::numeric,least(100::numeric,100::numeric*m.raw_breadth/40::numeric))
        +0.25*greatest(0::numeric,least(100::numeric,100::numeric*m.weighted_breadth/35::numeric))
        +0.20*m.weighted_affinity
        +0.15*m.multi_lag_pct
        +0.10*m.stable_pct
      )) proxy_score
    from metrics m
  )
  insert into public.flow_ticker_affinity_consensus_v3 (
    as_of_date,ticker,active_broker_count,active_broker_activity_share_pct,
    affinity_active_broker_count,stable_affinity_broker_count,recent_strengthening_broker_count,
    multi_lag_broker_count,lag0_broker_count,lag1_broker_count,lag2_broker_count,lag5_broker_count,
    raw_affinity_breadth_pct,activity_weighted_breadth_pct,weighted_affinity_score,mean_affinity_score,
    multi_lag_confirmation_pct,stable_confirmation_pct,breadth_state,broker_consensus_proxy_score,
    stock_residual_activity_z,turnover_residual_z,volume_residual_z,frequency_residual_z,
    foreign_net_volume_pct,return_pct,stock_residual_quality_state,computed_at
  )
  select
    p_as_of_date,s.ticker,active_n,active_share,
    s.matched_brokers,s.stable_brokers,s.recent_brokers,s.multi_lag_brokers,
    s.lag0_brokers,s.lag1_brokers,s.lag2_brokers,s.lag5_brokers,
    s.raw_breadth,s.weighted_breadth,s.weighted_affinity,s.mean_affinity,
    s.multi_lag_pct,s.stable_pct,s.breadth_state,s.proxy_score,
    r.stock_residual_activity_z,r.turnover_residual_z,r.volume_residual_z,r.frequency_residual_z,
    r.foreign_net_volume_pct,r.return_pct,r.residual_quality_state,now()
  from scored s
  left join public.flow_stock_residual_activity_v2 r
    on r.trade_date=p_as_of_date and r.ticker=s.ticker and r.source_verified;

  get diagnostics inserted_n=row_count;

  with ranked as (
    select ticker,
           round((100::numeric*(percent_rank() over(order by broker_consensus_proxy_score))::numeric),2) rank_pct
    from public.flow_ticker_affinity_consensus_v3
    where as_of_date=p_as_of_date
  )
  update public.flow_ticker_affinity_consensus_v3 c
  set consensus_rank_pct=r.rank_pct
  from ranked r
  where c.as_of_date=p_as_of_date and c.ticker=r.ticker;

  select
    count(*) filter(where breadth_state='BROAD')::integer,
    count(*) filter(where breadth_state='STRONG')::integer,
    count(*) filter(where breadth_state='MODERATE')::integer,
    count(*) filter(where breadth_state='WEAK')::integer,
    coalesce(max(affinity_active_broker_count),0)::integer,
    coalesce(max(activity_weighted_breadth_pct),0)::numeric,
    coalesce(max(broker_consensus_proxy_score),0)::numeric
  into broad_n,strong_n,moderate_n,weak_n,max_brokers,max_weighted_breadth,max_proxy
  from public.flow_ticker_affinity_consensus_v3
  where as_of_date=p_as_of_date;

  insert into public.flow_ticker_affinity_consensus_snapshot_v3 (
    as_of_date,phase3a_affinity_rows,active_broker_count,active_broker_activity_share_pct,
    consensus_ticker_count,broad_ticker_count,strong_ticker_count,moderate_ticker_count,weak_ticker_count,
    max_affinity_active_brokers,max_activity_weighted_breadth_pct,max_broker_consensus_proxy_score,
    computed_at
  ) values (
    p_as_of_date,affinity_rows_n,active_n,active_share,
    inserted_n,broad_n,strong_n,moderate_n,weak_n,
    max_brokers,max_weighted_breadth,max_proxy,now()
  );

  insert into public.flow_ingestion_audit (
    provider,dataset,started_at,completed_at,status,rows_received,rows_accepted,
    rows_rejected,freshness_date,details
  ) values (
    'IDX_OFFICIAL_DERIVED','TICKER_AFFINITY_CONSENSUS_V3_SHADOW',now(),now(),'OK',
    affinity_rows_n,inserted_n,0,p_as_of_date,
    jsonb_build_object(
      'phase','PHASE3B_TICKER_AFFINITY_CONSENSUS',
      'as_of_date',p_as_of_date,
      'active_brokers',active_n,
      'active_activity_share_pct',active_share,
      'consensus_tickers',inserted_n,
      'broad_tickers',broad_n,
      'strong_tickers',strong_n,
      'association_semantics','CO_ACTIVITY_AFFINITY_NOT_BUY_SELL',
      'foreign_and_stock_fields_confirmation_only',true,
      'no_production_scoring_change',true
    )
  );

  return jsonb_build_object(
    'as_of_date',p_as_of_date,
    'status','OK',
    'active_brokers',active_n,
    'active_activity_share_pct',active_share,
    'consensus_tickers',inserted_n,
    'broad_tickers',broad_n,
    'strong_tickers',strong_n,
    'max_affinity_active_brokers',max_brokers,
    'max_activity_weighted_breadth_pct',max_weighted_breadth,
    'max_broker_consensus_proxy_score',max_proxy,
    'association_semantics','CO_ACTIVITY_AFFINITY_NOT_BUY_SELL'
  );
end;
$$;

revoke all on function public.flow_refresh_ticker_affinity_consensus_v3(date)
  from public, anon, authenticated;
grant execute on function public.flow_refresh_ticker_affinity_consensus_v3(date)
  to service_role;
