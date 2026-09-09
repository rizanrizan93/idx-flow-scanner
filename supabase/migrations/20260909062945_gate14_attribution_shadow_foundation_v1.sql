create table if not exists public.flow_sector_membership_snapshot_v1(
  snapshot_date date not null,
  ticker text not null,
  sector text,
  subsector text,
  source_updated_at timestamptz,
  captured_at timestamptz not null default now(),
  source_state text not null default 'CURRENT_REGISTRY_CAPTURED_PROSPECTIVELY',
  production_influence_enabled boolean not null default false check(production_influence_enabled=false),
  primary key(snapshot_date,ticker)
);

create table if not exists public.flow_ownership_snapshot_v1(
  snapshot_date date not null,
  ticker text not null,
  source_observed_on date,
  source_ingested_at timestamptz,
  holder_count integer not null,
  top1_ownership_pct numeric,
  top5_ownership_pct numeric,
  controller_ownership_pct numeric,
  disclosed_ownership_pct numeric,
  unreported_float_upper_bound_pct numeric,
  source_state text not null default 'OFFICIAL_SHAREHOLDER_PROFILE_PROSPECTIVE_PIT',
  captured_at timestamptz not null default now(),
  production_influence_enabled boolean not null default false check(production_influence_enabled=false),
  primary key(snapshot_date,ticker)
);

create table if not exists public.flow_attribution_data_gap_v1(
  attribution_contract text not null,
  domain text not null,
  history_state text not null,
  observed_rows bigint not null default 0,
  observed_tickers integer not null default 0,
  min_available_date date,
  max_available_date date,
  prospective_pit_start_date date,
  limitation text not null,
  production_influence_enabled boolean not null default false check(production_influence_enabled=false),
  updated_at timestamptz not null default now(),
  primary key(attribution_contract,domain)
);

create table if not exists public.flow_attribution_forward_registry_v1(
  attribution_contract text not null,
  candidate_id text not null,
  candidate_type text not null check(candidate_type in ('DRIVER','INTERACTION')),
  component_ids text[] not null,
  tracking_state text not null check(tracking_state in ('CONFIRMATION_CANDIDATE','FORWARD_TRACK_ONLY')),
  discovery_contract text not null,
  untouched_signal_start_date date not null,
  horizons integer[] not null default array[5,20,60],
  preregistered_rule text not null,
  frozen_at timestamptz not null default now(),
  production_influence_enabled boolean not null default false check(production_influence_enabled=false),
  primary key(attribution_contract,candidate_id)
);

create table if not exists public.flow_attribution_shadow_policy_v1(
  attribution_contract text primary key,
  registry_version text not null,
  panel_contract text not null,
  oos_contract text not null,
  interaction_contract text not null,
  strong_threshold numeric not null check(strong_threshold between 0 and 1),
  contradicting_threshold numeric not null check(contradicting_threshold between 0 and 1),
  event_lookback_days integer not null check(event_lookback_days>0),
  narrative_rule text not null,
  frozen_at timestamptz not null default now(),
  production_influence_enabled boolean not null default false check(production_influence_enabled=false)
);

create table if not exists public.flow_attribution_shadow_snapshot_v1(
  attribution_contract text not null,
  signal_date date not null,
  ticker text not null,
  dominant_observed_evidence jsonb not null default '[]'::jsonb,
  supporting_diagnostic_evidence jsonb not null default '[]'::jsonb,
  contradicting_evidence jsonb not null default '[]'::jsonb,
  recent_verified_events jsonb not null default '[]'::jsonb,
  predictive_readiness_state text not null,
  validated_driver_count integer not null default 0,
  promising_unconfirmed_count integer not null default 0,
  diagnostic_strong_count integer not null default 0,
  available_driver_count integer not null default 0,
  evaluation_driver_count integer not null default 37,
  evidence_coverage_pct numeric not null,
  sector_history_state text not null,
  ownership_history_state text not null,
  event_history_state text not null,
  captured_at timestamptz not null default now(),
  production_influence_enabled boolean not null default false check(production_influence_enabled=false),
  primary key(attribution_contract,signal_date,ticker)
);

insert into public.flow_attribution_shadow_policy_v1(
  attribution_contract,registry_version,panel_contract,oos_contract,interaction_contract,
  strong_threshold,contradicting_threshold,event_lookback_days,narrative_rule,production_influence_enabled
) values(
  'IDX_PREDICTIVE_ATTRIBUTION_SHADOW_V1','IDX_DRIVER_REGISTRY_GATE10_V2','IDX_DRIVER_WEEKLY_PIT_PANEL_V2',
  'IDX_DRIVER_PURGED_EXPANDING_WF_V2','IDX_DRIVER_BOUNDED_CONFLUENCE_WF_V2',0.80,0.20,60,
  'Structured evidence only. PROMISING is unconfirmed; WEAK/UNSTABLE/LIQUIDITY_SENSITIVE are diagnostic; REJECTED never supports a thesis; no causal wording; no production score/rank/action/execution influence.',false
) on conflict(attribution_contract) do nothing;

insert into public.flow_attribution_forward_registry_v1(
  attribution_contract,candidate_id,candidate_type,component_ids,tracking_state,discovery_contract,
  untouched_signal_start_date,horizons,preregistered_rule,production_influence_enabled
) values
('IDX_PREDICTIVE_ATTRIBUTION_SHADOW_V1','FIN_BALANCE','DRIVER',array['FIN_BALANCE'],'CONFIRMATION_CANDIDATE','IDX_DRIVER_PURGED_EXPANDING_WF_V2','2026-09-09',array[5,20,60],'Untouched future signals only; no reuse of Gate9/Gate12 discovery periods as independent confirmation; require positive heldout/forward alpha, direction stability across horizons, adequate coverage, regime/liquidity robustness, and no leakage before any promotion experiment.',false),
('IDX_PREDICTIVE_ATTRIBUTION_SHADOW_V1','INT_FLOW_SECTOR','INTERACTION',array['FLOW_FOREIGN_ACCUMULATION','MKT_SECTOR_RELATIVE_STRENGTH_20D'],'FORWARD_TRACK_ONLY','IDX_DRIVER_BOUNDED_CONFLUENCE_WF_V2','2026-09-09',array[5,20,60],'Prospective track only; sector membership must come from captured PIT snapshots, never current-sector backfill.',false),
('IDX_PREDICTIVE_ATTRIBUTION_SHADOW_V1','INT_FLOW_TECHNICAL','INTERACTION',array['FLOW_FOREIGN_ACCUMULATION','TECH_TREND_STRUCTURE'],'FORWARD_TRACK_ONLY','IDX_DRIVER_BOUNDED_CONFLUENCE_WF_V2','2026-09-09',array[5,20,60],'Prospective track only; frozen components and thresholds; no post-hoc promotion.',false),
('IDX_PREDICTIVE_ATTRIBUTION_SHADOW_V1','INT_FLOW_PRICE_VOLUME','INTERACTION',array['FLOW_FOREIGN_ACCUMULATION','PV_PRICE_VOLUME_CONFIRMATION'],'FORWARD_TRACK_ONLY','IDX_DRIVER_BOUNDED_CONFLUENCE_WF_V2','2026-09-09',array[5,20,60],'Prospective track only; frozen components and thresholds; no post-hoc promotion.',false),
('IDX_PREDICTIVE_ATTRIBUTION_SHADOW_V1','INT_FLOW_FIN_BALANCE','INTERACTION',array['FLOW_FOREIGN_ACCUMULATION','FIN_BALANCE'],'FORWARD_TRACK_ONLY','IDX_DRIVER_BOUNDED_CONFLUENCE_WF_V2','2026-09-09',array[5,20,60],'Prospective track only; FIN_BALANCE discovery overlap remains guarded and requires untouched future confirmation.',false),
('IDX_PREDICTIVE_ATTRIBUTION_SHADOW_V1','INT_SECTOR_TECHNICAL','INTERACTION',array['MKT_SECTOR_RELATIVE_STRENGTH_20D','TECH_TREND_STRUCTURE'],'FORWARD_TRACK_ONLY','IDX_DRIVER_BOUNDED_CONFLUENCE_WF_V2','2026-09-09',array[5,20,60],'Prospective track only; sector membership from captured PIT snapshots.',false),
('IDX_PREDICTIVE_ATTRIBUTION_SHADOW_V1','INT_SECTOR_PRICE_VOLUME','INTERACTION',array['MKT_SECTOR_RELATIVE_STRENGTH_20D','PV_PRICE_VOLUME_CONFIRMATION'],'FORWARD_TRACK_ONLY','IDX_DRIVER_BOUNDED_CONFLUENCE_WF_V2','2026-09-09',array[5,20,60],'Prospective track only; sector membership from captured PIT snapshots.',false),
('IDX_PREDICTIVE_ATTRIBUTION_SHADOW_V1','INT_TECHNICAL_FIN_BALANCE','INTERACTION',array['TECH_TREND_STRUCTURE','FIN_BALANCE'],'FORWARD_TRACK_ONLY','IDX_DRIVER_BOUNDED_CONFLUENCE_WF_V2','2026-09-09',array[5,20,60],'Prospective track only; FIN_BALANCE overlap guard retained.',false),
('IDX_PREDICTIVE_ATTRIBUTION_SHADOW_V1','INT_FLOW_SECTOR_TECHNICAL','INTERACTION',array['FLOW_FOREIGN_ACCUMULATION','MKT_SECTOR_RELATIVE_STRENGTH_20D','TECH_TREND_STRUCTURE'],'FORWARD_TRACK_ONLY','IDX_DRIVER_BOUNDED_CONFLUENCE_WF_V2','2026-09-09',array[5,20,60],'Prospective track only; no brute-force variants.',false),
('IDX_PREDICTIVE_ATTRIBUTION_SHADOW_V1','INT_FLOW_SECTOR_PRICE_VOLUME','INTERACTION',array['FLOW_FOREIGN_ACCUMULATION','MKT_SECTOR_RELATIVE_STRENGTH_20D','PV_PRICE_VOLUME_CONFIRMATION'],'FORWARD_TRACK_ONLY','IDX_DRIVER_BOUNDED_CONFLUENCE_WF_V2','2026-09-09',array[5,20,60],'Prospective track only; no brute-force variants.',false),
('IDX_PREDICTIVE_ATTRIBUTION_SHADOW_V1','INT_FLOW_SECTOR_FIN_BALANCE','INTERACTION',array['FLOW_FOREIGN_ACCUMULATION','MKT_SECTOR_RELATIVE_STRENGTH_20D','FIN_BALANCE'],'FORWARD_TRACK_ONLY','IDX_DRIVER_BOUNDED_CONFLUENCE_WF_V2','2026-09-09',array[5,20,60],'Prospective track only; FIN_BALANCE overlap and PIT sector guards retained.',false),
('IDX_PREDICTIVE_ATTRIBUTION_SHADOW_V1','INT_FLOW_TECHNICAL_FIN_BALANCE','INTERACTION',array['FLOW_FOREIGN_ACCUMULATION','TECH_TREND_STRUCTURE','FIN_BALANCE'],'FORWARD_TRACK_ONLY','IDX_DRIVER_BOUNDED_CONFLUENCE_WF_V2','2026-09-09',array[5,20,60],'Prospective track only; FIN_BALANCE overlap guard retained.',false),
('IDX_PREDICTIVE_ATTRIBUTION_SHADOW_V1','INT_FLOW_SECTOR_TECHNICAL_FIN_BALANCE','INTERACTION',array['FLOW_FOREIGN_ACCUMULATION','MKT_SECTOR_RELATIVE_STRENGTH_20D','TECH_TREND_STRUCTURE','FIN_BALANCE'],'FORWARD_TRACK_ONLY','IDX_DRIVER_BOUNDED_CONFLUENCE_WF_V2','2026-09-09',array[5,20,60],'Prospective track only; PIT sector plus FIN_BALANCE overlap guards retained.',false)
on conflict(attribution_contract,candidate_id) do nothing;

create or replace function public.flow_capture_attribution_pit_sources_v1()
returns jsonb
language plpgsql
security invoker
set search_path=''
as $fn$
declare
  v_date date := (clock_timestamp() at time zone 'Asia/Jakarta')::date;
  v_sector integer;
  v_owner integer;
begin
  insert into public.flow_sector_membership_snapshot_v1(snapshot_date,ticker,sector,subsector,source_updated_at,production_influence_enabled)
  select v_date,ticker,sector,subsector,updated_at,false
  from public.flow_issuers
  where active
  on conflict(snapshot_date,ticker) do update set
    sector=excluded.sector,subsector=excluded.subsector,source_updated_at=excluded.source_updated_at,captured_at=now();
  get diagnostics v_sector = row_count;

  with latest as (
    select ticker,max(observed_on) observed_on
    from public.flow_official_shareholder_profiles
    where source_verified and observed_on<=v_date and ingested_at<=clock_timestamp()
    group by ticker
  ), ranked as (
    select p.ticker,p.observed_on,p.ingested_at,p.ownership_percentage,p.is_controller,
           row_number() over(partition by p.ticker order by p.ownership_percentage desc nulls last,p.holder_identity_hash) rn
    from public.flow_official_shareholder_profiles p
    join latest l on l.ticker=p.ticker and l.observed_on=p.observed_on
    where p.source_verified and p.ingested_at<=clock_timestamp()
  ), agg as (
    select ticker,max(observed_on) source_observed_on,max(ingested_at) source_ingested_at,
           count(*)::int holder_count,
           max(ownership_percentage) top1_ownership_pct,
           sum(ownership_percentage) filter(where rn<=5) top5_ownership_pct,
           sum(ownership_percentage) filter(where is_controller) controller_ownership_pct,
           sum(ownership_percentage) disclosed_ownership_pct
    from ranked group by ticker
  )
  insert into public.flow_ownership_snapshot_v1(
    snapshot_date,ticker,source_observed_on,source_ingested_at,holder_count,top1_ownership_pct,top5_ownership_pct,
    controller_ownership_pct,disclosed_ownership_pct,unreported_float_upper_bound_pct,production_influence_enabled
  )
  select v_date,ticker,source_observed_on,source_ingested_at,holder_count,top1_ownership_pct,top5_ownership_pct,
         controller_ownership_pct,disclosed_ownership_pct,greatest(0,100-coalesce(disclosed_ownership_pct,0)),false
  from agg
  on conflict(snapshot_date,ticker) do update set
    source_observed_on=excluded.source_observed_on,source_ingested_at=excluded.source_ingested_at,
    holder_count=excluded.holder_count,top1_ownership_pct=excluded.top1_ownership_pct,top5_ownership_pct=excluded.top5_ownership_pct,
    controller_ownership_pct=excluded.controller_ownership_pct,disclosed_ownership_pct=excluded.disclosed_ownership_pct,
    unreported_float_upper_bound_pct=excluded.unreported_float_upper_bound_pct,captured_at=now();
  get diagnostics v_owner = row_count;

  return jsonb_build_object('capture_date',v_date,'sector_rows',v_sector,'ownership_rows',v_owner,'production_influence_enabled',false);
end
$fn$;

create or replace function public.flow_refresh_attribution_data_gap_v1()
returns jsonb
language plpgsql
security invoker
set search_path=''
as $fn$
declare v_contract text := 'IDX_PREDICTIVE_ATTRIBUTION_SHADOW_V1';
begin
  delete from public.flow_attribution_data_gap_v1 where attribution_contract=v_contract;

  insert into public.flow_attribution_data_gap_v1(attribution_contract,domain,history_state,observed_rows,observed_tickers,min_available_date,max_available_date,prospective_pit_start_date,limitation,production_influence_enabled)
  select v_contract,'SECTOR','PROSPECTIVE_PIT_CAPTURE_STARTED',count(*),count(distinct ticker),min(snapshot_date),max(snapshot_date),min(snapshot_date),
         'Historical issuer-sector membership before the first captured snapshot remains unavailable; never backfill past dates with current classification.',false
  from public.flow_sector_membership_snapshot_v1;

  insert into public.flow_attribution_data_gap_v1(attribution_contract,domain,history_state,observed_rows,observed_tickers,min_available_date,max_available_date,prospective_pit_start_date,limitation,production_influence_enabled)
  select v_contract,'OWNERSHIP_FREE_FLOAT','PROSPECTIVE_PIT_CAPTURE_STARTED',count(*),count(distinct ticker),min(snapshot_date),max(snapshot_date),min(snapshot_date),
         'Official shareholder profiles only establish prospective PIT history. unreported_float_upper_bound_pct is not official free float and must not be labeled as exact free float.',false
  from public.flow_ownership_snapshot_v1;

  insert into public.flow_attribution_data_gap_v1(attribution_contract,domain,history_state,observed_rows,observed_tickers,min_available_date,max_available_date,prospective_pit_start_date,limitation,production_influence_enabled)
  select v_contract,'CORPORATE_EVENT','PIT_HISTORY_AVAILABLE_BUT_SPARSE',count(*),count(distinct ticker),min(coalesce(publication_date,event_date,observed_on)),max(coalesce(publication_date,event_date,observed_on)),null,
         'Verified capital-action history is PIT-usable as context, but sample is sparse and event-type heterogeneous; context-only until separately preregistered and validated.',false
  from public.flow_capital_action_evidence where source_verified and validation_state='VERIFIED';

  insert into public.flow_attribution_data_gap_v1(attribution_contract,domain,history_state,observed_rows,observed_tickers,min_available_date,max_available_date,prospective_pit_start_date,limitation,production_influence_enabled)
  select v_contract,'DISCLOSURE','PIT_HISTORY_TOO_SHORT',count(*),count(distinct ticker),min((published_at at time zone 'Asia/Jakarta')::date),max((published_at at time zone 'Asia/Jakarta')::date),null,
         'Verified disclosure v5 history is currently too short/sparse for predictive validation; presentation/context only.',false
  from public.flow_disclosure_evidence_v5 where source_verified and point_in_time_eligible and publication_time_verified;

  return (select jsonb_agg(to_jsonb(g) order by domain) from public.flow_attribution_data_gap_v1 g where attribution_contract=v_contract);
end
$fn$;

create or replace function public.flow_capture_attribution_shadow_v1(p_signal_date date default null)
returns jsonb
language plpgsql
security invoker
set search_path=''
as $fn$
declare
  v_contract text := 'IDX_PREDICTIVE_ATTRIBUTION_SHADOW_V1';
  v_date date;
  v_rows integer;
begin
  select coalesce(p_signal_date,max(signal_date)) into v_date
  from public.flow_driver_feature_panel_v1
  where panel_contract='IDX_DRIVER_WEEKLY_PIT_PANEL_V2';
  if v_date is null then raise exception 'No V2 signal date available'; end if;

  delete from public.flow_attribution_shadow_snapshot_v1 where attribution_contract=v_contract and signal_date=v_date;

  with drv as (
    select o.ticker,o.signal_date,o.driver_id,r.family,o.driver_state,o.raw_value,o.normalized_value,
           s.classification,s.confirmation_state,coalesce(s.eligible_to_enter_phase2,false) eligible_to_enter_phase2,
           s.mean_oos_alpha_spread_pct,s.mean_forward_alpha_spread_pct
    from public.flow_driver_observation_panel_v1 o
    join public.flow_driver_registry_v1 r on r.registry_version='IDX_DRIVER_REGISTRY_GATE10_V2' and r.driver_id=o.driver_id and r.evaluation_eligible
    left join public.flow_driver_oos_summary_v1 s on s.validation_contract='IDX_DRIVER_PURGED_EXPANDING_WF_V2' and s.driver_id=o.driver_id
    where o.panel_contract='IDX_DRIVER_WEEKLY_PIT_PANEL_V2' and o.signal_date=v_date
  ), agg as (
    select ticker,
      count(*) filter(where driver_state='AVAILABLE') available_count,
      count(*) filter(where driver_state='AVAILABLE' and eligible_to_enter_phase2 and normalized_value>=0.80) validated_count,
      count(*) filter(where driver_state='AVAILABLE' and classification='PROMISING' and not eligible_to_enter_phase2 and normalized_value>=0.80) promising_count,
      count(*) filter(where driver_state='AVAILABLE' and classification in ('WEAK','UNSTABLE','LIQUIDITY_SENSITIVE') and normalized_value>=0.80) diagnostic_count,
      coalesce(jsonb_agg(jsonb_build_object('driver_id',driver_id,'family',family,'strength_percentile',round(normalized_value::numeric,4),'classification',classification,'confirmation_state',confirmation_state,'mean_oos_alpha_spread_pct',mean_oos_alpha_spread_pct,'mean_forward_alpha_spread_pct',mean_forward_alpha_spread_pct) order by normalized_value desc) filter(where driver_state='AVAILABLE' and classification='PROMISING' and normalized_value>=0.80),'[]'::jsonb) dominant,
      coalesce(jsonb_agg(jsonb_build_object('driver_id',driver_id,'family',family,'strength_percentile',round(normalized_value::numeric,4),'classification',classification,'mean_oos_alpha_spread_pct',mean_oos_alpha_spread_pct,'mean_forward_alpha_spread_pct',mean_forward_alpha_spread_pct) order by normalized_value desc) filter(where driver_state='AVAILABLE' and classification in ('WEAK','UNSTABLE','LIQUIDITY_SENSITIVE') and normalized_value>=0.80),'[]'::jsonb) supporting,
      coalesce(jsonb_agg(jsonb_build_object('driver_id',driver_id,'family',family,'strength_percentile',round(normalized_value::numeric,4),'classification',classification) order by normalized_value asc) filter(where driver_state='AVAILABLE' and classification in ('PROMISING','WEAK','UNSTABLE','LIQUIDITY_SENSITIVE') and normalized_value<=0.20),'[]'::jsonb) contradicting
    from drv group by ticker
  ), ev as (
    select s.ticker,coalesce(jsonb_agg(jsonb_build_object('event_type',e.event_type,'publication_date',e.publication_date,'event_date',e.event_date,'validation_state',e.validation_state) order by coalesce(e.publication_date,e.event_date,e.observed_on) desc) filter(where e.ticker is not null),'[]'::jsonb) events
    from (select distinct ticker from drv) s
    left join public.flow_capital_action_evidence e on e.ticker=s.ticker and e.source_verified and e.validation_state='VERIFIED'
      and coalesce(e.publication_date,e.observed_on,e.event_date)<=v_date
      and coalesce(e.publication_date,e.observed_on,e.event_date)>=(v_date-60)
    group by s.ticker
  )
  insert into public.flow_attribution_shadow_snapshot_v1(
    attribution_contract,signal_date,ticker,dominant_observed_evidence,supporting_diagnostic_evidence,contradicting_evidence,
    recent_verified_events,predictive_readiness_state,validated_driver_count,promising_unconfirmed_count,diagnostic_strong_count,
    available_driver_count,evaluation_driver_count,evidence_coverage_pct,sector_history_state,ownership_history_state,event_history_state,production_influence_enabled
  )
  select v_contract,v_date,a.ticker,a.dominant,a.supporting,a.contradicting,e.events,
    case when a.validated_count>0 then 'VALIDATED_PREDICTIVE_EVIDENCE_PRESENT'
         when a.promising_count>0 then 'PROMISING_UNCONFIRMED_EVIDENCE_PRESENT'
         else 'NO_VALIDATED_PREDICTIVE_DRIVER' end,
    a.validated_count,a.promising_count,a.diagnostic_count,a.available_count,37,round(100.0*a.available_count/37.0,2),
    case when exists(select 1 from public.flow_sector_membership_snapshot_v1 x where x.ticker=a.ticker and x.snapshot_date<=v_date) then 'PIT_SNAPSHOT_AVAILABLE' else 'HISTORICAL_PIT_UNAVAILABLE' end,
    case when exists(select 1 from public.flow_ownership_snapshot_v1 x where x.ticker=a.ticker and x.snapshot_date<=v_date) then 'PIT_SNAPSHOT_AVAILABLE' else 'HISTORICAL_PIT_UNAVAILABLE' end,
    'PIT_CONTEXT_AVAILABLE_SPARSE',false
  from agg a join ev e on e.ticker=a.ticker;
  get diagnostics v_rows = row_count;
  return jsonb_build_object('attribution_contract',v_contract,'signal_date',v_date,'rows',v_rows,'production_influence_enabled',false);
end
$fn$;

alter table public.flow_sector_membership_snapshot_v1 enable row level security;
alter table public.flow_ownership_snapshot_v1 enable row level security;
alter table public.flow_attribution_data_gap_v1 enable row level security;
alter table public.flow_attribution_forward_registry_v1 enable row level security;
alter table public.flow_attribution_shadow_policy_v1 enable row level security;
alter table public.flow_attribution_shadow_snapshot_v1 enable row level security;

revoke all on table public.flow_sector_membership_snapshot_v1,public.flow_ownership_snapshot_v1,public.flow_attribution_data_gap_v1,public.flow_attribution_forward_registry_v1,public.flow_attribution_shadow_policy_v1,public.flow_attribution_shadow_snapshot_v1 from public,anon,authenticated;
grant select,insert,update,delete on table public.flow_sector_membership_snapshot_v1,public.flow_ownership_snapshot_v1,public.flow_attribution_data_gap_v1,public.flow_attribution_forward_registry_v1,public.flow_attribution_shadow_policy_v1,public.flow_attribution_shadow_snapshot_v1 to service_role;
revoke all on function public.flow_capture_attribution_pit_sources_v1(),public.flow_refresh_attribution_data_gap_v1(),public.flow_capture_attribution_shadow_v1(date) from public,anon,authenticated;
grant execute on function public.flow_capture_attribution_pit_sources_v1(),public.flow_refresh_attribution_data_gap_v1(),public.flow_capture_attribution_shadow_v1(date) to service_role;
