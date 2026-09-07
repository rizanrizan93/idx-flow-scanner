-- Phase 4B: market-wide outcome memory for self-learning factor discovery.
--
-- Storage policy: do NOT duplicate the already persisted official stock/residual
-- panels. The database is already close to the free-tier storage envelope, so
-- Phase 4B stores one compact immutable manifest row per trading date and exposes
-- versioned learning/outcome views over the canonical date-keyed evidence tables.
-- A later feature-contract change must create a new version, not rewrite v4.
--
-- Leakage policy:
-- - feature rows use only information with event/observed dates <= as_of_date;
-- - future returns exist only in the separate outcome view;
-- - historical ownership is never backfilled from a later observed snapshot;
-- - Phase 3A/3B/3C absence on an old date is explicit missingness, not fabricated;
-- - sector classification is tagged as current-registry classification because
--   no historical issuer-sector registry exists yet.

create table if not exists public.flow_market_memory_manifest_v4 (
  as_of_date date not null,
  feature_contract text not null default 'MARKET_MEMORY_V4_1',
  snapshot_mode text not null,
  stock_rows integer not null,
  residual_rows integer not null,
  broker_regime_rows integer not null,
  phase3b_state text,
  phase3b_as_of_date date,
  phase3c_state text,
  phase3c_as_of_date date,
  advanced_3abc_available boolean not null default false,
  manifest_state text not null,
  source_snapshot_hash text not null,
  source text not null default 'DERIVED_CANONICAL_IDX_MARKET_MEMORY',
  source_verified boolean not null default true,
  provenance_state text not null default 'VERIFIED_CANONICAL_ASOF_MANIFEST',
  captured_at timestamptz not null default now(),
  primary key (as_of_date, feature_contract),
  constraint flow_market_memory_manifest_v4_mode_ck check (
    snapshot_mode in ('LIVE_CAPTURE','HISTORICAL_RECONSTRUCTION')
  ),
  constraint flow_market_memory_manifest_v4_state_ck check (
    manifest_state in ('FULL_ADVANCED','BASE_MARKET')
  ),
  constraint flow_market_memory_manifest_v4_count_ck check (
    stock_rows >= 0 and residual_rows >= 0 and broker_regime_rows >= 0
  )
);

alter table public.flow_market_memory_manifest_v4 enable row level security;
revoke all on table public.flow_market_memory_manifest_v4 from public, anon, authenticated;
grant select, insert, update, delete on table public.flow_market_memory_manifest_v4 to service_role;

create index if not exists flow_risk_events_ticker_date_v4_idx
  on public.flow_official_risk_events (ticker, event_date desc);
create index if not exists flow_capital_actions_ticker_publication_v4_idx
  on public.flow_capital_action_evidence (ticker, publication_date desc, event_date desc);
create index if not exists flow_shareholders_ticker_observed_v4_idx
  on public.flow_official_shareholder_profiles (ticker, observed_on desc);

create or replace view public.flow_sector_index_map_v4
with (security_invoker=true) as
select *
from (values
  ('Barang Baku'::text, 'IDXBASIC'::text),
  ('Barang Konsumen Non-Primer', 'IDXCYCLIC'),
  ('Barang Konsumen Primer', 'IDXNONCYC'),
  ('Energi', 'IDXENERGY'),
  ('Infrastruktur', 'IDXINFRA'),
  ('Kesehatan', 'IDXHEALTH'),
  ('Keuangan', 'IDXFINANCE'),
  ('Perindustrian', 'IDXINDUST'),
  ('Properti & Real Estat', 'IDXPROPERT'),
  ('Teknologi', 'IDXTECHNO'),
  ('Transportasi & Logistik', 'IDXTRANS')
) as x(sector, index_code);

revoke all on public.flow_sector_index_map_v4 from public, anon, authenticated;
grant select on public.flow_sector_index_map_v4 to service_role;

create or replace function public.flow_capture_market_memory_manifest_v4(
  p_as_of_date date default ((now() at time zone 'Asia/Jakarta')::date),
  p_snapshot_mode text default 'LIVE_CAPTURE'
)
returns jsonb
language plpgsql
security definer
set search_path=pg_catalog,public
as $$
declare
  v_stock_rows integer := 0;
  v_stock_bad integer := 0;
  v_residual_rows integer := 0;
  v_residual_bad integer := 0;
  v_regime_rows integer := 0;
  v_regime_bad integer := 0;
  v_b_state text;
  v_b_date date;
  v_c_state text;
  v_c_date date;
  v_advanced boolean := false;
  v_manifest_state text;
  v_hash text;
  v_inserted integer := 0;
begin
  if p_snapshot_mode not in ('LIVE_CAPTURE','HISTORICAL_RECONSTRUCTION') then
    raise exception 'Invalid Phase 4B snapshot mode: %', p_snapshot_mode;
  end if;

  select
    count(distinct ticker)::integer,
    count(*) filter(
      where not source_verified
         or source_url is null
         or source_url not like 'https://block.idx.id/%'
    )::integer
  into v_stock_rows, v_stock_bad
  from public.flow_official_stock_summary
  where trade_date=p_as_of_date
    and source='IDX_OFFICIAL_STOCK_SUMMARY';

  select
    count(*)::integer,
    count(*) filter(where not source_verified)::integer
  into v_residual_rows, v_residual_bad
  from public.flow_stock_residual_activity_v2
  where trade_date=p_as_of_date;

  select
    count(*)::integer,
    count(*) filter(where not source_verified)::integer
  into v_regime_rows, v_regime_bad
  from public.flow_broker_market_regime_v2
  where trade_date=p_as_of_date;

  if v_stock_rows < 800
     or v_residual_rows < 800
     or v_regime_rows <> 1
     or v_stock_bad <> 0
     or v_residual_bad <> 0
     or v_regime_bad <> 0 then
    return jsonb_build_object(
      'status','CORE_NOT_READY',
      'as_of_date',p_as_of_date,
      'stock_rows',v_stock_rows,
      'residual_rows',v_residual_rows,
      'broker_regime_rows',v_regime_rows,
      'stock_bad_rows',v_stock_bad,
      'residual_bad_rows',v_residual_bad,
      'broker_regime_bad_rows',v_regime_bad
    );
  end if;

  select phase3b_gate_state,as_of_date
    into v_b_state,v_b_date
  from public.flow_phase3b_quality_summary;

  select phase3c_gate_state,as_of_date
    into v_c_state,v_c_date
  from public.flow_phase3c_quality_summary;

  v_advanced := coalesce(v_b_state='PHASE3B_READY' and v_b_date=p_as_of_date,false)
             and coalesce(v_c_state='PHASE3C_READY' and v_c_date=p_as_of_date,false);
  v_manifest_state := case when v_advanced then 'FULL_ADVANCED' else 'BASE_MARKET' end;

  v_hash := encode(
    digest(
      concat_ws('|',
        p_as_of_date::text,
        'MARKET_MEMORY_V4_1',
        p_snapshot_mode,
        v_stock_rows::text,
        v_residual_rows::text,
        v_regime_rows::text,
        coalesce(v_b_state,'NULL'),
        coalesce(v_b_date::text,'NULL'),
        coalesce(v_c_state,'NULL'),
        coalesce(v_c_date::text,'NULL'),
        v_manifest_state
      ),
      'sha256'
    ),
    'hex'
  );

  insert into public.flow_market_memory_manifest_v4 (
    as_of_date,feature_contract,snapshot_mode,
    stock_rows,residual_rows,broker_regime_rows,
    phase3b_state,phase3b_as_of_date,phase3c_state,phase3c_as_of_date,
    advanced_3abc_available,manifest_state,source_snapshot_hash
  ) values (
    p_as_of_date,'MARKET_MEMORY_V4_1',p_snapshot_mode,
    v_stock_rows,v_residual_rows,v_regime_rows,
    v_b_state,v_b_date,v_c_state,v_c_date,
    v_advanced,v_manifest_state,v_hash
  )
  on conflict (as_of_date,feature_contract) do nothing;

  get diagnostics v_inserted = row_count;

  insert into public.flow_ingestion_audit (
    provider,dataset,started_at,completed_at,status,
    rows_received,rows_accepted,rows_rejected,freshness_date,details
  ) values (
    'IDX_OFFICIAL_DERIVED','MARKET_MEMORY_MANIFEST_V4',now(),now(),
    case when v_inserted=1 then 'OK' else 'ALREADY_CAPTURED' end,
    v_stock_rows,v_stock_rows,0,p_as_of_date,
    jsonb_build_object(
      'feature_contract','MARKET_MEMORY_V4_1',
      'snapshot_mode',p_snapshot_mode,
      'manifest_state',v_manifest_state,
      'advanced_3abc_available',v_advanced,
      'storage_policy','MANIFEST_PLUS_VERSIONED_VIEWS_NO_RAW_PANEL_DUPLICATION',
      'source_snapshot_hash',v_hash
    )
  );

  return jsonb_build_object(
    'status',case when v_inserted=1 then 'OK' else 'ALREADY_CAPTURED' end,
    'as_of_date',p_as_of_date,
    'snapshot_mode',p_snapshot_mode,
    'manifest_state',v_manifest_state,
    'stock_rows',v_stock_rows,
    'residual_rows',v_residual_rows,
    'advanced_3abc_available',v_advanced,
    'source_snapshot_hash',v_hash
  );
end;
$$;

revoke all on function public.flow_capture_market_memory_manifest_v4(date,text)
  from public,anon,authenticated;
grant execute on function public.flow_capture_market_memory_manifest_v4(date,text)
  to service_role;

create or replace function public.flow_backfill_market_memory_manifest_v4(
  p_start_date date,
  p_end_date date
)
returns jsonb
language plpgsql
security definer
set search_path=pg_catalog,public
as $$
declare
  d date;
  v_attempted integer := 0;
  v_ok integer := 0;
  v_skipped integer := 0;
  v_result jsonb;
begin
  if p_start_date is null or p_end_date is null or p_end_date < p_start_date then
    raise exception 'Invalid Phase 4B backfill range';
  end if;
  if p_end_date-p_start_date > 31 then
    raise exception 'Phase 4B backfill is limited to 31 calendar days per call';
  end if;

  for d in
    select distinct trade_date
    from public.flow_stock_residual_activity_v2
    where trade_date between p_start_date and p_end_date
    order by trade_date
  loop
    v_attempted := v_attempted+1;
    v_result := public.flow_capture_market_memory_manifest_v4(
      d,'HISTORICAL_RECONSTRUCTION'
    );
    if v_result->>'status' in ('OK','ALREADY_CAPTURED') then
      v_ok := v_ok+1;
    else
      v_skipped := v_skipped+1;
    end if;
  end loop;

  return jsonb_build_object(
    'status','OK',
    'start_date',p_start_date,
    'end_date',p_end_date,
    'attempted_sessions',v_attempted,
    'accepted_sessions',v_ok,
    'skipped_sessions',v_skipped
  );
end;
$$;

revoke all on function public.flow_backfill_market_memory_manifest_v4(date,date)
  from public,anon,authenticated;
grant execute on function public.flow_backfill_market_memory_manifest_v4(date,date)
  to service_role;

create or replace view public.flow_market_learning_panel_v4
with (security_invoker=true) as
with stock_hist as (
  select
    s.trade_date,
    s.ticker,
    s.stock_name,
    s.previous,
    s.close,
    s.high,
    s.low,
    s.volume,
    s.traded_value,
    s.frequency,
    s.foreign_buy,
    s.foreign_sell,
    s.foreign_buy-s.foreign_sell as foreign_net,
    s.listed_shares,
    s.tradable_shares,
    s.source_verified as stock_source_verified,
    lag(s.close,5) over(partition by s.ticker order by s.trade_date) as close_lag5,
    lag(s.close,20) over(partition by s.ticker order by s.trade_date) as close_lag20,
    lag(s.close,60) over(partition by s.ticker order by s.trade_date) as close_lag60,
    max(s.high) over(
      partition by s.ticker order by s.trade_date
      rows between 19 preceding and current row
    ) as high_20,
    min(s.low) over(
      partition by s.ticker order by s.trade_date
      rows between 19 preceding and current row
    ) as low_20
  from public.flow_official_stock_summary s
  where s.source='IDX_OFFICIAL_STOCK_SUMMARY'
    and s.source_verified
), c3_ranked as (
  select
    t.as_of_date,
    t.ticker,
    t.coalition_id,
    c.activation_state,
    c.structure_class,
    t.coalition_ticker_profile_score,
    t.affinity_member_count,
    t.member_reliability_factor,
    (t.source_verified and c.source_verified) as c3_source_verified,
    t.coalition_ticker_profile_score * case c.activation_state
      when 'BROAD_ACTIVE' then 1::numeric
      when 'PARTIAL' then 0.50::numeric
      else 0::numeric
    end as effective_profile_score,
    row_number() over(
      partition by t.as_of_date,t.ticker
      order by
        t.coalition_ticker_profile_score * case c.activation_state
          when 'BROAD_ACTIVE' then 1::numeric
          when 'PARTIAL' then 0.50::numeric
          else 0::numeric
        end desc,
        t.coalition_id
    ) as rn
  from public.flow_broker_coalition_ticker_affinity_v3 t
  join public.flow_broker_coalitions_v3 c
    using(as_of_date,coalition_id)
), joined as (
  select
    m.as_of_date,
    m.feature_contract,
    m.snapshot_mode,
    m.manifest_state,
    m.advanced_3abc_available,
    h.ticker,
    h.stock_name,
    coalesce(r.sector,i.sector) as sector,
    coalesce(r.subsector,i.subsector) as subsector,
    'CURRENT_REGISTRY_CLASSIFICATION_NOT_HISTORICAL'::text as sector_history_state,
    h.previous,
    h.close,
    case when h.previous>0 then 100::numeric*(h.close/h.previous-1) end as return_1d_pct,
    case when h.close_lag5>0 then 100::numeric*(h.close/h.close_lag5-1) end as return_5d_pct,
    case when h.close_lag20>0 then 100::numeric*(h.close/h.close_lag20-1) end as return_20d_pct,
    case when h.close_lag60>0 then 100::numeric*(h.close/h.close_lag60-1) end as return_60d_pct,
    case when h.close>0 then 100::numeric*(h.high-h.low)/h.close end as volatility_range_pct,
    case when h.high_20>0 then 100::numeric*(h.close/h.high_20-1) end as close_vs_20d_high_pct,
    case when h.low_20>0 then 100::numeric*(h.close/h.low_20-1) end as close_vs_20d_low_pct,
    h.volume,
    h.traded_value,
    h.frequency,
    h.foreign_buy,
    h.foreign_sell,
    h.foreign_net,
    h.listed_shares,
    h.tradable_shares,
    case when h.listed_shares>0 and h.tradable_shares is not null
      then 100::numeric*h.tradable_shares/h.listed_shares end as tradable_float_pct,
    r.foreign_net_volume_pct,
    r.market_turnover_share_pct,
    r.sector_turnover_share_pct,
    r.turnover_residual_z,
    r.volume_residual_z,
    r.frequency_residual_z,
    r.stock_residual_activity_z,
    r.volatility_bucket,
    r.peer_group_size,
    r.residual_quality_state,
    br.market_value_z60,
    br.market_volume_z60,
    br.market_frequency_z60,
    br.top10_value_share_pct,
    br.value_hhi_10k,
    br.value_entropy_pct,
    br.activity_breadth_pct,
    br.high_activity_broker_count,
    br.shock_broker_count,
    br.market_activity_intensity_z,
    br.regime_label as broker_market_regime,
    br.regime_quality_state as broker_regime_quality_state,
    coalesce(b.weighted_affinity_score,0)::numeric as phase3a_score,
    (
      coalesce(b.source_verified,false)
      and coalesce(b.affinity_active_broker_count,0)>=3
      and coalesce(b.weighted_affinity_score,0)>=65
      and coalesce(b.consensus_reliability_factor,0)>=0.60
    ) as phase3a_eligible,
    coalesce(b.broker_consensus_proxy_score,0)::numeric as phase3b_score,
    coalesce(b.breadth_state,'NONE') as phase3b_breadth_state,
    coalesce(b.consensus_reliability_factor,0)::numeric as phase3b_reliability_factor,
    (
      coalesce(b.source_verified,false)
      and coalesce(b.breadth_state,'') in ('STRONG','BROAD')
      and coalesce(b.broker_consensus_proxy_score,0)>=45
    ) as phase3b_eligible,
    coalesce(c3.effective_profile_score,0)::numeric as phase3c_score,
    c3.coalition_id as phase3c_coalition_id,
    c3.activation_state as phase3c_activation_state,
    c3.structure_class as phase3c_structure_class,
    coalesce(c3.affinity_member_count,0)::integer as phase3c_affinity_member_count,
    coalesce(c3.member_reliability_factor,0)::numeric as phase3c_member_reliability_factor,
    (
      coalesce(c3.c3_source_verified,false)
      and coalesce(c3.effective_profile_score,0)>=50
    ) as phase3c_eligible,
    coalesce(risk.risk_event_20d_count,0)::integer as risk_event_20d_count,
    coalesce(risk.has_uma_20d,false) as has_uma_20d,
    coalesce(risk.has_suspend_20d,false) as has_suspend_20d,
    coalesce(cap.capital_action_90d_count,0)::integer as capital_action_90d_count,
    cap.capital_change_max_abs_pct_90d,
    coalesce(cap.has_rights_issue_90d,false) as has_rights_issue_90d,
    coalesce(cap.has_private_placement_90d,false) as has_private_placement_90d,
    own.ownership_observed_on,
    case when own.ownership_observed_on is not null
      then m.as_of_date-own.ownership_observed_on end as ownership_snapshot_age_days,
    own.holder_count,
    own.controller_count,
    own.controller_ownership_pct,
    (m.source_verified and h.stock_source_verified and coalesce(r.source_verified,false)
      and coalesce(br.source_verified,false)) as source_verified,
    m.source_snapshot_hash
  from public.flow_market_memory_manifest_v4 m
  join stock_hist h
    on h.trade_date=m.as_of_date
  join public.flow_stock_residual_activity_v2 r
    on r.trade_date=m.as_of_date and r.ticker=h.ticker
  join public.flow_broker_market_regime_v2 br
    on br.trade_date=m.as_of_date
  left join public.flow_issuers i
    on i.ticker=h.ticker
  left join public.flow_ticker_affinity_consensus_v3 b
    on b.as_of_date=m.as_of_date and b.ticker=h.ticker
  left join c3_ranked c3
    on c3.as_of_date=m.as_of_date and c3.ticker=h.ticker and c3.rn=1
  left join lateral (
    select
      count(*)::integer as risk_event_20d_count,
      bool_or(upper(coalesce(e.event_type,'')) like '%UMA%') as has_uma_20d,
      bool_or(
        upper(coalesce(e.event_type,'')) like '%SUSPEND%'
        or upper(coalesce(e.event_type,'')) like '%SUSPENS%'
      ) as has_suspend_20d
    from public.flow_official_risk_events e
    where e.ticker=h.ticker
      and e.source_verified
      and e.event_date between m.as_of_date-30 and m.as_of_date
  ) risk on true
  left join lateral (
    select
      count(*)::integer as capital_action_90d_count,
      max(abs(a.delta_percent)) as capital_change_max_abs_pct_90d,
      bool_or(a.event_type='RIGHTS_ISSUE') as has_rights_issue_90d,
      bool_or(a.event_type='PRIVATE_PLACEMENT') as has_private_placement_90d
    from public.flow_capital_action_evidence a
    where a.ticker=h.ticker
      and a.source_verified
      and coalesce(a.publication_date,a.event_date) <= m.as_of_date
      and coalesce(a.publication_date,a.event_date) >= m.as_of_date-120
  ) cap on true
  left join lateral (
    with od as (
      select max(p.observed_on) as observed_on
      from public.flow_official_shareholder_profiles p
      where p.ticker=h.ticker
        and p.source_verified
        and p.observed_on<=m.as_of_date
    )
    select
      od.observed_on as ownership_observed_on,
      count(p.holder_identity_hash)::integer as holder_count,
      count(*) filter(where p.is_controller)::integer as controller_count,
      sum(p.ownership_percentage) filter(where p.is_controller) as controller_ownership_pct
    from od
    left join public.flow_official_shareholder_profiles p
      on p.ticker=h.ticker
     and p.source_verified
     and p.observed_on=od.observed_on
    where od.observed_on is not null
    group by od.observed_on
  ) own on true
  where m.feature_contract='MARKET_MEMORY_V4_1'
), scored as (
  select
    j.*,
    (j.phase3a_eligible::integer+j.phase3b_eligible::integer+j.phase3c_eligible::integer)::integer
      as advanced_evidence_layer_count,
    least(1::numeric,greatest(0::numeric,
      0.25::numeric*case when j.phase3a_eligible
        then (least(100::numeric,greatest(0::numeric,j.phase3a_score))/100::numeric)
             * least(1::numeric,greatest(0::numeric,j.phase3b_reliability_factor))
        else 0::numeric end
      + 0.50::numeric*case when j.phase3b_eligible
        then least(100::numeric,greatest(0::numeric,j.phase3b_score))/100::numeric
        else 0::numeric end
      + 0.25::numeric*case when j.phase3c_eligible
        then least(100::numeric,greatest(0::numeric,j.phase3c_score))/100::numeric
        else 0::numeric end
    )) as advanced_support
  from joined j
)
select
  s.*,
  50::numeric+50::numeric*s.advanced_support as advanced_broker_score,
  (s.advanced_evidence_layer_count>0) as advanced_broker_evidence_eligible,
  jsonb_build_object(
    'technical_5d',s.return_5d_pct is not null,
    'technical_20d',s.return_20d_pct is not null,
    'technical_60d',s.return_60d_pct is not null,
    'phase3abc',s.advanced_3abc_available,
    'risk_events',true,
    'capital_actions',true,
    'ownership_asof',s.ownership_observed_on is not null
  ) as feature_availability,
  'STATISTICAL_CO_ACTIVITY_EVIDENCE_NOT_BUY_SELL'::text as association_semantics,
  'MARKET_MEMORY_V4_1'::text as learning_feature_version
from scored s;

revoke all on public.flow_market_learning_panel_v4 from public,anon,authenticated;
grant select on public.flow_market_learning_panel_v4 to service_role;

create or replace view public.flow_market_learning_outcomes_v4
with (security_invoker=true) as
with stock_seq as (
  select
    s.trade_date,
    s.ticker,
    s.close,
    lead(s.close,1) over w as close_1d,
    lead(s.close,5) over w as close_5d,
    lead(s.close,10) over w as close_10d,
    lead(s.close,20) over w as close_20d,
    lead(s.close,60) over w as close_60d,
    lead(s.close,120) over w as close_120d,
    lead(s.close,250) over w as close_250d,
    max(s.high) over(
      partition by s.ticker order by s.trade_date
      rows between 1 following and 20 following
    ) as high_20d,
    min(s.low) over(
      partition by s.ticker order by s.trade_date
      rows between 1 following and 20 following
    ) as low_20d,
    max(s.high) over(
      partition by s.ticker order by s.trade_date
      rows between 1 following and 60 following
    ) as high_60d,
    min(s.low) over(
      partition by s.ticker order by s.trade_date
      rows between 1 following and 60 following
    ) as low_60d,
    max(s.high) over(
      partition by s.ticker order by s.trade_date
      rows between 1 following and 120 following
    ) as high_120d,
    min(s.low) over(
      partition by s.ticker order by s.trade_date
      rows between 1 following and 120 following
    ) as low_120d,
    max(s.high) over(
      partition by s.ticker order by s.trade_date
      rows between 1 following and 250 following
    ) as high_250d,
    min(s.low) over(
      partition by s.ticker order by s.trade_date
      rows between 1 following and 250 following
    ) as low_250d,
    (count(*) over(
      partition by s.ticker order by s.trade_date
      rows between current row and unbounded following
    )-1)::integer as evaluated_sessions
  from public.flow_official_stock_summary s
  where s.source='IDX_OFFICIAL_STOCK_SUMMARY'
    and s.source_verified
  window w as (partition by s.ticker order by s.trade_date)
), idx_seq as (
  select
    x.trade_date,
    x.index_code,
    x.close,
    lead(x.close,20) over w as close_20d,
    lead(x.close,60) over w as close_60d,
    lead(x.close,120) over w as close_120d,
    lead(x.close,250) over w as close_250d
  from public.flow_official_index_summary x
  where x.source_verified
  window w as (partition by x.index_code order by x.trade_date)
), base as (
  select
    m.as_of_date,
    m.feature_contract,
    s.ticker,
    coalesce(r.sector,i.sector) as sector,
    sm.index_code as sector_index_code,
    s.close as entry_close,
    s.evaluated_sessions,
    case when s.close>0 and s.close_1d is not null then 100::numeric*(s.close_1d/s.close-1) end as forward_return_1d_pct,
    case when s.close>0 and s.close_5d is not null then 100::numeric*(s.close_5d/s.close-1) end as forward_return_5d_pct,
    case when s.close>0 and s.close_10d is not null then 100::numeric*(s.close_10d/s.close-1) end as forward_return_10d_pct,
    case when s.close>0 and s.close_20d is not null then 100::numeric*(s.close_20d/s.close-1) end as forward_return_20d_pct,
    case when s.close>0 and s.close_60d is not null then 100::numeric*(s.close_60d/s.close-1) end as forward_return_60d_pct,
    case when s.close>0 and s.close_120d is not null then 100::numeric*(s.close_120d/s.close-1) end as forward_return_120d_pct,
    case when s.close>0 and s.close_250d is not null then 100::numeric*(s.close_250d/s.close-1) end as forward_return_250d_pct,
    case when s.evaluated_sessions>=20 and s.close>0 then 100::numeric*(s.high_20d/s.close-1) end as mfe_20d_pct,
    case when s.evaluated_sessions>=20 and s.close>0 then 100::numeric*(s.low_20d/s.close-1) end as mae_20d_pct,
    case when s.evaluated_sessions>=60 and s.close>0 then 100::numeric*(s.high_60d/s.close-1) end as mfe_60d_pct,
    case when s.evaluated_sessions>=60 and s.close>0 then 100::numeric*(s.low_60d/s.close-1) end as mae_60d_pct,
    case when s.evaluated_sessions>=120 and s.close>0 then 100::numeric*(s.high_120d/s.close-1) end as mfe_120d_pct,
    case when s.evaluated_sessions>=120 and s.close>0 then 100::numeric*(s.low_120d/s.close-1) end as mae_120d_pct,
    case when s.evaluated_sessions>=250 and s.close>0 then 100::numeric*(s.high_250d/s.close-1) end as mfe_250d_pct,
    case when s.evaluated_sessions>=250 and s.close>0 then 100::numeric*(s.low_250d/s.close-1) end as mae_250d_pct,
    case when ih.close>0 and ih.close_20d is not null then 100::numeric*(ih.close_20d/ih.close-1) end as ihsg_return_20d_pct,
    case when ih.close>0 and ih.close_60d is not null then 100::numeric*(ih.close_60d/ih.close-1) end as ihsg_return_60d_pct,
    case when ih.close>0 and ih.close_120d is not null then 100::numeric*(ih.close_120d/ih.close-1) end as ihsg_return_120d_pct,
    case when ih.close>0 and ih.close_250d is not null then 100::numeric*(ih.close_250d/ih.close-1) end as ihsg_return_250d_pct,
    case when si.close>0 and si.close_20d is not null then 100::numeric*(si.close_20d/si.close-1) end as sector_return_20d_pct,
    case when si.close>0 and si.close_60d is not null then 100::numeric*(si.close_60d/si.close-1) end as sector_return_60d_pct,
    case when si.close>0 and si.close_120d is not null then 100::numeric*(si.close_120d/si.close-1) end as sector_return_120d_pct,
    case when si.close>0 and si.close_250d is not null then 100::numeric*(si.close_250d/si.close-1) end as sector_return_250d_pct
  from public.flow_market_memory_manifest_v4 m
  join stock_seq s
    on s.trade_date=m.as_of_date
  left join public.flow_stock_residual_activity_v2 r
    on r.trade_date=m.as_of_date and r.ticker=s.ticker
  left join public.flow_issuers i
    on i.ticker=s.ticker
  left join public.flow_sector_index_map_v4 sm
    on sm.sector=coalesce(r.sector,i.sector)
  left join idx_seq ih
    on ih.trade_date=m.as_of_date and ih.index_code='COMPOSITE'
  left join idx_seq si
    on si.trade_date=m.as_of_date and si.index_code=sm.index_code
  where m.feature_contract='MARKET_MEMORY_V4_1'
)
select
  b.*,
  case when b.forward_return_20d_pct is not null and b.ihsg_return_20d_pct is not null
    then b.forward_return_20d_pct-b.ihsg_return_20d_pct end as alpha_vs_ihsg_20d_pct,
  case when b.forward_return_60d_pct is not null and b.ihsg_return_60d_pct is not null
    then b.forward_return_60d_pct-b.ihsg_return_60d_pct end as alpha_vs_ihsg_60d_pct,
  case when b.forward_return_120d_pct is not null and b.ihsg_return_120d_pct is not null
    then b.forward_return_120d_pct-b.ihsg_return_120d_pct end as alpha_vs_ihsg_120d_pct,
  case when b.forward_return_250d_pct is not null and b.ihsg_return_250d_pct is not null
    then b.forward_return_250d_pct-b.ihsg_return_250d_pct end as alpha_vs_ihsg_250d_pct,
  case when b.forward_return_20d_pct is not null and b.sector_return_20d_pct is not null
    then b.forward_return_20d_pct-b.sector_return_20d_pct end as alpha_vs_sector_20d_pct,
  case when b.forward_return_60d_pct is not null and b.sector_return_60d_pct is not null
    then b.forward_return_60d_pct-b.sector_return_60d_pct end as alpha_vs_sector_60d_pct,
  case when b.forward_return_120d_pct is not null and b.sector_return_120d_pct is not null
    then b.forward_return_120d_pct-b.sector_return_120d_pct end as alpha_vs_sector_120d_pct,
  case when b.forward_return_250d_pct is not null and b.sector_return_250d_pct is not null
    then b.forward_return_250d_pct-b.sector_return_250d_pct end as alpha_vs_sector_250d_pct,
  case when b.evaluated_sessions>=20 then b.mfe_20d_pct>=10 end as hit_up_10pct_20d,
  case when b.evaluated_sessions>=60 then b.mfe_60d_pct>=20 end as hit_up_20pct_60d,
  case when b.evaluated_sessions>=120 then b.mfe_120d_pct>=50 end as hit_up_50pct_120d,
  case when b.evaluated_sessions>=250 then b.mfe_250d_pct>=100 end as hit_up_100pct_250d,
  case when b.evaluated_sessions>=250 then b.forward_return_250d_pct>=100 end as close_multibagger_250d,
  case when b.evaluated_sessions>=20 then b.mae_20d_pct<=-10 end as hit_down_10pct_20d,
  case when b.evaluated_sessions>=60 then b.mae_60d_pct<=-20 end as hit_down_20pct_60d,
  case when b.evaluated_sessions>=120 then b.mae_120d_pct<=-30 end as hit_down_30pct_120d,
  case
    when b.evaluated_sessions>=250 then 'MATURE_250D'
    when b.evaluated_sessions>=120 then 'MATURE_120D'
    when b.evaluated_sessions>=60 then 'MATURE_60D'
    when b.evaluated_sessions>=20 then 'MATURE_20D'
    when b.evaluated_sessions>=5 then 'MATURE_5D'
    when b.evaluated_sessions>=1 then 'PARTIAL'
    else 'PENDING'
  end as outcome_maturity_state,
  'OFFICIAL_IDX_FORWARD_OUTCOME_NOT_FEATURE'::text as outcome_semantics,
  'MARKET_OUTCOME_V4_1'::text as outcome_version
from base b;

revoke all on public.flow_market_learning_outcomes_v4 from public,anon,authenticated;
grant select on public.flow_market_learning_outcomes_v4 to service_role;

create or replace view public.flow_market_memory_quality_summary_v4
with (security_invoker=true) as
select
  count(*)::integer as manifest_sessions,
  min(as_of_date) as first_manifest_date,
  max(as_of_date) as last_manifest_date,
  min(stock_rows)::integer as min_stock_rows,
  max(stock_rows)::integer as max_stock_rows,
  round(avg(stock_rows),2) as avg_stock_rows,
  count(*) filter(where manifest_state='FULL_ADVANCED')::integer as full_advanced_sessions,
  count(*) filter(where manifest_state='BASE_MARKET')::integer as base_market_sessions,
  count(*) filter(where snapshot_mode='LIVE_CAPTURE')::integer as live_capture_sessions,
  count(*) filter(where snapshot_mode='HISTORICAL_RECONSTRUCTION')::integer as historical_reconstruction_sessions,
  count(*) filter(where not source_verified)::integer as unverified_manifest_sessions,
  count(*) filter(where stock_rows<800 or residual_rows<800 or broker_regime_rows<>1)::integer as bad_core_sessions,
  case
    when count(*)>=250
      and min(stock_rows)>=800
      and min(residual_rows)>=800
      and count(*) filter(where not source_verified)=0
      and count(*) filter(where stock_rows<800 or residual_rows<800 or broker_regime_rows<>1)=0
      then 'PHASE4B_READY'
    else 'PHASE4B_NOT_READY'
  end as phase4b_gate_state,
  'MARKET_MEMORY_V4_1'::text as feature_contract
from public.flow_market_memory_manifest_v4
where feature_contract='MARKET_MEMORY_V4_1';

revoke all on public.flow_market_memory_quality_summary_v4 from public,anon,authenticated;
grant select on public.flow_market_memory_quality_summary_v4 to service_role;

comment on table public.flow_market_memory_manifest_v4 is
'Phase 4B compact immutable market-memory manifest. Raw official panels are referenced in versioned views rather than duplicated to protect free-tier storage.';
comment on view public.flow_market_learning_panel_v4 is
'Leakage-safe versioned feature panel reconstructed only from as-of evidence. Current issuer sector classification is explicitly tagged as non-historical.';
comment on view public.flow_market_learning_outcomes_v4 is
'Forward outcome labels (+1/+5/+10/+20/+60/+120/+250 sessions, MFE/MAE and benchmark alpha). Outcomes are targets only and must never feed the originating feature row.';

-- Daily market-memory manifest after Phase 3C and Phase 4A calibration.
do $$
declare j record;
begin
  for j in select jobid from cron.job where jobname='flow-market-memory-v4-daily'
  loop
    perform cron.unschedule(j.jobid);
  end loop;
end $$;

select cron.schedule(
  'flow-market-memory-v4-daily',
  '24 11 * * 1-5',
  $$select public.flow_capture_market_memory_manifest_v4(
      (now() at time zone 'Asia/Jakarta')::date,
      'LIVE_CAPTURE'
    );$$
);
