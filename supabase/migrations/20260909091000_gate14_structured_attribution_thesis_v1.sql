-- Gate 14 completion: canonical structured attribution, data gaps, and thesis lifecycle.
create table if not exists public.flow_data_gap_registry_v2(
  attribution_contract text not null,
  domain text not null,
  evidence_state text not null check(evidence_state in (
    'AVAILABLE','MISSING','STALE','INVALID','NOT_APPLICABLE','INSUFFICIENT_HISTORY'
  )),
  observed_rows bigint not null default 0,
  observed_tickers integer not null default 0,
  min_available_date date,
  max_available_date date,
  limitation text not null,
  source_relations text[] not null default '{}'::text[],
  refreshed_at timestamptz not null default statement_timestamp(),
  production_influence_enabled boolean not null default false check(production_influence_enabled=false),
  primary key(attribution_contract,domain)
);

create table if not exists public.flow_attribution_structured_policy_v2(
  attribution_contract text primary key,
  source_attribution_contract text not null,
  universe_contract text not null,
  component_ids text[] not null,
  primary_threshold numeric not null,
  supporting_threshold numeric not null,
  contradicting_threshold numeric not null,
  event_lookback_days integer not null,
  narrative_rule text not null,
  frozen_at timestamptz not null default statement_timestamp(),
  production_influence_enabled boolean not null default false check(production_influence_enabled=false)
);

create table if not exists public.flow_attribution_structured_snapshot_v2(
  attribution_contract text not null,
  signal_date date not null,
  ticker text not null,
  universe_contract text not null,
  universe_rank integer not null,
  research_universe_eligible boolean not null,
  current_tradeable boolean not null,
  production_actionable boolean not null,
  primary_drivers jsonb not null default '[]'::jsonb,
  supporting_drivers jsonb not null default '[]'::jsonb,
  contradicting_drivers jsonb not null default '[]'::jsonb,
  context_only_evidence jsonb not null default '[]'::jsonb,
  missing_stale_unavailable_evidence jsonb not null default '[]'::jsonb,
  attribution_confidence text not null check(attribution_confidence in (
    'HIGH','MODERATE','LOW','INSUFFICIENT_DATA'
  )),
  predictive_readiness text not null check(predictive_readiness in (
    'VALIDATED_PREDICTIVE_EVIDENCE_PRESENT',
    'PROMISING_UNCONFIRMED_EVIDENCE_PRESENT',
    'NO_VALIDATED_PREDICTIVE_DRIVER'
  )),
  data_coverage_pct numeric not null,
  evidence_freshness text not null check(evidence_freshness in (
    'FRESH_SAME_DATE','STALE','INCOMPLETE'
  )),
  evidence_lineage jsonb not null default '[]'::jsonb,
  frozen_historical_performance_metadata jsonb not null default '[]'::jsonb,
  prospective_confirmation_status jsonb not null default '[]'::jsonb,
  narrative_summary text not null,
  captured_at timestamptz not null default statement_timestamp(),
  production_influence_enabled boolean not null default false check(production_influence_enabled=false),
  primary key(attribution_contract,signal_date,ticker)
);

create table if not exists public.flow_thesis_signal_v1(
  thesis_contract text not null,
  signal_date date not null,
  ticker text not null,
  primary_candidate_ids text[] not null,
  thesis_at_signal jsonb not null,
  thesis_now jsonb not null,
  structural_invalidation numeric,
  initial_primary_count integer not null,
  initial_contradicting_count integer not null,
  lifecycle_state text not null check(lifecycle_state in (
    'STRENGTHENING','INTACT','WEAKENING','BROKEN','EXPIRED','INVALID_DATA'
  )),
  changed_drivers jsonb not null default '[]'::jsonb,
  last_observation_date date not null,
  created_at timestamptz not null default statement_timestamp(),
  updated_at timestamptz not null default statement_timestamp(),
  production_influence_enabled boolean not null default false check(production_influence_enabled=false),
  primary key(thesis_contract,signal_date,ticker)
);

create table if not exists public.flow_thesis_signal_component_v1(
  thesis_contract text not null,
  signal_date date not null,
  ticker text not null,
  driver_id text not null,
  signal_driver_state text not null,
  signal_percentile numeric,
  signal_role text not null check(signal_role in ('PRIMARY','SUPPORTING','CONTRADICTING','NEUTRAL','UNAVAILABLE')),
  captured_at timestamptz not null default statement_timestamp(),
  production_influence_enabled boolean not null default false check(production_influence_enabled=false),
  primary key(thesis_contract,signal_date,ticker,driver_id)
);

create table if not exists public.flow_thesis_lifecycle_history_v1(
  thesis_contract text not null,
  signal_date date not null,
  observation_date date not null,
  ticker text not null,
  lifecycle_state text not null check(lifecycle_state in (
    'STRENGTHENING','INTACT','WEAKENING','BROKEN','EXPIRED','INVALID_DATA'
  )),
  thesis_now jsonb not null,
  changed_drivers jsonb not null,
  state_reason text not null,
  sessions_elapsed integer not null,
  observed_at timestamptz not null default statement_timestamp(),
  production_influence_enabled boolean not null default false check(production_influence_enabled=false),
  primary key(thesis_contract,signal_date,observation_date,ticker)
);

insert into public.flow_attribution_structured_policy_v2(
  attribution_contract,source_attribution_contract,universe_contract,component_ids,
  primary_threshold,supporting_threshold,contradicting_threshold,event_lookback_days,
  narrative_rule,production_influence_enabled
) values(
  'IDX_STRUCTURED_ATTRIBUTION_SHADOW_V2','IDX_PREDICTIVE_ATTRIBUTION_SHADOW_V1',
  'TOP_900_UNIVERSE_V1',
  array['FLOW_FOREIGN_ACCUMULATION','MKT_SECTOR_RELATIVE_STRENGTH_20D',
        'TECH_TREND_STRUCTURE','PV_PRICE_VOLUME_CONFIRMATION','FIN_BALANCE'],
  0.80,0.65,0.20,60,
  'Canonical structured evidence is the source of truth. Narrative only summarizes stored fields; use observed-association language, never causal wording. PROMISING remains unconfirmed and all production influence remains false.',
  false
) on conflict(attribution_contract) do nothing;

create index if not exists flow_attribution_structured_v2_rank_idx
  on public.flow_attribution_structured_snapshot_v2(signal_date desc,universe_rank);
create index if not exists flow_attribution_structured_v2_readiness_idx
  on public.flow_attribution_structured_snapshot_v2(signal_date desc,predictive_readiness);
create index if not exists flow_thesis_signal_v1_state_idx
  on public.flow_thesis_signal_v1(lifecycle_state,last_observation_date desc);
create index if not exists flow_thesis_lifecycle_v1_ticker_idx
  on public.flow_thesis_lifecycle_history_v1(ticker,observation_date desc);

create or replace function public.flow_refresh_data_gap_registry_v2()
returns jsonb
language plpgsql
security invoker
set search_path=''
as $fn$
declare v_contract text := 'IDX_STRUCTURED_ATTRIBUTION_SHADOW_V2';
begin
  delete from public.flow_data_gap_registry_v2 where attribution_contract=v_contract;

  insert into public.flow_data_gap_registry_v2(
    attribution_contract,domain,evidence_state,observed_rows,observed_tickers,
    min_available_date,max_available_date,limitation,source_relations,
    production_influence_enabled
  )
  select v_contract,domain,evidence_state,observed_rows,observed_tickers,
    min_date,max_date,limitation,source_relations,false
  from (
    select 'SECTOR'::text domain,
      case when count(distinct snapshot_date)>=20 then 'AVAILABLE' else 'INSUFFICIENT_HISTORY' end::text evidence_state,
      count(*)::bigint observed_rows,count(distinct ticker)::int observed_tickers,
      min(snapshot_date) min_date,max(snapshot_date) max_date,
      'Prospective PIT capture started 2026-09-09; pre-start historical membership is unavailable and is never backfilled.' limitation,
      array['flow_sector_membership_snapshot_v1']::text[] source_relations
    from public.flow_sector_membership_snapshot_v1
    union all
    select 'OWNERSHIP_SHAREHOLDER',
      case when count(distinct snapshot_date)>=20 then 'AVAILABLE' else 'INSUFFICIENT_HISTORY' end,
      count(*),count(distinct ticker),
      min(snapshot_date),max(snapshot_date),
      'Prospective official shareholder snapshots exist, but independent multi-date history is not yet sufficient.',
      array['flow_ownership_snapshot_v1']
    from public.flow_ownership_snapshot_v1
    union all
    select 'OFFICIAL_FREE_FLOAT','MISSING',0,0,null::date,null::date,
      'No verified regulatory free-float history is available. Tradable shares and residual disclosed ownership are not substituted.',
      array[]::text[]
    union all
    select 'CORPORATE_ACTION',case when count(*)>=100 then 'AVAILABLE' else 'INSUFFICIENT_HISTORY' end,
      count(*),count(distinct ticker),min(coalesce(publication_date,observed_on,event_date)),
      max(coalesce(publication_date,observed_on,event_date)),
      'Event occurrence is context-only; event interpretation and predictive validity remain separate and unvalidated.',
      array['flow_capital_action_evidence']
    from public.flow_capital_action_evidence
    where source_verified and validation_state='VERIFIED'
    union all
    select 'DISCLOSURE_MATERIAL_EVENT',case when count(*)>=100 then 'AVAILABLE' else 'INSUFFICIENT_HISTORY' end,
      count(*),count(distinct ticker),min((published_at at time zone 'Asia/Jakarta')::date),
      max((published_at at time zone 'Asia/Jakarta')::date),
      'Verified PIT disclosures remain context-only until a separate event contract is preregistered and validated.',
      array['flow_disclosure_evidence_v5']
    from public.flow_disclosure_evidence_v5
    where source_verified and point_in_time_eligible and publication_time_verified
    union all
    select 'FINANCIAL',case when count(*)>0 then 'AVAILABLE' else 'MISSING' end,
      count(*),count(distinct ticker),min(as_of_date),max(as_of_date),
      'PIT financial evidence is available; FIN_BALANCE remains discovery replay pending untouched confirmation.',
      array['flow_financial_shadow_panel_v5']
    from public.flow_financial_shadow_panel_v5
    where financial_state='AVAILABLE'
    union all
    select 'FOREIGN_FLOW',case when count(*)>0 then 'AVAILABLE' else 'MISSING' end,
      count(*),count(distinct ticker),min(trade_date),max(trade_date),
      'Verified foreign-flow source; missing values remain explicit and are never neutral-filled.',
      array['flow_stock_residual_activity_v2']
    from public.flow_stock_residual_activity_v2 where source_verified
    union all
    select 'TECHNICAL_PRICE_VOLUME',case when count(*)>0 then 'AVAILABLE' else 'MISSING' end,
      count(*),count(distinct ticker),min(trade_date),max(trade_date),
      'Verified official OHLCV source; insufficient history remains a distinct state.',
      array['flow_official_stock_summary']
    from public.flow_official_stock_summary where source_verified
    union all
    select 'LIQUIDITY',case when count(*)>0 then 'AVAILABLE' else 'MISSING' end,
      count(*),count(distinct ticker),min(trade_date),max(trade_date),
      'Tradeability is measured separately from research eligibility; zero activity is not erased.',
      array['flow_official_stock_summary']
    from public.flow_official_stock_summary where source_verified and traded_value>0 and frequency>0
    union all
    select 'MARKET_CONTEXT',case when count(distinct index_code)>=12 then 'AVAILABLE' else 'INSUFFICIENT_HISTORY' end,
      count(*),count(distinct index_code),min(trade_date),max(trade_date),
      'Official index context including COMPOSITE is required for horizons and sector-relative evidence.',
      array['flow_official_index_summary']
    from public.flow_official_index_summary where source_verified
  ) x;

  return (
    select jsonb_agg(to_jsonb(g) order by domain)
    from public.flow_data_gap_registry_v2 g
    where attribution_contract=v_contract
  );
end
$fn$;

create or replace function public.flow_capture_structured_attribution_v2(p_signal_date date)
returns jsonb
language plpgsql
security invoker
set search_path=''
set work_mem='64MB'
as $fn$
declare
  v_contract text := 'IDX_STRUCTURED_ATTRIBUTION_SHADOW_V2';
  v_source_contract text := 'IDX_PREDICTIVE_ATTRIBUTION_SHADOW_V1';
  v_universe_contract text := 'TOP_900_UNIVERSE_V1';
  v_universe_state text;
  v_signal_state text;
  v_rows integer := 0;
begin
  select capture_state into v_universe_state
  from public.flow_universe_capture_manifest_v1
  where universe_contract=v_universe_contract and snapshot_date=p_signal_date;

  select capture_state into v_signal_state
  from public.flow_attribution_capture_manifest_v1
  where attribution_contract=v_source_contract and signal_date=p_signal_date;

  if v_universe_state is distinct from 'CAPTURED' or v_signal_state is distinct from 'CAPTURED' then
    return jsonb_build_object('status','SOURCE_NOT_READY','signal_date',p_signal_date,
      'universe_state',coalesce(v_universe_state,'MISSING'),
      'prospective_signal_state',coalesce(v_signal_state,'MISSING'),
      'rows',0,'production_influence_enabled',false);
  end if;

  perform public.flow_refresh_data_gap_registry_v2();

  delete from public.flow_attribution_structured_snapshot_v2
  where attribution_contract=v_contract and signal_date=p_signal_date;

  with u as (
    select * from public.flow_universe_snapshot_v1
    where universe_contract=v_universe_contract and snapshot_date=p_signal_date and selected_top900
  ), grid as (
    select u.*,x.driver_id
    from u cross join unnest(array[
      'FLOW_FOREIGN_ACCUMULATION','MKT_SECTOR_RELATIVE_STRENGTH_20D',
      'TECH_TREND_STRUCTURE','PV_PRICE_VOLUME_CONFIRMATION','FIN_BALANCE'
    ]::text[]) x(driver_id)
  ), drv as (
    select g.ticker,g.universe_rank,g.research_universe_eligible,g.current_tradeable,
      g.production_actionable,g.driver_id,r.family,r.description,r.source_table,r.source_fields,
      d.raw_value,d.normalized_value,coalesce(d.driver_state,'MISSING') driver_state,
      d.source_state,d.captured_at driver_captured_at,
      o.valid_oos_cells,o.positive_oos_cells,o.direction_agreement_pct,
      o.mean_oos_alpha_spread_pct,o.mean_heldout_alpha_spread_pct,
      o.mean_forward_alpha_spread_pct,o.mean_rank_ic,o.positive_horizons,
      o.panel_coverage_pct,o.regime_consistency_pct,o.liquidity_consistency_pct,
      o.classification,o.confirmation_state,coalesce(o.eligible_to_enter_phase2,false) eligible
    from grid g
    left join public.flow_attribution_prospective_driver_v1 d
      on d.attribution_contract=v_source_contract and d.signal_date=p_signal_date
      and d.ticker=g.ticker and d.driver_id=g.driver_id
    left join public.flow_driver_registry_v1 r
      on r.registry_version='IDX_DRIVER_REGISTRY_GATE10_V2' and r.driver_id=g.driver_id
    left join public.flow_driver_oos_summary_v1 o
      on o.validation_contract='IDX_DRIVER_PURGED_EXPANDING_WF_V2' and o.driver_id=g.driver_id
  ), agg as (
    select ticker,max(universe_rank) universe_rank,bool_or(research_universe_eligible) research_eligible,
      bool_or(current_tradeable) current_tradeable,bool_or(production_actionable) production_actionable,
      count(*) filter(where driver_state='AVAILABLE' and normalized_value is not null)::int available_count,
      count(*) filter(where driver_state='AVAILABLE' and normalized_value>=0.80 and eligible)::int validated_count,
      count(*) filter(where driver_state='AVAILABLE' and normalized_value>=0.80
        and classification='PROMISING' and not eligible)::int promising_count,
      coalesce(jsonb_agg(jsonb_build_object(
        'driver_id',driver_id,'family',family,'description',description,'raw_value',raw_value,
        'percentile',round(normalized_value,6),'evidence_state',driver_state,
        'predictive_status',case when eligible then 'VALIDATED' else 'PROMISING_UNCONFIRMED' end,
        'classification',classification,'confirmation_state',confirmation_state
      ) order by normalized_value desc) filter(
        where driver_state='AVAILABLE' and normalized_value>=0.80
          and (eligible or classification='PROMISING')
      ),'[]'::jsonb) primary_drivers,
      coalesce(jsonb_agg(jsonb_build_object(
        'driver_id',driver_id,'family',family,'description',description,'raw_value',raw_value,
        'percentile',round(normalized_value,6),'evidence_state',driver_state,
        'predictive_status','DIAGNOSTIC','classification',coalesce(classification,'UNVALIDATED')
      ) order by normalized_value desc) filter(
        where driver_state='AVAILABLE' and normalized_value>=0.65
          and not (normalized_value>=0.80 and (eligible or classification='PROMISING'))
      ),'[]'::jsonb) supporting_drivers,
      coalesce(jsonb_agg(jsonb_build_object(
        'driver_id',driver_id,'family',family,'raw_value',raw_value,
        'percentile',round(normalized_value,6),'evidence_state',driver_state,
        'interpretation','CONTRADICTING_OBSERVED_EVIDENCE'
      ) order by normalized_value) filter(
        where driver_state='AVAILABLE' and normalized_value<=0.20
      ),'[]'::jsonb) contradicting_drivers,
      coalesce(jsonb_agg(jsonb_build_object(
        'driver_id',driver_id,'family',family,'evidence_state',driver_state,
        'source_state',coalesce(source_state,'UNAVAILABLE'),'missing_is_zero',false
      ) order by driver_id) filter(
        where driver_state<>'AVAILABLE' or normalized_value is null
      ),'[]'::jsonb) missing_drivers,
      jsonb_agg(jsonb_build_object(
        'driver_id',driver_id,'family',family,'source_relation',source_table,
        'source_fields',source_fields,'source_state',coalesce(source_state,'UNAVAILABLE'),
        'raw_value',raw_value,'percentile',normalized_value,'driver_state',driver_state,
        'captured_at',driver_captured_at
      ) order by driver_id) lineage,
      coalesce(jsonb_agg(jsonb_build_object(
        'driver_id',driver_id,'classification',classification,
        'confirmation_state',confirmation_state,'valid_oos_cells',valid_oos_cells,
        'positive_oos_cells',positive_oos_cells,'direction_agreement_pct',direction_agreement_pct,
        'mean_oos_alpha_spread_pct',mean_oos_alpha_spread_pct,
        'mean_heldout_alpha_spread_pct',mean_heldout_alpha_spread_pct,
        'mean_forward_alpha_spread_pct',mean_forward_alpha_spread_pct,
        'mean_rank_ic',mean_rank_ic,'positive_horizons',positive_horizons,
        'panel_coverage_pct',panel_coverage_pct,'regime_consistency_pct',regime_consistency_pct,
        'liquidity_consistency_pct',liquidity_consistency_pct,
        'eligible_to_enter_phase2',eligible
      ) order by driver_id) filter(where classification is not null),'[]'::jsonb) historical_metadata,
      max(driver_captured_at) latest_driver_capture
    from drv group by ticker
  ), ev as (
    select u.ticker,coalesce(jsonb_agg(jsonb_build_object(
      'domain','CORPORATE_EVENT','event_occurred',true,'event_type',e.event_type,
      'publication_date',e.publication_date,'event_date',e.event_date,
      'event_interpretation','UNASSESSED_CONTEXT_ONLY',
      'event_predictive_validity','NOT_ESTABLISHED','source_verified',e.source_verified
    ) order by coalesce(e.publication_date,e.observed_on,e.event_date) desc)
      filter(where e.ticker is not null),'[]'::jsonb) events
    from u left join public.flow_capital_action_evidence e
      on e.ticker=u.ticker and e.source_verified and e.validation_state='VERIFIED'
      and coalesce(e.publication_date,e.observed_on,e.event_date)<=p_signal_date
      and coalesce(e.publication_date,e.observed_on,e.event_date)>=(p_signal_date-60)
    group by u.ticker
  ), disc as (
    select u.ticker,coalesce(jsonb_agg(jsonb_build_object(
      'domain','DISCLOSURE_MATERIAL_EVENT','event_occurred',true,
      'disclosure_type',d.disclosure_type,'title',d.title,
      'published_at',d.published_at,'event_interpretation','UNASSESSED_CONTEXT_ONLY',
      'event_predictive_validity','NOT_ESTABLISHED','source_verified',d.source_verified
    ) order by d.published_at desc) filter(where d.announcement_id is not null),'[]'::jsonb) disclosures
    from u left join public.flow_disclosure_evidence_v5 d
      on d.ticker=u.ticker and d.source_verified and d.point_in_time_eligible
      and d.publication_time_verified
      and (d.published_at at time zone 'Asia/Jakarta')::date<=p_signal_date
      and (d.published_at at time zone 'Asia/Jakarta')::date>=(p_signal_date-60)
    group by u.ticker
  ), candidate_dates as (
    select candidate_id,count(distinct signal_date)::int independent_signal_dates
    from public.flow_attribution_prospective_candidate_v1
    where attribution_contract=v_source_contract and active_signal
    group by candidate_id
  ), outcome_counts as (
    select ticker,candidate_id,
      count(*) filter(where horizon_days=5 and outcome_state='MATURED')::int matured_5d,
      count(*) filter(where horizon_days=20 and outcome_state='MATURED')::int matured_20d,
      count(*) filter(where horizon_days=60 and outcome_state='MATURED')::int matured_60d
    from public.flow_attribution_forward_outcome_v1
    where attribution_contract=v_source_contract
    group by ticker,candidate_id
  ), candidate as (
    select c.ticker,coalesce(jsonb_agg(jsonb_build_object(
      'candidate_id',c.candidate_id,'candidate_type',c.candidate_type,
      'active_signal',c.active_signal,'signal_state',c.signal_state,
      'tracking_state',f.tracking_state,'untouched_signal_start_date',f.untouched_signal_start_date,
      'independent_signal_dates',coalesce(cd.independent_signal_dates,0),
      'matured_5d',coalesce(oc.matured_5d,0),
      'matured_20d',coalesce(oc.matured_20d,0),
      'matured_60d',coalesce(oc.matured_60d,0),
      'discovery_classification',s.classification,
      'discovery_confirmation_state',s.confirmation_state,
      'discovery_eligible_to_enter_phase2',coalesce(s.eligible_to_enter_phase2,false)
    ) order by c.candidate_id),'[]'::jsonb) prospective_status
    from public.flow_attribution_prospective_candidate_v1 c
    join public.flow_attribution_forward_registry_v1 f
      on f.attribution_contract=c.attribution_contract and f.candidate_id=c.candidate_id
    left join public.flow_driver_interaction_summary_v1 s
      on s.validation_contract='IDX_DRIVER_BOUNDED_CONFLUENCE_WF_V2'
      and s.interaction_id=c.candidate_id
    left join candidate_dates cd on cd.candidate_id=c.candidate_id
    left join outcome_counts oc on oc.ticker=c.ticker and oc.candidate_id=c.candidate_id
    where c.attribution_contract=v_source_contract and c.signal_date=p_signal_date
    group by c.ticker
  ), gaps as (
    select coalesce(jsonb_agg(jsonb_build_object(
      'domain',domain,'evidence_state',evidence_state,'limitation',limitation,
      'source_relations',source_relations,'missing_is_zero',false
    ) order by domain) filter(where evidence_state<>'AVAILABLE'),'[]'::jsonb) gap_items
    from public.flow_data_gap_registry_v2 where attribution_contract=v_contract
  )
  insert into public.flow_attribution_structured_snapshot_v2(
    attribution_contract,signal_date,ticker,universe_contract,universe_rank,
    research_universe_eligible,current_tradeable,production_actionable,
    primary_drivers,supporting_drivers,contradicting_drivers,context_only_evidence,
    missing_stale_unavailable_evidence,attribution_confidence,predictive_readiness,
    data_coverage_pct,evidence_freshness,evidence_lineage,
    frozen_historical_performance_metadata,prospective_confirmation_status,
    narrative_summary,production_influence_enabled
  )
  select v_contract,p_signal_date,a.ticker,v_universe_contract,a.universe_rank,
    a.research_eligible,a.current_tradeable,a.production_actionable,
    a.primary_drivers,a.supporting_drivers,a.contradicting_drivers,
    jsonb_build_array(jsonb_build_object(
      'domain','SECTOR','state',case when s.ticker is null then 'MISSING' else 'AVAILABLE' end,
      'sector',s.sector,'subsector',s.subsector,'snapshot_date',s.snapshot_date
    )) ||
    jsonb_build_array(jsonb_build_object(
      'domain','OWNERSHIP_SHAREHOLDER',
      'state',case when o.ticker is null then 'MISSING' else 'AVAILABLE' end,
      'source_observed_on',o.source_observed_on,'holder_count',o.holder_count,
      'top1_ownership_pct',o.top1_ownership_pct,'top5_ownership_pct',o.top5_ownership_pct,
      'controller_ownership_pct',o.controller_ownership_pct,
      'disclosed_ownership_pct',o.disclosed_ownership_pct,
      'unreported_float_upper_bound_pct',o.unreported_float_upper_bound_pct,
      'free_float_semantics','NOT_OFFICIAL_FREE_FLOAT'
    )) || e.events || di.disclosures,
    a.missing_drivers || g.gap_items,
    case when a.validated_count>0 and a.available_count=5 then 'HIGH'
         when a.promising_count>0 and a.available_count>=4 then 'MODERATE'
         when a.available_count>=3 then 'LOW' else 'INSUFFICIENT_DATA' end,
    case when a.validated_count>0 then 'VALIDATED_PREDICTIVE_EVIDENCE_PRESENT'
         when a.promising_count>0 then 'PROMISING_UNCONFIRMED_EVIDENCE_PRESENT'
         else 'NO_VALIDATED_PREDICTIVE_DRIVER' end,
    round(100.0*a.available_count/5.0,2),
    case when a.available_count<5 then 'INCOMPLETE'
         when a.latest_driver_capture::date=p_signal_date then 'FRESH_SAME_DATE'
         else 'STALE' end,
    a.lineage,a.historical_metadata,coalesce(c.prospective_status,'[]'::jsonb),
    case when a.validated_count>0 then
      'Historically associated with independently validated predictive evidence; current observed conditions are stored structurally and remain shadow-only.'
         when a.promising_count>0 then
      'Observed evidence suggests promising conditions, but the historical association is discovery-only and untouched forward confirmation remains pending.'
         else
      'Observed evidence is diagnostic or unavailable; no validated predictive driver is present.'
    end,false
  from agg a
  left join public.flow_sector_membership_snapshot_v1 s
    on s.snapshot_date=p_signal_date and s.ticker=a.ticker
  left join public.flow_ownership_snapshot_v1 o
    on o.snapshot_date=p_signal_date and o.ticker=a.ticker
  join ev e on e.ticker=a.ticker
  join disc di on di.ticker=a.ticker
  left join candidate c on c.ticker=a.ticker
  cross join gaps g;

  get diagnostics v_rows = row_count;
  return jsonb_build_object('status','CAPTURED','attribution_contract',v_contract,
    'signal_date',p_signal_date,'rows',v_rows,'production_influence_enabled',false);
end
$fn$;

create or replace function public.flow_refresh_thesis_lifecycle_v1(p_observation_date date)
returns jsonb
language plpgsql
security invoker
set search_path=''
set work_mem='48MB'
as $fn$
declare
  v_contract text := 'IDX_THESIS_LIFECYCLE_SHADOW_V1';
  v_attr text := 'IDX_STRUCTURED_ATTRIBUTION_SHADOW_V2';
  v_source text := 'IDX_PREDICTIVE_ATTRIBUTION_SHADOW_V1';
  v_new integer := 0;
  v_components integer := 0;
  v_lifecycle integer := 0;
begin
  if not exists(
    select 1 from public.flow_attribution_structured_snapshot_v2
    where attribution_contract=v_attr and signal_date=p_observation_date
  ) then
    return jsonb_build_object('status','SOURCE_NOT_READY','observation_date',p_observation_date,
      'new_theses',0,'lifecycle_rows',0,'production_influence_enabled',false);
  end if;

  insert into public.flow_thesis_signal_v1(
    thesis_contract,signal_date,ticker,primary_candidate_ids,thesis_at_signal,thesis_now,
    structural_invalidation,initial_primary_count,initial_contradicting_count,
    lifecycle_state,changed_drivers,last_observation_date,production_influence_enabled
  )
  select v_contract,p_observation_date,a.ticker,
    array(select c.candidate_id
      from public.flow_attribution_prospective_candidate_v1 c
      where c.attribution_contract=v_source and c.signal_date=p_observation_date
        and c.ticker=a.ticker and c.active_signal order by c.candidate_id),
    jsonb_build_object('primary_drivers',a.primary_drivers,'supporting_drivers',a.supporting_drivers,
      'contradicting_drivers',a.contradicting_drivers,'predictive_readiness',a.predictive_readiness,
      'data_coverage_pct',a.data_coverage_pct,'captured_before_outcome',true),
    jsonb_build_object('primary_drivers',a.primary_drivers,'supporting_drivers',a.supporting_drivers,
      'contradicting_drivers',a.contradicting_drivers,'observation_date',p_observation_date),
    (select min(q.low) from (
      select s.low from public.flow_official_stock_summary s
      where s.ticker=a.ticker and s.source_verified and s.trade_date<=p_observation_date
      order by s.trade_date desc limit 20
    ) q),
    jsonb_array_length(a.primary_drivers),jsonb_array_length(a.contradicting_drivers),
    'INTACT','[]'::jsonb,p_observation_date,false
  from public.flow_attribution_structured_snapshot_v2 a
  where a.attribution_contract=v_attr and a.signal_date=p_observation_date
    and exists(
      select 1 from public.flow_attribution_prospective_candidate_v1 c
      where c.attribution_contract=v_source and c.signal_date=p_observation_date
        and c.ticker=a.ticker and c.active_signal
    )
  on conflict(thesis_contract,signal_date,ticker) do nothing;
  get diagnostics v_new = row_count;

  insert into public.flow_thesis_signal_component_v1(
    thesis_contract,signal_date,ticker,driver_id,signal_driver_state,signal_percentile,
    signal_role,production_influence_enabled
  )
  select v_contract,p_observation_date,d.ticker,d.driver_id,d.driver_state,d.normalized_value,
    case when d.driver_state<>'AVAILABLE' or d.normalized_value is null then 'UNAVAILABLE'
         when d.normalized_value>=0.80 then 'PRIMARY'
         when d.normalized_value>=0.65 then 'SUPPORTING'
         when d.normalized_value<=0.20 then 'CONTRADICTING'
         else 'NEUTRAL' end,false
  from public.flow_attribution_prospective_driver_v1 d
  join public.flow_thesis_signal_v1 t
    on t.thesis_contract=v_contract and t.signal_date=p_observation_date
    and t.ticker=d.ticker
  where d.attribution_contract=v_source and d.signal_date=p_observation_date
  on conflict(thesis_contract,signal_date,ticker,driver_id) do nothing;
  get diagnostics v_components = row_count;

  with current_close as (
    select distinct on(ticker) ticker,close
    from public.flow_official_stock_summary
    where source_verified and trade_date<=p_observation_date
    order by ticker,trade_date desc
  ), compared as (
    select t.signal_date,t.ticker,t.structural_invalidation,t.initial_primary_count,
      t.initial_contradicting_count,c.driver_id,c.signal_driver_state,c.signal_percentile,c.signal_role,
      d.driver_state current_state,d.normalized_value current_percentile,
      cc.close current_close,
      (select count(distinct i.trade_date)::int
       from public.flow_official_index_summary i
       where i.index_code='COMPOSITE' and i.source_verified
         and i.trade_date>t.signal_date and i.trade_date<=p_observation_date) sessions_elapsed
    from public.flow_thesis_signal_v1 t
    join public.flow_thesis_signal_component_v1 c
      on c.thesis_contract=t.thesis_contract and c.signal_date=t.signal_date and c.ticker=t.ticker
    left join public.flow_attribution_prospective_driver_v1 d
      on d.attribution_contract=v_source and d.signal_date=p_observation_date
      and d.ticker=t.ticker and d.driver_id=c.driver_id
    left join current_close cc on cc.ticker=t.ticker
    where t.thesis_contract=v_contract and t.signal_date<=p_observation_date
  ), summary as (
    select signal_date,ticker,max(structural_invalidation) structural_invalidation,
      max(current_close) current_close,max(sessions_elapsed) sessions_elapsed,
      count(*) filter(where current_state='AVAILABLE' and current_percentile is not null)::int available_now,
      count(*) filter(where signal_percentile>=0.80)::int strong_then,
      count(*) filter(where current_state='AVAILABLE' and current_percentile>=0.80)::int strong_now,
      avg(signal_percentile) filter(where signal_driver_state='AVAILABLE') mean_then,
      avg(current_percentile) filter(where current_state='AVAILABLE') mean_now,
      bool_or(signal_role='PRIMARY' and
        (current_state is distinct from 'AVAILABLE' or current_percentile is null)) primary_missing,
      bool_or(signal_role='PRIMARY' and current_percentile<=0.20) primary_reversed,
      bool_or(signal_role='PRIMARY' and current_percentile<0.50) primary_weakened,
      coalesce(jsonb_agg(jsonb_build_object(
        'driver_id',driver_id,'signal_role',signal_role,
        'from_percentile',signal_percentile,'now_percentile',current_percentile,
        'current_state',coalesce(current_state,'MISSING'),
        'change_state',case
          when current_state is distinct from 'AVAILABLE' or current_percentile is null then 'MISSING_NOW'
          when signal_role='PRIMARY' and current_percentile<=0.20 then 'REVERSED'
          when signal_role='PRIMARY' and current_percentile<0.50 then 'WEAKENED'
          when current_percentile>=coalesce(signal_percentile,0)+0.10 then 'STRENGTHENED'
          else 'UNCHANGED' end
      ) order by driver_id),'[]'::jsonb) changes,
      coalesce(jsonb_agg(jsonb_build_object(
        'driver_id',driver_id,'driver_state',coalesce(current_state,'MISSING'),
        'percentile',current_percentile
      ) order by driver_id),'[]'::jsonb) current_drivers
    from compared group by signal_date,ticker
  ), state as (
    select s.*,
      case when available_now=0 then 'INVALID_DATA'
           when sessions_elapsed>60 then 'EXPIRED'
           when (structural_invalidation is not null and current_close<structural_invalidation)
             or primary_reversed then 'BROKEN'
           when primary_missing or primary_weakened then 'WEAKENING'
           when strong_now>strong_then or mean_now>=mean_then+0.10 then 'STRENGTHENING'
           else 'INTACT' end lifecycle_state,
      case when available_now=0 then 'No current comparable driver evidence.'
           when sessions_elapsed>60 then 'Frozen 60-session thesis horizon expired.'
           when structural_invalidation is not null and current_close<structural_invalidation
             then 'Price violated the stored structural invalidation.'
           when primary_reversed then 'At least one primary driver reversed into the bottom quintile.'
           when primary_missing then 'At least one primary driver became missing or invalid.'
           when primary_weakened then 'At least one primary driver fell below the frozen 0.50 weakening boundary.'
           when strong_now>strong_then or mean_now>=mean_then+0.10
             then 'Driver breadth or average percentile strengthened by the frozen rule.'
           else 'Primary evidence remains inside the frozen intact boundaries.' end state_reason
    from summary s
  )
  insert into public.flow_thesis_lifecycle_history_v1(
    thesis_contract,signal_date,observation_date,ticker,lifecycle_state,thesis_now,
    changed_drivers,state_reason,sessions_elapsed,production_influence_enabled
  )
  select v_contract,signal_date,p_observation_date,ticker,lifecycle_state,
    jsonb_build_object('observation_date',p_observation_date,'current_close',current_close,
      'structural_invalidation',structural_invalidation,'drivers',current_drivers),
    changes,state_reason,sessions_elapsed,false
  from state
  on conflict(thesis_contract,signal_date,observation_date,ticker) do update set
    lifecycle_state=excluded.lifecycle_state,thesis_now=excluded.thesis_now,
    changed_drivers=excluded.changed_drivers,state_reason=excluded.state_reason,
    sessions_elapsed=excluded.sessions_elapsed,observed_at=statement_timestamp();
  get diagnostics v_lifecycle = row_count;

  update public.flow_thesis_signal_v1 t set
    lifecycle_state=h.lifecycle_state,thesis_now=h.thesis_now,changed_drivers=h.changed_drivers,
    last_observation_date=h.observation_date,updated_at=statement_timestamp()
  from public.flow_thesis_lifecycle_history_v1 h
  where h.thesis_contract=t.thesis_contract and h.signal_date=t.signal_date and h.ticker=t.ticker
    and h.observation_date=p_observation_date and t.thesis_contract=v_contract;

  return jsonb_build_object('status','OK','observation_date',p_observation_date,
    'new_theses',v_new,'new_components',v_components,'lifecycle_rows',v_lifecycle,
    'production_influence_enabled',false);
end
$fn$;

create or replace function public.flow_run_attribution_signal_cycle_v2(
  p_signal_date date default ((clock_timestamp() at time zone 'Asia/Jakarta')::date)
)
returns jsonb
language plpgsql
security invoker
set search_path=''
as $fn$
declare v_signal jsonb; v_structured jsonb; v_thesis jsonb;
begin
  v_signal := public.flow_capture_attribution_prospective_signals_v1(p_signal_date);
  if coalesce(v_signal->>'status','')<>'CAPTURED' then
    return jsonb_build_object('signal',v_signal,'structured',jsonb_build_object('status','NOT_RUN'),
      'thesis',jsonb_build_object('status','NOT_RUN'),'production_influence_enabled',false);
  end if;
  v_structured := public.flow_capture_structured_attribution_v2(p_signal_date);
  if coalesce(v_structured->>'status','')='CAPTURED' then
    v_thesis := public.flow_refresh_thesis_lifecycle_v1(p_signal_date);
  else
    v_thesis := jsonb_build_object('status','NOT_RUN');
  end if;
  return jsonb_build_object('signal',v_signal,'structured',v_structured,'thesis',v_thesis,
    'production_influence_enabled',false);
end
$fn$;

create or replace function public.flow_run_attribution_pit_capture_v1()
returns jsonb
language plpgsql
security invoker
set search_path=''
as $fn$
declare v_sources jsonb; v_universe jsonb; v_gaps_v1 jsonb; v_gaps_v2 jsonb; v_date date;
begin
  v_date := (clock_timestamp() at time zone 'Asia/Jakarta')::date;
  v_sources := public.flow_capture_attribution_pit_sources_v1();
  v_universe := public.flow_capture_universe_snapshot_v1(v_date);
  v_gaps_v1 := public.flow_refresh_attribution_data_gap_v1();
  v_gaps_v2 := public.flow_refresh_data_gap_registry_v2();
  return jsonb_build_object('sources',v_sources,'universe',v_universe,
    'gaps_v1_refreshed',v_gaps_v1 is not null,'gaps_v2_refreshed',v_gaps_v2 is not null,
    'production_influence_enabled',false);
end
$fn$;

alter table public.flow_data_gap_registry_v2 enable row level security;
alter table public.flow_attribution_structured_policy_v2 enable row level security;
alter table public.flow_attribution_structured_snapshot_v2 enable row level security;
alter table public.flow_thesis_signal_v1 enable row level security;
alter table public.flow_thesis_signal_component_v1 enable row level security;
alter table public.flow_thesis_lifecycle_history_v1 enable row level security;

revoke all on table public.flow_data_gap_registry_v2,public.flow_attribution_structured_policy_v2,
  public.flow_attribution_structured_snapshot_v2,public.flow_thesis_signal_v1,
  public.flow_thesis_signal_component_v1,public.flow_thesis_lifecycle_history_v1
  from public,anon,authenticated;
grant select,insert,update,delete on table public.flow_data_gap_registry_v2,
  public.flow_attribution_structured_policy_v2,public.flow_attribution_structured_snapshot_v2,
  public.flow_thesis_signal_v1,public.flow_thesis_signal_component_v1,
  public.flow_thesis_lifecycle_history_v1 to service_role;

revoke all on function public.flow_refresh_data_gap_registry_v2(),
  public.flow_capture_structured_attribution_v2(date),
  public.flow_refresh_thesis_lifecycle_v1(date),
  public.flow_run_attribution_signal_cycle_v2(date),
  public.flow_run_attribution_pit_capture_v1()
  from public,anon,authenticated;
grant execute on function public.flow_refresh_data_gap_registry_v2(),
  public.flow_capture_structured_attribution_v2(date),
  public.flow_refresh_thesis_lifecycle_v1(date),
  public.flow_run_attribution_signal_cycle_v2(date),
  public.flow_run_attribution_pit_capture_v1()
  to service_role;

do $do$
declare r record;
begin
  for r in select jobid from cron.job where jobname='flow-attribution-forward-signals-v1' loop
    perform cron.unschedule(r.jobid);
  end loop;
  perform cron.schedule(
    'flow-attribution-forward-signals-v1','40 11 * * 1-5',
    'select public.flow_run_attribution_signal_cycle_v2((now() at time zone ''Asia/Jakarta'')::date);'
  );
end
$do$;
