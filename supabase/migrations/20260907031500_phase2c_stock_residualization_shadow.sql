-- Phase 2C: stock residual-activity foundation for future broker-ticker affinity.
-- Shadow research only. No production scoring or execution behavior changes.

create or replace function public.flow_robust_z_from_stats(
  p_value numeric,
  p_median numeric,
  p_mad numeric,
  p_stddev numeric
)
returns numeric
language sql
immutable
set search_path = pg_catalog, public
as $$
select case
  when p_value is null or p_median is null then null
  else greatest(
    -8::numeric,
    least(
      8::numeric,
      (p_value-p_median) /
      coalesce(
        nullif(1.4826::numeric*p_mad,0),
        nullif(p_stddev,0),
        greatest(abs(p_median)*0.05::numeric,0.01::numeric)
      )
    )
  )
end;
$$;

revoke all on function public.flow_robust_z_from_stats(numeric,numeric,numeric,numeric)
  from public, anon, authenticated;
grant execute on function public.flow_robust_z_from_stats(numeric,numeric,numeric,numeric)
  to service_role;

create table if not exists public.flow_stock_residual_activity_v2 (
  trade_date date not null,
  ticker text not null,
  sector text,
  subsector text,
  previous numeric,
  close numeric,
  high numeric,
  low numeric,
  traded_value numeric not null default 0,
  volume numeric not null default 0,
  frequency numeric not null default 0,
  foreign_buy numeric not null default 0,
  foreign_sell numeric not null default 0,
  foreign_net numeric not null default 0,
  return_pct numeric,
  volatility_range_pct numeric,
  volatility_bucket integer,
  market_turnover_share_pct numeric,
  sector_turnover_share_pct numeric,
  foreign_net_volume_pct numeric,
  peer_group_size integer not null default 0,
  turnover_residual_z numeric,
  volume_residual_z numeric,
  frequency_residual_z numeric,
  stock_residual_activity_z numeric,
  residual_quality_state text not null,
  residualization_basis text not null default 'DAILY_SECTOR_X_VOLATILITY_QUINTILE_ROBUST_LOG_ACTIVITY',
  source text not null default 'DERIVED_IDX_OFFICIAL_STOCK_RESIDUAL_V2',
  source_verified boolean not null default true,
  source_dataset text not null default 'flow_official_stock_summary',
  provenance_state text not null default 'SHADOW_DERIVED_FROM_VERIFIED_OFFICIAL_IDX_STOCK_SUMMARY',
  computed_at timestamptz not null default now(),
  primary key (trade_date,ticker),
  constraint flow_stock_residual_activity_v2_quality_ck
    check (residual_quality_state in ('FULL','SECTOR_FALLBACK','MARKET_FALLBACK')),
  constraint flow_stock_residual_activity_v2_bucket_ck
    check (volatility_bucket between 1 and 5),
  constraint flow_stock_residual_activity_v2_nonnegative_ck
    check (peer_group_size >= 1 and traded_value >= 0 and volume >= 0 and frequency >= 0)
);

create index if not exists flow_stock_residual_activity_v2_ticker_date_idx
  on public.flow_stock_residual_activity_v2 (ticker,trade_date desc);
create index if not exists flow_stock_residual_activity_v2_date_quality_idx
  on public.flow_stock_residual_activity_v2 (trade_date desc,residual_quality_state);
create index if not exists flow_stock_residual_activity_v2_sector_date_idx
  on public.flow_stock_residual_activity_v2 (sector,trade_date desc);

alter table public.flow_stock_residual_activity_v2 enable row level security;
revoke all on table public.flow_stock_residual_activity_v2 from public, anon, authenticated;
grant select,insert,update,delete on table public.flow_stock_residual_activity_v2 to service_role;

create or replace function public.flow_refresh_stock_residual_activity_v2(
  p_date date default ((now() at time zone 'Asia/Jakarta')::date)
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  raw_rows integer := 0;
  unverified_rows integer := 0;
  bad_url_rows integer := 0;
  invalid_metric_rows integer := 0;
  inserted_rows integer := 0;
  full_rows integer := 0;
  sector_fallback_rows integer := 0;
  market_fallback_rows integer := 0;
begin
  select
    count(*)::integer,
    count(*) filter (where not source_verified)::integer,
    count(*) filter (where source_url is null or source_url not like 'https://block.idx.id/%')::integer,
    count(*) filter (
      where traded_value<0 or volume<0 or frequency<0
         or previous is null or previous<=0 or high is null or low is null
    )::integer
  into raw_rows,unverified_rows,bad_url_rows,invalid_metric_rows
  from public.flow_official_stock_summary
  where trade_date=p_date and source='IDX_OFFICIAL_STOCK_SUMMARY';

  if raw_rows=0 then
    return jsonb_build_object('trade_date',p_date,'status','NO_OFFICIAL_STOCK_SESSION');
  end if;
  if raw_rows<800 then
    raise exception 'Phase2C official stock session unexpectedly small for %: % rows',p_date,raw_rows;
  end if;
  if unverified_rows>0 or bad_url_rows>0 or invalid_metric_rows>0 then
    raise exception 'Phase2C invalid official stock session %: unverified %, bad_url %, invalid_metrics %',
      p_date,unverified_rows,bad_url_rows,invalid_metric_rows;
  end if;

  delete from public.flow_stock_residual_activity_v2 where trade_date=p_date;

  with base0 as (
    select
      s.trade_date,
      s.ticker,
      i.sector,
      i.subsector,
      s.previous,
      s.close,
      s.high,
      s.low,
      s.traded_value,
      s.volume,
      s.frequency,
      s.foreign_buy,
      s.foreign_sell,
      (s.foreign_buy-s.foreign_sell)::numeric as foreign_net,
      100::numeric*(s.close-s.previous)/nullif(s.previous,0) as return_pct,
      100::numeric*(s.high-s.low)/nullif(s.previous,0) as volatility_range_pct,
      ln(1::numeric+s.traded_value) as log_value,
      ln(1::numeric+s.volume) as log_volume,
      ln(1::numeric+s.frequency) as log_frequency,
      sum(s.traded_value) over () as market_total_value,
      sum(s.traded_value) over (partition by i.sector) as sector_total_value
    from public.flow_official_stock_summary s
    left join public.flow_issuers i on i.ticker=s.ticker
    where s.trade_date=p_date
      and s.source='IDX_OFFICIAL_STOCK_SUMMARY'
      and s.source_verified
  ), bucketed as (
    select
      b.*,
      ntile(5) over(order by b.volatility_range_pct,b.ticker)::integer as volatility_bucket
    from base0 b
  ), market_center as (
    select
      count(*)::integer n,
      percentile_cont(0.5) within group(order by log_value)::numeric med_value,
      percentile_cont(0.5) within group(order by log_volume)::numeric med_volume,
      percentile_cont(0.5) within group(order by log_frequency)::numeric med_frequency,
      stddev_pop(log_value)::numeric sd_value,
      stddev_pop(log_volume)::numeric sd_volume,
      stddev_pop(log_frequency)::numeric sd_frequency
    from bucketed
  ), market_stats as (
    select
      c.*,
      percentile_cont(0.5) within group(order by abs(b.log_value-c.med_value))::numeric mad_value,
      percentile_cont(0.5) within group(order by abs(b.log_volume-c.med_volume))::numeric mad_volume,
      percentile_cont(0.5) within group(order by abs(b.log_frequency-c.med_frequency))::numeric mad_frequency
    from bucketed b cross join market_center c
    group by c.n,c.med_value,c.med_volume,c.med_frequency,c.sd_value,c.sd_volume,c.sd_frequency
  ), sector_center as (
    select
      sector,
      count(*)::integer n,
      percentile_cont(0.5) within group(order by log_value)::numeric med_value,
      percentile_cont(0.5) within group(order by log_volume)::numeric med_volume,
      percentile_cont(0.5) within group(order by log_frequency)::numeric med_frequency,
      stddev_pop(log_value)::numeric sd_value,
      stddev_pop(log_volume)::numeric sd_volume,
      stddev_pop(log_frequency)::numeric sd_frequency
    from bucketed
    where sector is not null and trim(sector)<>''
    group by sector
  ), sector_stats as (
    select
      c.sector,c.n,c.med_value,c.med_volume,c.med_frequency,c.sd_value,c.sd_volume,c.sd_frequency,
      percentile_cont(0.5) within group(order by abs(b.log_value-c.med_value))::numeric mad_value,
      percentile_cont(0.5) within group(order by abs(b.log_volume-c.med_volume))::numeric mad_volume,
      percentile_cont(0.5) within group(order by abs(b.log_frequency-c.med_frequency))::numeric mad_frequency
    from sector_center c
    join bucketed b on b.sector=c.sector
    group by c.sector,c.n,c.med_value,c.med_volume,c.med_frequency,c.sd_value,c.sd_volume,c.sd_frequency
  ), bucket_center as (
    select
      sector,volatility_bucket,
      count(*)::integer n,
      percentile_cont(0.5) within group(order by log_value)::numeric med_value,
      percentile_cont(0.5) within group(order by log_volume)::numeric med_volume,
      percentile_cont(0.5) within group(order by log_frequency)::numeric med_frequency,
      stddev_pop(log_value)::numeric sd_value,
      stddev_pop(log_volume)::numeric sd_volume,
      stddev_pop(log_frequency)::numeric sd_frequency
    from bucketed
    where sector is not null and trim(sector)<>''
    group by sector,volatility_bucket
  ), bucket_stats as (
    select
      c.sector,c.volatility_bucket,c.n,c.med_value,c.med_volume,c.med_frequency,
      c.sd_value,c.sd_volume,c.sd_frequency,
      percentile_cont(0.5) within group(order by abs(b.log_value-c.med_value))::numeric mad_value,
      percentile_cont(0.5) within group(order by abs(b.log_volume-c.med_volume))::numeric mad_volume,
      percentile_cont(0.5) within group(order by abs(b.log_frequency-c.med_frequency))::numeric mad_frequency
    from bucket_center c
    join bucketed b on b.sector=c.sector and b.volatility_bucket=c.volatility_bucket
    group by c.sector,c.volatility_bucket,c.n,c.med_value,c.med_volume,c.med_frequency,
             c.sd_value,c.sd_volume,c.sd_frequency
  ), joined as (
    select
      b.*,
      m.n market_n,m.med_value market_med_value,m.med_volume market_med_volume,
      m.med_frequency market_med_frequency,m.mad_value market_mad_value,
      m.mad_volume market_mad_volume,m.mad_frequency market_mad_frequency,
      m.sd_value market_sd_value,m.sd_volume market_sd_volume,m.sd_frequency market_sd_frequency,
      s.n sector_n,s.med_value sector_med_value,s.med_volume sector_med_volume,
      s.med_frequency sector_med_frequency,s.mad_value sector_mad_value,
      s.mad_volume sector_mad_volume,s.mad_frequency sector_mad_frequency,
      s.sd_value sector_sd_value,s.sd_volume sector_sd_volume,s.sd_frequency sector_sd_frequency,
      g.n bucket_n,g.med_value bucket_med_value,g.med_volume bucket_med_volume,
      g.med_frequency bucket_med_frequency,g.mad_value bucket_mad_value,
      g.mad_volume bucket_mad_volume,g.mad_frequency bucket_mad_frequency,
      g.sd_value bucket_sd_value,g.sd_volume bucket_sd_volume,g.sd_frequency bucket_sd_frequency
    from bucketed b
    cross join market_stats m
    left join sector_stats s on s.sector=b.sector
    left join bucket_stats g on g.sector=b.sector and g.volatility_bucket=b.volatility_bucket
  ), chosen as (
    select
      j.*,
      case
        when j.sector is not null and trim(j.sector)<>'' and coalesce(j.bucket_n,0)>=5 then 'FULL'
        when j.sector is not null and trim(j.sector)<>'' and coalesce(j.sector_n,0)>=5 then 'SECTOR_FALLBACK'
        else 'MARKET_FALLBACK'
      end as quality_state,
      case
        when j.sector is not null and trim(j.sector)<>'' and coalesce(j.bucket_n,0)>=5 then j.bucket_n
        when j.sector is not null and trim(j.sector)<>'' and coalesce(j.sector_n,0)>=5 then j.sector_n
        else j.market_n
      end as peer_n,
      case
        when j.sector is not null and trim(j.sector)<>'' and coalesce(j.bucket_n,0)>=5 then j.bucket_med_value
        when j.sector is not null and trim(j.sector)<>'' and coalesce(j.sector_n,0)>=5 then j.sector_med_value
        else j.market_med_value
      end med_value,
      case
        when j.sector is not null and trim(j.sector)<>'' and coalesce(j.bucket_n,0)>=5 then j.bucket_mad_value
        when j.sector is not null and trim(j.sector)<>'' and coalesce(j.sector_n,0)>=5 then j.sector_mad_value
        else j.market_mad_value
      end mad_value,
      case
        when j.sector is not null and trim(j.sector)<>'' and coalesce(j.bucket_n,0)>=5 then j.bucket_sd_value
        when j.sector is not null and trim(j.sector)<>'' and coalesce(j.sector_n,0)>=5 then j.sector_sd_value
        else j.market_sd_value
      end sd_value,
      case
        when j.sector is not null and trim(j.sector)<>'' and coalesce(j.bucket_n,0)>=5 then j.bucket_med_volume
        when j.sector is not null and trim(j.sector)<>'' and coalesce(j.sector_n,0)>=5 then j.sector_med_volume
        else j.market_med_volume
      end med_volume,
      case
        when j.sector is not null and trim(j.sector)<>'' and coalesce(j.bucket_n,0)>=5 then j.bucket_mad_volume
        when j.sector is not null and trim(j.sector)<>'' and coalesce(j.sector_n,0)>=5 then j.sector_mad_volume
        else j.market_mad_volume
      end mad_volume,
      case
        when j.sector is not null and trim(j.sector)<>'' and coalesce(j.bucket_n,0)>=5 then j.bucket_sd_volume
        when j.sector is not null and trim(j.sector)<>'' and coalesce(j.sector_n,0)>=5 then j.sector_sd_volume
        else j.market_sd_volume
      end sd_volume,
      case
        when j.sector is not null and trim(j.sector)<>'' and coalesce(j.bucket_n,0)>=5 then j.bucket_med_frequency
        when j.sector is not null and trim(j.sector)<>'' and coalesce(j.sector_n,0)>=5 then j.sector_med_frequency
        else j.market_med_frequency
      end med_frequency,
      case
        when j.sector is not null and trim(j.sector)<>'' and coalesce(j.bucket_n,0)>=5 then j.bucket_mad_frequency
        when j.sector is not null and trim(j.sector)<>'' and coalesce(j.sector_n,0)>=5 then j.sector_mad_frequency
        else j.market_mad_frequency
      end mad_frequency,
      case
        when j.sector is not null and trim(j.sector)<>'' and coalesce(j.bucket_n,0)>=5 then j.bucket_sd_frequency
        when j.sector is not null and trim(j.sector)<>'' and coalesce(j.sector_n,0)>=5 then j.sector_sd_frequency
        else j.market_sd_frequency
      end sd_frequency
    from joined j
  ), scored as (
    select
      c.*,
      public.flow_robust_z_from_stats(c.log_value,c.med_value,c.mad_value,c.sd_value) as turnover_z,
      public.flow_robust_z_from_stats(c.log_volume,c.med_volume,c.mad_volume,c.sd_volume) as volume_z,
      public.flow_robust_z_from_stats(c.log_frequency,c.med_frequency,c.mad_frequency,c.sd_frequency) as frequency_z
    from chosen c
  )
  insert into public.flow_stock_residual_activity_v2 (
    trade_date,ticker,sector,subsector,previous,close,high,low,
    traded_value,volume,frequency,foreign_buy,foreign_sell,foreign_net,
    return_pct,volatility_range_pct,volatility_bucket,
    market_turnover_share_pct,sector_turnover_share_pct,foreign_net_volume_pct,
    peer_group_size,turnover_residual_z,volume_residual_z,frequency_residual_z,
    stock_residual_activity_z,residual_quality_state,computed_at
  )
  select
    s.trade_date,s.ticker,s.sector,s.subsector,s.previous,s.close,s.high,s.low,
    s.traded_value,s.volume,s.frequency,s.foreign_buy,s.foreign_sell,s.foreign_net,
    s.return_pct,s.volatility_range_pct,s.volatility_bucket,
    100::numeric*s.traded_value/nullif(s.market_total_value,0),
    case when s.sector is null or trim(s.sector)='' then null
         else 100::numeric*s.traded_value/nullif(s.sector_total_value,0) end,
    case when s.volume<=0 then null else 100::numeric*s.foreign_net/s.volume end,
    s.peer_n,s.turnover_z,s.volume_z,s.frequency_z,s.turnover_z,s.quality_state,now()
  from scored s;

  get diagnostics inserted_rows=row_count;

  select
    count(*) filter (where residual_quality_state='FULL')::integer,
    count(*) filter (where residual_quality_state='SECTOR_FALLBACK')::integer,
    count(*) filter (where residual_quality_state='MARKET_FALLBACK')::integer
  into full_rows,sector_fallback_rows,market_fallback_rows
  from public.flow_stock_residual_activity_v2
  where trade_date=p_date;

  insert into public.flow_ingestion_audit (
    provider,dataset,started_at,completed_at,status,rows_received,rows_accepted,
    rows_rejected,freshness_date,details
  ) values (
    'IDX_OFFICIAL_DERIVED','STOCK_RESIDUAL_ACTIVITY_V2_SHADOW',now(),now(),'OK',
    raw_rows,inserted_rows,0,p_date,
    jsonb_build_object(
      'phase','PHASE2C_STOCK_RESIDUALIZATION_SHADOW',
      'full_rows',full_rows,
      'sector_fallback_rows',sector_fallback_rows,
      'market_fallback_rows',market_fallback_rows,
      'basis','DAILY_SECTOR_X_VOLATILITY_QUINTILE_ROBUST_LOG_ACTIVITY',
      'no_production_scoring_change',true
    )
  );

  return jsonb_build_object(
    'trade_date',p_date,
    'status','OK',
    'rows',inserted_rows,
    'full_rows',full_rows,
    'sector_fallback_rows',sector_fallback_rows,
    'market_fallback_rows',market_fallback_rows
  );
end;
$$;

revoke all on function public.flow_refresh_stock_residual_activity_v2(date)
  from public, anon, authenticated;
grant execute on function public.flow_refresh_stock_residual_activity_v2(date)
  to service_role;

create or replace function public.flow_backfill_stock_residual_activity_v2(
  p_start_date date,
  p_end_date date
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  d date;
  r jsonb;
  sessions integer := 0;
  rows_touched bigint := 0;
  failures integer := 0;
begin
  if p_start_date is null or p_end_date is null or p_start_date>p_end_date then
    raise exception 'invalid Phase2C backfill window: % to %',p_start_date,p_end_date;
  end if;
  if (p_end_date-p_start_date)>31 then
    raise exception 'Phase2C backfill window exceeds 31 calendar days: % to %',p_start_date,p_end_date;
  end if;

  for d in
    select distinct trade_date
    from public.flow_official_stock_summary
    where trade_date between p_start_date and p_end_date
      and source='IDX_OFFICIAL_STOCK_SUMMARY' and source_verified
    order by trade_date
  loop
    begin
      r := public.flow_refresh_stock_residual_activity_v2(d);
      sessions := sessions+1;
      rows_touched := rows_touched+coalesce((r->>'rows')::integer,0);
    exception when others then
      failures := failures+1;
      insert into public.flow_ingestion_audit (
        provider,dataset,started_at,completed_at,status,rows_received,rows_accepted,
        rows_rejected,freshness_date,error_code,details
      ) values (
        'IDX_OFFICIAL_DERIVED','STOCK_RESIDUAL_ACTIVITY_V2_SHADOW',now(),now(),'FAILED',0,0,0,d,
        sqlstate,jsonb_build_object('error',sqlerrm,'phase','PHASE2C_STOCK_RESIDUALIZATION_SHADOW')
      );
    end;
  end loop;

  return jsonb_build_object(
    'start_date',p_start_date,
    'end_date',p_end_date,
    'sessions_attempted',sessions+failures,
    'sessions_completed',sessions,
    'rows_touched',rows_touched,
    'failures',failures
  );
end;
$$;

revoke all on function public.flow_backfill_stock_residual_activity_v2(date,date)
  from public, anon, authenticated;
grant execute on function public.flow_backfill_stock_residual_activity_v2(date,date)
  to service_role;

create or replace view public.flow_phase2c_quality_summary as
with q as (
  select
    count(*)::bigint residual_rows,
    count(distinct trade_date)::integer residual_sessions,
    count(*) filter (where residual_quality_state='FULL')::bigint full_rows,
    count(*) filter (where residual_quality_state='SECTOR_FALLBACK')::bigint sector_fallback_rows,
    count(*) filter (where residual_quality_state='MARKET_FALLBACK')::bigint market_fallback_rows,
    count(*) filter (where stock_residual_activity_z is null or volume_residual_z is null or frequency_residual_z is null)::bigint null_residual_rows,
    count(*) filter (where not source_verified)::bigint unverified_rows,
    min(trade_date) first_residual_date,
    max(trade_date) last_residual_date
  from public.flow_stock_residual_activity_v2
), a as (
  select count(*) filter (where status='FAILED')::integer failed_audit_rows
  from public.flow_ingestion_audit
  where provider='IDX_OFFICIAL_DERIVED' and dataset='STOCK_RESIDUAL_ACTIVITY_V2_SHADOW'
)
select q.*,a.*,
  round(100::numeric*q.market_fallback_rows/nullif(q.residual_rows,0),4) market_fallback_pct,
  case
    when q.residual_sessions>=250
      and q.residual_rows>=240000
      and q.null_residual_rows=0
      and q.unverified_rows=0
      and 100::numeric*q.market_fallback_rows/nullif(q.residual_rows,0)<=1
      and a.failed_audit_rows=0
      then 'PHASE2C_READY'
    else 'PHASE2C_NOT_READY'
  end as phase2c_gate_state
from q cross join a;

revoke all on public.flow_phase2c_quality_summary from public, anon, authenticated;
grant select on public.flow_phase2c_quality_summary to service_role;

create or replace view public.flow_phase2_quality_summary as
select
  ab.phase2ab_gate_state,
  c.phase2c_gate_state,
  ab.feature_sessions,
  ab.ready_regime_sessions,
  ab.mature_regime_sessions,
  c.residual_sessions,
  c.residual_rows,
  c.market_fallback_pct,
  case
    when ab.phase2ab_gate_state='PHASE2AB_READY' and c.phase2c_gate_state='PHASE2C_READY'
      then 'PHASE2_READY'
    else 'PHASE2_NOT_READY'
  end as phase2_gate_state
from public.flow_phase2ab_quality_summary ab
cross join public.flow_phase2c_quality_summary c;

revoke all on public.flow_phase2_quality_summary from public, anon, authenticated;
grant select on public.flow_phase2_quality_summary to service_role;

create extension if not exists pg_cron;
do $$
declare r record;
begin
  for r in select jobid from cron.job where jobname='flow-stock-residual-v2-shadow-daily' loop
    perform cron.unschedule(r.jobid);
  end loop;
  perform cron.schedule(
    'flow-stock-residual-v2-shadow-daily',
    '12 11 * * 1-5',
    $cron$select public.flow_refresh_stock_residual_activity_v2((now() at time zone 'Asia/Jakarta')::date);$cron$
  );
end $$;
