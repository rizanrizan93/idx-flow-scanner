-- Phase 4C: leakage-safe, storage-bounded market-wide factor discovery.
-- Discovery only: this migration does NOT change production scoring, gates, or weights.
-- All forward metrics are targets. Clean paths exclude verified share-structure events.
-- Interaction search is pre-registered and bounded; no Cartesian brute force is allowed.

create or replace function public.flow_normal_two_sided_p_v4(p_z double precision)
returns double precision
language sql
immutable
strict
parallel safe
as $$
with x as (
  select abs(p_z) as z
), t as (
  select z, 1.0/(1.0+0.2316419*z) as q
  from x
), cdf as (
  select 1.0 -
    (exp(-0.5*z*z)/sqrt(2.0*pi())) *
    (0.319381530*q + -0.356563782*power(q,2) + 1.781477937*power(q,3)
      + -1.821255978*power(q,4) + 1.330274429*power(q,5)) as v
  from t
)
select greatest(0.0,least(1.0,2.0*(1.0-v))) from cdf;
$$;
revoke all on function public.flow_normal_two_sided_p_v4(double precision) from public,anon,authenticated;
grant execute on function public.flow_normal_two_sided_p_v4(double precision) to service_role;

create or replace view public.flow_market_learning_labels_clean_v4c
with (security_invoker=true) as
with stock5 as (
  select
    s.trade_date as as_of_date,
    s.ticker,
    s.close as entry_close,
    lead(s.trade_date,5) over w as target_date_5d,
    lead(s.close,5) over w as close_5d,
    max(s.high) over (
      partition by s.ticker order by s.trade_date
      rows between 1 following and 5 following
    ) as high_5d,
    min(s.low) over (
      partition by s.ticker order by s.trade_date
      rows between 1 following and 5 following
    ) as low_5d
  from public.flow_official_stock_summary s
  where s.source='IDX_OFFICIAL_STOCK_SUMMARY' and s.source_verified
  window w as (partition by s.ticker order by s.trade_date)
), index5 as (
  select
    i.trade_date,
    i.index_code,
    i.close,
    lead(i.close,5) over(partition by i.index_code order by i.trade_date) as close_5d
  from public.flow_official_index_summary i
  where i.source_verified
), x as (
  select
    l.*,
    s.target_date_5d,
    s.close_5d,
    s.high_5d,
    s.low_5d,
    ih.close as ihsg_close,
    ih.close_5d as ihsg_close_5d,
    si.close as sector_close,
    si.close_5d as sector_close_5d,
    exists (
      select 1
      from public.flow_capital_action_evidence a
      where a.ticker=l.ticker
        and a.source_verified
        and a.event_type in (
          'STOCK_SPLIT','CAPITAL_REDUCTION','BONUS_SHARES','STOCK_DIVIDEND',
          'RIGHTS_ISSUE','PRIVATE_PLACEMENT','CONVERSION','WARRANT_EXERCISE','MERGER'
        )
        and a.event_date>l.as_of_date
        and s.target_date_5d is not null
        and a.event_date<=s.target_date_5d
    ) as share_structure_event_5d
  from public.flow_market_learning_labels_v4 l
  join stock5 s on s.as_of_date=l.as_of_date and s.ticker=l.ticker
  left join index5 ih on ih.trade_date=l.as_of_date and ih.index_code='COMPOSITE'
  left join index5 si on si.trade_date=l.as_of_date and si.index_code=l.sector_index_code
)
select
  x.*,
  case when x.target_date_5d is not null and not x.share_structure_event_5d and x.entry_close>0
    then 100.0*(x.close_5d/x.entry_close-1.0) end as clean_forward_return_5d_pct,
  case when x.target_date_5d is not null and not x.share_structure_event_5d and x.entry_close>0
    then 100.0*(x.high_5d/x.entry_close-1.0) end as clean_mfe_5d_pct,
  case when x.target_date_5d is not null and not x.share_structure_event_5d and x.entry_close>0
    then 100.0*(x.low_5d/x.entry_close-1.0) end as clean_mae_5d_pct,
  case when x.target_date_5d is not null and not x.share_structure_event_5d
      and x.entry_close>0 and x.ihsg_close>0 and x.ihsg_close_5d is not null
    then 100.0*(x.close_5d/x.entry_close-1.0)-100.0*(x.ihsg_close_5d/x.ihsg_close-1.0) end
    as clean_alpha_vs_ihsg_5d_pct,
  case when x.target_date_5d is not null and not x.share_structure_event_5d
      and x.entry_close>0 and x.sector_close>0 and x.sector_close_5d is not null
    then 100.0*(x.close_5d/x.entry_close-1.0)-100.0*(x.sector_close_5d/x.sector_close-1.0) end
    as clean_alpha_vs_sector_5d_pct,
  case when not x.share_structure_event_20d then x.forward_return_20d_pct end as clean_forward_return_20d_pct,
  case when not x.share_structure_event_20d then x.mfe_20d_pct end as clean_mfe_20d_pct,
  case when not x.share_structure_event_20d then x.mae_20d_pct end as clean_mae_20d_pct,
  case when not x.share_structure_event_20d then x.alpha_vs_ihsg_20d_pct end as clean_alpha_vs_ihsg_20d_pct,
  case when not x.share_structure_event_20d then x.alpha_vs_sector_20d_pct end as clean_alpha_vs_sector_20d_pct,
  case when not x.share_structure_event_60d then x.forward_return_60d_pct end as clean_forward_return_60d_pct,
  case when not x.share_structure_event_60d then x.mfe_60d_pct end as clean_mfe_60d_pct,
  case when not x.share_structure_event_60d then x.mae_60d_pct end as clean_mae_60d_pct,
  case when not x.share_structure_event_60d then x.alpha_vs_ihsg_60d_pct end as clean_alpha_vs_ihsg_60d_pct,
  case when not x.share_structure_event_60d then x.alpha_vs_sector_60d_pct end as clean_alpha_vs_sector_60d_pct,
  case when not x.share_structure_event_120d then x.forward_return_120d_pct end as clean_forward_return_120d_pct,
  case when not x.share_structure_event_120d then x.mfe_120d_pct end as clean_mfe_120d_pct,
  case when not x.share_structure_event_120d then x.mae_120d_pct end as clean_mae_120d_pct,
  case when not x.share_structure_event_120d then x.alpha_vs_ihsg_120d_pct end as clean_alpha_vs_ihsg_120d_pct,
  case when not x.share_structure_event_120d then x.alpha_vs_sector_120d_pct end as clean_alpha_vs_sector_120d_pct,
  case when not x.share_structure_event_250d then x.forward_return_250d_pct end as clean_forward_return_250d_pct,
  case when not x.share_structure_event_250d then x.mfe_250d_pct end as clean_mfe_250d_pct,
  case when not x.share_structure_event_250d then x.mae_250d_pct end as clean_mae_250d_pct,
  case when not x.share_structure_event_250d then x.alpha_vs_ihsg_250d_pct end as clean_alpha_vs_ihsg_250d_pct,
  case when not x.share_structure_event_250d then x.alpha_vs_sector_250d_pct end as clean_alpha_vs_sector_250d_pct,
  'CLEAN_CORPORATE_ACTION_GUARDED_OUTCOME_PATH_V4C_1'::text as clean_path_version
from x;
revoke all on public.flow_market_learning_labels_clean_v4c from public,anon,authenticated;
grant select on public.flow_market_learning_labels_clean_v4c to service_role;

create or replace view public.flow_factor_catalog_v4
with (security_invoker=true) as
select * from (values
 ('return_1d_pct'::text,'PRICE_MOMENTUM'::text,'CONTINUOUS'::text,'as-of 1D return'),
 ('return_5d_pct','PRICE_MOMENTUM','CONTINUOUS','as-of 5D return'),
 ('return_20d_pct','PRICE_MOMENTUM','CONTINUOUS','as-of 20D return'),
 ('return_60d_pct','PRICE_MOMENTUM','CONTINUOUS','as-of 60D return'),
 ('volatility_range_pct','PRICE_MOMENTUM','CONTINUOUS','same-session high-low range relative to close'),
 ('close_vs_20d_high_pct','PRICE_MOMENTUM','CONTINUOUS','distance to trailing 20D high; no future data'),
 ('close_vs_20d_low_pct','PRICE_MOMENTUM','CONTINUOUS','distance to trailing 20D low; no future data'),
 ('foreign_net_volume_pct','FLOW_LIQUIDITY','CONTINUOUS','official foreign net volume normalized by stock volume'),
 ('tradable_float_pct','FLOW_LIQUIDITY','CONTINUOUS','official tradable/listed shares ratio'),
 ('market_turnover_share_pct','FLOW_LIQUIDITY','CONTINUOUS','stock share of market turnover'),
 ('sector_turnover_share_pct','FLOW_LIQUIDITY','CONTINUOUS','stock share of current-classification sector turnover'),
 ('turnover_residual_z','FLOW_LIQUIDITY','CONTINUOUS','market-sector-volatility residual turnover z'),
 ('volume_residual_z','FLOW_LIQUIDITY','CONTINUOUS','market-sector-volatility residual volume z'),
 ('frequency_residual_z','FLOW_LIQUIDITY','CONTINUOUS','market-sector-volatility residual frequency z'),
 ('stock_residual_activity_z','FLOW_LIQUIDITY','CONTINUOUS','combined stock residual activity z'),
 ('market_value_z60','MARKET_REGIME','CONTINUOUS','market traded-value 60-session z'),
 ('market_volume_z60','MARKET_REGIME','CONTINUOUS','market volume 60-session z'),
 ('market_frequency_z60','MARKET_REGIME','CONTINUOUS','market frequency 60-session z'),
 ('top10_value_share_pct','MARKET_REGIME','CONTINUOUS','top-10 broker value concentration'),
 ('activity_breadth_pct','MARKET_REGIME','CONTINUOUS','high-activity broker breadth'),
 ('market_activity_intensity_z','MARKET_REGIME','CONTINUOUS','market broker activity intensity z'),
 ('phase3a_score','ADVANCED_BROKER','CONTINUOUS','co-activity affinity score; NOT broker buy/sell'),
 ('phase3b_score','ADVANCED_BROKER','CONTINUOUS','ticker affinity breadth score; NOT broker buy/sell'),
 ('phase3c_score','ADVANCED_BROKER','CONTINUOUS','coalition co-activity profile score; NOT coordinated trading proof'),
 ('advanced_broker_score','ADVANCED_BROKER','CONTINUOUS','Phase 4A advanced boost-only evidence score'),
 ('risk_event_20d_count','RISK_ACTION','EVENT','verified official risk-event presence in prior 20D'),
 ('capital_action_90d_count','RISK_ACTION','EVENT','verified capital-action presence in prior 90D'),
 ('controller_ownership_pct','OWNERSHIP','CONTINUOUS','ownership observed on or before as-of date')
) as f(factor_name,factor_family,factor_kind,factor_semantics);
revoke all on public.flow_factor_catalog_v4 from public,anon,authenticated;
grant select on public.flow_factor_catalog_v4 to service_role;

create or replace view public.flow_factor_interaction_catalog_v4
with (security_invoker=true) as
select * from (values
 ('FOREIGN_X_RESIDUAL'::text,'foreign_net_volume_pct'::text,'stock_residual_activity_z'::text),
 ('MARKET_INTENSITY_X_RESIDUAL','market_activity_intensity_z','stock_residual_activity_z'),
 ('FOREIGN_X_SECTOR_TURNOVER','foreign_net_volume_pct','sector_turnover_share_pct'),
 ('PHASE3B_X_PRICE_EXTENSION','phase3b_score','close_vs_20d_high_pct'),
 ('ADVANCED_X_PRICE_EXTENSION','advanced_broker_score','close_vs_20d_high_pct'),
 ('LIQUIDITY_X_RESIDUAL','market_turnover_share_pct','stock_residual_activity_z'),
 ('FLOAT_X_RESIDUAL','tradable_float_pct','stock_residual_activity_z'),
 ('RISK_X_RESIDUAL','risk_event_20d_count','stock_residual_activity_z'),
 ('CAPITAL_ACTION_X_FOREIGN','capital_action_90d_count','foreign_net_volume_pct'),
 ('VOLUME_RESIDUAL_X_MOMENTUM','volume_residual_z','return_20d_pct')
) as x(interaction_name,factor_a,factor_b);
revoke all on public.flow_factor_interaction_catalog_v4 from public,anon,authenticated;
grant select on public.flow_factor_interaction_catalog_v4 to service_role;

create table if not exists public.flow_factor_discovery_v4 (
  discovery_as_of date not null,
  discovery_contract text not null default 'FACTOR_DISCOVERY_V4_1',
  factor_name text not null,
  factor_family text not null,
  factor_kind text not null,
  factor_semantics text not null,
  horizon_days integer not null,
  stability_window text not null,
  outcome_universe_count integer not null,
  sample_count integer not null,
  missingness_pct double precision,
  mean_forward_return_pct double precision,
  median_forward_return_pct double precision,
  positive_return_rate_pct double precision,
  clean_target_rate_pct double precision,
  clean_loser_rate_pct double precision,
  clean_multibagger_rate_pct double precision,
  mean_mfe_pct double precision,
  mean_mae_pct double precision,
  mean_ihsg_alpha_pct double precision,
  mean_sector_alpha_pct double precision,
  bottom_bin_count integer,
  top_bin_count integer,
  bottom_bin_mean_return_pct double precision,
  top_bin_mean_return_pct double precision,
  top_minus_bottom_return_pct double precision,
  effect_z double precision,
  p_value double precision,
  fdr_q_value double precision,
  monotonicity_corr double precision,
  nonlinear_shape text,
  stability_windows integer not null default 0,
  stability_sign_agreement_pct double precision,
  regime_group_count integer not null default 0,
  regime_sign_agreement_pct double precision,
  robustness_state text not null default 'PENDING_FDR_STABILITY',
  challenger_eligible boolean not null default false,
  bin_stats jsonb not null default '[]'::jsonb,
  source text not null default 'DERIVED_MARKET_MEMORY_V4',
  source_verified boolean not null default true,
  provenance_state text not null default 'LEAKAGE_SAFE_CLEAN_LABEL_DISCOVERY',
  calculated_at timestamptz not null default now(),
  primary key(discovery_as_of,discovery_contract,factor_name,horizon_days,stability_window),
  constraint flow_factor_discovery_v4_window_ck check(stability_window in ('ALL','EARLY','MIDDLE','RECENT')),
  constraint flow_factor_discovery_v4_horizon_ck check(horizon_days in (5,20,60,120,250))
);
alter table public.flow_factor_discovery_v4 enable row level security;
revoke all on table public.flow_factor_discovery_v4 from public,anon,authenticated;
grant select,insert,update,delete on table public.flow_factor_discovery_v4 to service_role;

create table if not exists public.flow_factor_interactions_v4 (
  discovery_as_of date not null,
  discovery_contract text not null default 'FACTOR_DISCOVERY_V4_1',
  interaction_name text not null,
  factor_a text not null,
  factor_b text not null,
  horizon_days integer not null,
  stability_window text not null,
  sample_count integer not null,
  high_high_count integer not null,
  baseline_mean_return_pct double precision,
  factor_a_high_mean_return_pct double precision,
  factor_b_high_mean_return_pct double precision,
  high_high_mean_return_pct double precision,
  interaction_excess_return_pct double precision,
  high_high_clean_target_rate_pct double precision,
  effect_z double precision,
  p_value double precision,
  fdr_q_value double precision,
  stability_windows integer not null default 0,
  stability_sign_agreement_pct double precision,
  robustness_state text not null default 'PENDING_FDR_STABILITY',
  source text not null default 'DERIVED_MARKET_MEMORY_V4',
  source_verified boolean not null default true,
  provenance_state text not null default 'BOUNDED_PRE_REGISTERED_INTERACTION_DISCOVERY',
  calculated_at timestamptz not null default now(),
  primary key(discovery_as_of,discovery_contract,interaction_name,horizon_days,stability_window),
  constraint flow_factor_interactions_v4_window_ck check(stability_window in ('ALL','EARLY','MIDDLE','RECENT')),
  constraint flow_factor_interactions_v4_horizon_ck check(horizon_days in (20,60,120))
);
alter table public.flow_factor_interactions_v4 enable row level security;
revoke all on table public.flow_factor_interactions_v4 from public,anon,authenticated;
grant select,insert,update,delete on table public.flow_factor_interactions_v4 to service_role;

create table if not exists public.flow_factor_regime_effects_v4 (
  discovery_as_of date not null,
  discovery_contract text not null default 'FACTOR_DISCOVERY_V4_1',
  factor_name text not null,
  horizon_days integer not null,
  regime_type text not null,
  regime_value text not null,
  sample_count integer not null,
  bottom_quintile_count integer not null,
  top_quintile_count integer not null,
  bottom_mean_return_pct double precision,
  top_mean_return_pct double precision,
  top_minus_bottom_return_pct double precision,
  top_clean_target_rate_pct double precision,
  effect_z double precision,
  p_value double precision,
  direction_matches_all boolean,
  classification_state text not null,
  source text not null default 'DERIVED_MARKET_MEMORY_V4',
  source_verified boolean not null default true,
  provenance_state text not null default 'REGIME_CONDITIONED_DISCOVERY',
  calculated_at timestamptz not null default now(),
  primary key(discovery_as_of,discovery_contract,factor_name,horizon_days,regime_type,regime_value)
);
alter table public.flow_factor_regime_effects_v4 enable row level security;
revoke all on table public.flow_factor_regime_effects_v4 from public,anon,authenticated;
grant select,insert,update,delete on table public.flow_factor_regime_effects_v4 to service_role;

create table if not exists public.flow_factor_discovery_snapshot_v4 (
  discovery_as_of date not null,
  discovery_contract text not null default 'FACTOR_DISCOVERY_V4_1',
  feature_contract text not null,
  label_version text not null,
  clean_path_version text not null,
  first_feature_date date not null,
  last_feature_date date not null,
  factor_catalog_count integer not null,
  interaction_catalog_count integer not null,
  factor_result_rows integer not null,
  interaction_result_rows integer not null,
  regime_result_rows integer not null,
  robust_factor_rows integer not null,
  challenger_factor_rows integer not null,
  robust_interaction_rows integer not null,
  production_scoring_changed boolean not null default false,
  discovery_state text not null,
  source text not null default 'DERIVED_MARKET_MEMORY_V4',
  source_verified boolean not null default true,
  provenance_state text not null default 'PHASE4C_DISCOVERY_SNAPSHOT',
  captured_at timestamptz not null default now(),
  primary key(discovery_as_of,discovery_contract),
  constraint flow_factor_discovery_snapshot_v4_prod_ck check(production_scoring_changed=false)
);
alter table public.flow_factor_discovery_snapshot_v4 enable row level security;
revoke all on table public.flow_factor_discovery_snapshot_v4 from public,anon,authenticated;
grant select,insert,update,delete on table public.flow_factor_discovery_snapshot_v4 to service_role;

create or replace function public.flow_prepare_phase4c_temp_v4()
returns integer
language plpgsql
security invoker
set search_path=pg_catalog,public
as $$
declare v_rows integer;
begin
  drop table if exists pg_temp.flow_phase4c_base;
  create temp table flow_phase4c_base on commit drop as
  with dm as (
    select as_of_date,
      case ntile(3) over(order by as_of_date)
        when 1 then 'EARLY' when 2 then 'MIDDLE' else 'RECENT' end as stability_bucket
    from public.flow_market_memory_manifest_v4
    where feature_contract='MARKET_MEMORY_V4_1'
  ), joined as (
    select
      p.as_of_date,p.ticker,p.sector,p.broker_market_regime,p.volatility_bucket,p.traded_value,
      dm.stability_bucket,
      p.return_1d_pct,p.return_5d_pct,p.return_20d_pct,p.return_60d_pct,
      p.volatility_range_pct,p.close_vs_20d_high_pct,p.close_vs_20d_low_pct,
      p.foreign_net_volume_pct,p.tradable_float_pct,p.market_turnover_share_pct,p.sector_turnover_share_pct,
      p.turnover_residual_z,p.volume_residual_z,p.frequency_residual_z,p.stock_residual_activity_z,
      p.market_value_z60,p.market_volume_z60,p.market_frequency_z60,p.top10_value_share_pct,
      p.activity_breadth_pct,p.market_activity_intensity_z,
      p.phase3a_score,p.phase3b_score,p.phase3c_score,p.advanced_broker_score,
      p.risk_event_20d_count,p.capital_action_90d_count,p.controller_ownership_pct,
      c.clean_forward_return_5d_pct,c.clean_mfe_5d_pct,c.clean_mae_5d_pct,
      c.clean_alpha_vs_ihsg_5d_pct,c.clean_alpha_vs_sector_5d_pct,
      c.clean_forward_return_20d_pct,c.clean_mfe_20d_pct,c.clean_mae_20d_pct,
      c.clean_alpha_vs_ihsg_20d_pct,c.clean_alpha_vs_sector_20d_pct,
      c.clean_forward_return_60d_pct,c.clean_mfe_60d_pct,c.clean_mae_60d_pct,
      c.clean_alpha_vs_ihsg_60d_pct,c.clean_alpha_vs_sector_60d_pct,
      c.clean_forward_return_120d_pct,c.clean_mfe_120d_pct,c.clean_mae_120d_pct,
      c.clean_alpha_vs_ihsg_120d_pct,c.clean_alpha_vs_sector_120d_pct,
      c.clean_forward_return_250d_pct,c.clean_mfe_250d_pct,c.clean_mae_250d_pct,
      c.clean_alpha_vs_ihsg_250d_pct,c.clean_alpha_vs_sector_250d_pct,
      c.clean_hit_up_10pct_20d,c.clean_hit_down_10pct_20d,
      c.clean_hit_up_20pct_60d,c.clean_hit_down_20pct_60d,
      c.clean_hit_up_50pct_120d,c.clean_hit_down_30pct_120d,
      c.clean_hit_up_100pct_250d,c.clean_close_multibagger_250d,
      ntile(5) over(partition by p.as_of_date order by p.traded_value nulls first) as liquidity_bucket
    from public.flow_market_learning_panel_v4 p
    join dm on dm.as_of_date=p.as_of_date
    join public.flow_market_learning_labels_clean_v4c c
      on c.as_of_date=p.as_of_date and c.ticker=p.ticker and c.feature_contract=p.feature_contract
    where p.feature_contract='MARKET_MEMORY_V4_1' and p.source_verified
  )
  select * from joined;
  get diagnostics v_rows=row_count;
  analyze pg_temp.flow_phase4c_base;
  return v_rows;
end;
$$;
revoke all on function public.flow_prepare_phase4c_temp_v4() from public,anon,authenticated;
grant execute on function public.flow_prepare_phase4c_temp_v4() to service_role;

create or replace function public.flow_refresh_factor_discovery_one_v4(p_factor_name text)
returns integer
language plpgsql
security invoker
set search_path=pg_catalog,public
as $$
declare
  v_asof date;
  v_family text;
  v_kind text;
  v_semantics text;
  v_sql text;
  v_rows integer;
begin
  select factor_family,factor_kind,factor_semantics
  into v_family,v_kind,v_semantics
  from public.flow_factor_catalog_v4 where factor_name=p_factor_name;
  if v_family is null then raise exception 'Unknown Phase4C factor %',p_factor_name; end if;
  if to_regclass('pg_temp.flow_phase4c_base') is null then
    raise exception 'Phase4C temp base is not prepared';
  end if;
  select max(as_of_date) into v_asof from public.flow_market_memory_manifest_v4
  where feature_contract='MARKET_MEMORY_V4_1';
  delete from public.flow_factor_discovery_v4
  where discovery_as_of=v_asof and discovery_contract='FACTOR_DISCOVERY_V4_1' and factor_name=p_factor_name;

  v_sql := format($q$
    with base as (
      select b.*,%1$I::double precision as factor_value,w.stability_window,
        h.horizon_days,h.clean_return,h.mfe,h.mae,h.ihsg_alpha,h.sector_alpha,h.winner,h.loser,h.multi
      from pg_temp.flow_phase4c_base b
      cross join lateral (values ('ALL'::text),(b.stability_bucket::text)) w(stability_window)
      cross join lateral (values
        (5,b.clean_forward_return_5d_pct::double precision,b.clean_mfe_5d_pct::double precision,b.clean_mae_5d_pct::double precision,b.clean_alpha_vs_ihsg_5d_pct::double precision,b.clean_alpha_vs_sector_5d_pct::double precision,null::boolean,null::boolean,null::boolean),
        (20,b.clean_forward_return_20d_pct::double precision,b.clean_mfe_20d_pct::double precision,b.clean_mae_20d_pct::double precision,b.clean_alpha_vs_ihsg_20d_pct::double precision,b.clean_alpha_vs_sector_20d_pct::double precision,b.clean_hit_up_10pct_20d,b.clean_hit_down_10pct_20d,null::boolean),
        (60,b.clean_forward_return_60d_pct::double precision,b.clean_mfe_60d_pct::double precision,b.clean_mae_60d_pct::double precision,b.clean_alpha_vs_ihsg_60d_pct::double precision,b.clean_alpha_vs_sector_60d_pct::double precision,b.clean_hit_up_20pct_60d,b.clean_hit_down_20pct_60d,null::boolean),
        (120,b.clean_forward_return_120d_pct::double precision,b.clean_mfe_120d_pct::double precision,b.clean_mae_120d_pct::double precision,b.clean_alpha_vs_ihsg_120d_pct::double precision,b.clean_alpha_vs_sector_120d_pct::double precision,b.clean_hit_up_50pct_120d,b.clean_hit_down_30pct_120d,null::boolean),
        (250,b.clean_forward_return_250d_pct::double precision,b.clean_mfe_250d_pct::double precision,b.clean_mae_250d_pct::double precision,b.clean_alpha_vs_ihsg_250d_pct::double precision,b.clean_alpha_vs_sector_250d_pct::double precision,b.clean_hit_up_100pct_250d,null::boolean,b.clean_close_multibagger_250d)
      ) h(horizon_days,clean_return,mfe,mae,ihsg_alpha,sector_alpha,winner,loser,multi)
    ), denom as (
      select stability_window,horizon_days,
        count(*) filter(where clean_return is not null)::integer as outcome_n,
        count(*) filter(where clean_return is not null and factor_value is not null)::integer as factor_n
      from base group by 1,2
    ), ranked as (
      select *,case when %2$L='EVENT'
        then case when factor_value>0 then 2 else 1 end
        else ntile(10) over(partition by stability_window,horizon_days order by factor_value)
      end as factor_bin
      from base where clean_return is not null and factor_value is not null
    ), bins as (
      select stability_window,horizon_days,factor_bin,
        count(*)::integer as n,avg(clean_return) as mean_ret,stddev_samp(clean_return) as sd_ret,
        avg(case when winner is null then null else winner::int::double precision end)*100.0 as winner_rate,
        jsonb_build_object('bin',factor_bin,'n',count(*),'mean_return_pct',round(avg(clean_return)::numeric,6),
          'median_return_pct',round(percentile_cont(0.5) within group(order by clean_return)::numeric,6),
          'positive_rate_pct',round((avg((clean_return>0)::int::double precision)*100.0)::numeric,4)) as js
      from ranked group by 1,2,3
    ), b2 as (
      select bins.*,min(factor_bin) over(partition by stability_window,horizon_days) as min_bin,
        max(factor_bin) over(partition by stability_window,horizon_days) as max_bin
      from bins
    ), shape as (
      select stability_window,horizon_days,
        corr(factor_bin::double precision,mean_ret) as mono,
        max(n) filter(where factor_bin=min_bin)::integer as bottom_n,
        max(n) filter(where factor_bin=max_bin)::integer as top_n,
        max(mean_ret) filter(where factor_bin=min_bin) as bottom_mean,
        max(mean_ret) filter(where factor_bin=max_bin) as top_mean,
        max(sd_ret) filter(where factor_bin=min_bin) as bottom_sd,
        max(sd_ret) filter(where factor_bin=max_bin) as top_sd,
        avg(mean_ret) filter(where factor_bin between 4 and 7) as mid_mean,
        avg(mean_ret) filter(where factor_bin<=2) as low_mean,
        avg(mean_ret) filter(where factor_bin>=greatest(max_bin-1,2)) as high_mean,
        max(mean_ret) filter(where factor_bin=max_bin-1) as penultimate_mean,
        jsonb_agg(js order by factor_bin) as bin_stats
      from b2 group by 1,2
    ), overall as (
      select stability_window,horizon_days,count(*)::integer as n,
        avg(clean_return) as mean_ret,percentile_cont(0.5) within group(order by clean_return) as median_ret,
        avg((clean_return>0)::int::double precision)*100.0 as positive_rate,
        avg(case when winner is null then null else winner::int::double precision end)*100.0 as winner_rate,
        avg(case when loser is null then null else loser::int::double precision end)*100.0 as loser_rate,
        avg(case when multi is null then null else multi::int::double precision end)*100.0 as multi_rate,
        avg(mfe) as mean_mfe,avg(mae) as mean_mae,avg(ihsg_alpha) as mean_ihsg_alpha,avg(sector_alpha) as mean_sector_alpha
      from ranked group by 1,2
    )
    insert into public.flow_factor_discovery_v4(
      discovery_as_of,discovery_contract,factor_name,factor_family,factor_kind,factor_semantics,horizon_days,stability_window,
      outcome_universe_count,sample_count,missingness_pct,mean_forward_return_pct,median_forward_return_pct,positive_return_rate_pct,
      clean_target_rate_pct,clean_loser_rate_pct,clean_multibagger_rate_pct,mean_mfe_pct,mean_mae_pct,mean_ihsg_alpha_pct,mean_sector_alpha_pct,
      bottom_bin_count,top_bin_count,bottom_bin_mean_return_pct,top_bin_mean_return_pct,top_minus_bottom_return_pct,effect_z,p_value,
      monotonicity_corr,nonlinear_shape,robustness_state,bin_stats)
    select %3$L::date,'FACTOR_DISCOVERY_V4_1',%4$L,%5$L,%2$L,%6$L,o.horizon_days,o.stability_window,
      d.outcome_n,o.n,case when d.outcome_n>0 then 100.0*(1.0-d.factor_n::double precision/d.outcome_n) end,
      o.mean_ret,o.median_ret,o.positive_rate,o.winner_rate,o.loser_rate,o.multi_rate,o.mean_mfe,o.mean_mae,o.mean_ihsg_alpha,o.mean_sector_alpha,
      s.bottom_n,s.top_n,s.bottom_mean,s.top_mean,s.top_mean-s.bottom_mean,
      case when s.bottom_n>1 and s.top_n>1 and coalesce(s.bottom_sd,0)>0 and coalesce(s.top_sd,0)>0
        then (s.top_mean-s.bottom_mean)/sqrt(s.bottom_sd*s.bottom_sd/s.bottom_n+s.top_sd*s.top_sd/s.top_n) end as z,
      case when s.bottom_n>1 and s.top_n>1 and coalesce(s.bottom_sd,0)>0 and coalesce(s.top_sd,0)>0
        then public.flow_normal_two_sided_p_v4((s.top_mean-s.bottom_mean)/sqrt(s.bottom_sd*s.bottom_sd/s.bottom_n+s.top_sd*s.top_sd/s.top_n)) end,
      s.mono,
      case
        when %2$L='EVENT' then 'EVENT_VS_NO_EVENT'
        when s.mono>=0.70 then 'MONOTONIC_UP'
        when s.mono<=-0.70 then 'MONOTONIC_DOWN'
        when s.mid_mean>greatest(coalesce(s.low_mean,-1e9),coalesce(s.high_mean,-1e9))+0.25 then 'INVERTED_U'
        when s.mid_mean<least(coalesce(s.low_mean,1e9),coalesce(s.high_mean,1e9))-0.25 then 'U_SHAPE'
        when s.top_mean<coalesce(s.penultimate_mean,s.top_mean)-0.25 then 'TOP_BIN_CHASE_REVERSAL'
        else 'NON_MONOTONIC' end,
      case when o.n<1000 or coalesce(s.bottom_n,0)<100 or coalesce(s.top_n,0)<100 then 'INSUFFICIENT_SAMPLE' else 'PENDING_FDR_STABILITY' end,
      s.bin_stats
    from overall o join denom d using(stability_window,horizon_days) join shape s using(stability_window,horizon_days);
  $q$,p_factor_name,v_kind,v_asof::text,p_factor_name,v_family,v_semantics);
  execute v_sql;
  get diagnostics v_rows=row_count;
  return v_rows;
end;
$$;
revoke all on function public.flow_refresh_factor_discovery_one_v4(text) from public,anon,authenticated;
grant execute on function public.flow_refresh_factor_discovery_one_v4(text) to service_role;

create or replace function public.flow_recompute_phase4c_fdr_v4()
returns jsonb
language plpgsql
security invoker
set search_path=pg_catalog,public
as $$
declare v_asof date; v_factor_rows integer; v_interaction_rows integer;
begin
  select max(as_of_date) into v_asof from public.flow_market_memory_manifest_v4 where feature_contract='MARKET_MEMORY_V4_1';
  with ranked as (
    select discovery_as_of,discovery_contract,factor_name,horizon_days,stability_window,p_value,
      row_number() over(partition by discovery_as_of,discovery_contract,horizon_days,stability_window order by p_value nulls last,factor_name) as r,
      count(p_value) over(partition by discovery_as_of,discovery_contract,horizon_days,stability_window) as m
    from public.flow_factor_discovery_v4 where discovery_as_of=v_asof
  ), raw as (
    select *,least(1.0,p_value*m/nullif(r,0)) as raw_q from ranked where p_value is not null
  ), adj as (
    select *,least(1.0,min(raw_q) over(partition by discovery_as_of,discovery_contract,horizon_days,stability_window order by r desc rows between unbounded preceding and current row)) as q
    from raw
  )
  update public.flow_factor_discovery_v4 f set fdr_q_value=a.q
  from adj a where f.discovery_as_of=a.discovery_as_of and f.discovery_contract=a.discovery_contract
    and f.factor_name=a.factor_name and f.horizon_days=a.horizon_days and f.stability_window=a.stability_window;

  update public.flow_factor_discovery_v4 f
  set robustness_state=case
    when f.sample_count<1000 or coalesce(f.bottom_bin_count,0)<100 or coalesce(f.top_bin_count,0)<100 then 'INSUFFICIENT_SAMPLE'
    when f.fdr_q_value<=0.10 and abs(f.top_minus_bottom_return_pct)>=case f.horizon_days when 5 then 0.40 when 20 then 1.00 when 60 then 2.00 when 120 then 4.00 else 8.00 end then 'SCREENED_EFFECT'
    else 'NO_ROBUST_EFFECT' end
  where f.discovery_as_of=v_asof;

  with w as (
    select factor_name,horizon_days,
      count(*) filter(where stability_window<>'ALL' and robustness_state<>'INSUFFICIENT_SAMPLE')::integer as valid_windows,
      count(*) filter(where stability_window<>'ALL' and robustness_state<>'INSUFFICIENT_SAMPLE' and top_minus_bottom_return_pct>0)::integer as pos_windows,
      count(*) filter(where stability_window<>'ALL' and robustness_state<>'INSUFFICIENT_SAMPLE' and top_minus_bottom_return_pct<0)::integer as neg_windows
    from public.flow_factor_discovery_v4 where discovery_as_of=v_asof group by 1,2
  )
  update public.flow_factor_discovery_v4 f set
    stability_windows=w.valid_windows,
    stability_sign_agreement_pct=case when w.valid_windows>0 then 100.0*greatest(w.pos_windows,w.neg_windows)/w.valid_windows end,
    robustness_state=case
      when f.robustness_state='SCREENED_EFFECT' and w.valid_windows>=2 and 100.0*greatest(w.pos_windows,w.neg_windows)/w.valid_windows>=66.6667 then 'ROBUST_DISCOVERY_SIGNAL'
      when f.robustness_state='SCREENED_EFFECT' then 'INSUFFICIENT_STABILITY'
      else f.robustness_state end
  from w where f.discovery_as_of=v_asof and f.stability_window='ALL' and f.factor_name=w.factor_name and f.horizon_days=w.horizon_days;

  with ranked as (
    select discovery_as_of,discovery_contract,interaction_name,horizon_days,stability_window,p_value,
      row_number() over(partition by discovery_as_of,discovery_contract,horizon_days,stability_window order by p_value nulls last,interaction_name) as r,
      count(p_value) over(partition by discovery_as_of,discovery_contract,horizon_days,stability_window) as m
    from public.flow_factor_interactions_v4 where discovery_as_of=v_asof
  ), raw as (
    select *,least(1.0,p_value*m/nullif(r,0)) as raw_q from ranked where p_value is not null
  ), adj as (
    select *,least(1.0,min(raw_q) over(partition by discovery_as_of,discovery_contract,horizon_days,stability_window order by r desc rows between unbounded preceding and current row)) as q
    from raw
  )
  update public.flow_factor_interactions_v4 i set fdr_q_value=a.q
  from adj a where i.discovery_as_of=a.discovery_as_of and i.discovery_contract=a.discovery_contract
    and i.interaction_name=a.interaction_name and i.horizon_days=a.horizon_days and i.stability_window=a.stability_window;

  update public.flow_factor_interactions_v4 i set robustness_state=case
    when i.sample_count<1000 or i.high_high_count<100 then 'INSUFFICIENT_SAMPLE'
    when i.fdr_q_value<=0.10 and abs(i.interaction_excess_return_pct)>=case i.horizon_days when 20 then 0.75 when 60 then 1.50 else 2.50 end then 'SCREENED_EFFECT'
    else 'NO_ROBUST_EFFECT' end
  where i.discovery_as_of=v_asof;

  with w as (
    select interaction_name,horizon_days,
      count(*) filter(where stability_window<>'ALL' and robustness_state<>'INSUFFICIENT_SAMPLE')::integer as valid_windows,
      count(*) filter(where stability_window<>'ALL' and robustness_state<>'INSUFFICIENT_SAMPLE' and interaction_excess_return_pct>0)::integer as pos_windows,
      count(*) filter(where stability_window<>'ALL' and robustness_state<>'INSUFFICIENT_SAMPLE' and interaction_excess_return_pct<0)::integer as neg_windows
    from public.flow_factor_interactions_v4 where discovery_as_of=v_asof group by 1,2
  )
  update public.flow_factor_interactions_v4 i set
    stability_windows=w.valid_windows,
    stability_sign_agreement_pct=case when w.valid_windows>0 then 100.0*greatest(w.pos_windows,w.neg_windows)/w.valid_windows end,
    robustness_state=case
      when i.robustness_state='SCREENED_EFFECT' and w.valid_windows>=2 and 100.0*greatest(w.pos_windows,w.neg_windows)/w.valid_windows>=66.6667 then 'ROBUST_DISCOVERY_SIGNAL'
      when i.robustness_state='SCREENED_EFFECT' then 'INSUFFICIENT_STABILITY'
      else i.robustness_state end
  from w where i.discovery_as_of=v_asof and i.stability_window='ALL' and i.interaction_name=w.interaction_name and i.horizon_days=w.horizon_days;

  select count(*) into v_factor_rows from public.flow_factor_discovery_v4 where discovery_as_of=v_asof;
  select count(*) into v_interaction_rows from public.flow_factor_interactions_v4 where discovery_as_of=v_asof;
  return jsonb_build_object('status','OK','as_of_date',v_asof,'factor_rows',v_factor_rows,'interaction_rows',v_interaction_rows);
end;
$$;
revoke all on function public.flow_recompute_phase4c_fdr_v4() from public,anon,authenticated;
grant execute on function public.flow_recompute_phase4c_fdr_v4() to service_role;

create or replace function public.flow_refresh_factor_family_v4(p_factor_family text)
returns jsonb
language plpgsql
security invoker
set search_path=pg_catalog,public
as $$
declare r record; v_base integer; v_factor_count integer:=0; v_rows integer:=0;
begin
  if not exists(select 1 from public.flow_factor_catalog_v4 where factor_family=p_factor_family) then
    raise exception 'Unknown Phase4C factor family %',p_factor_family;
  end if;
  v_base:=public.flow_prepare_phase4c_temp_v4();
  for r in select factor_name from public.flow_factor_catalog_v4 where factor_family=p_factor_family order by factor_name loop
    v_rows:=v_rows+public.flow_refresh_factor_discovery_one_v4(r.factor_name);
    v_factor_count:=v_factor_count+1;
  end loop;
  perform public.flow_recompute_phase4c_fdr_v4();
  return jsonb_build_object('status','OK','family',p_factor_family,'base_rows',v_base,'factors',v_factor_count,'result_rows',v_rows);
end;
$$;
revoke all on function public.flow_refresh_factor_family_v4(text) from public,anon,authenticated;
grant execute on function public.flow_refresh_factor_family_v4(text) to service_role;

create or replace function public.flow_refresh_interactions_v4()
returns jsonb
language plpgsql
security invoker
set search_path=pg_catalog,public
as $$
declare r record; v_asof date; v_base integer; v_sql text; v_rows integer:=0; v_n integer;
begin
  v_base:=public.flow_prepare_phase4c_temp_v4();
  select max(as_of_date) into v_asof from public.flow_market_memory_manifest_v4 where feature_contract='MARKET_MEMORY_V4_1';
  delete from public.flow_factor_interactions_v4 where discovery_as_of=v_asof and discovery_contract='FACTOR_DISCOVERY_V4_1';
  for r in select * from public.flow_factor_interaction_catalog_v4 order by interaction_name loop
    v_sql:=format($q$
      with base as (
        select b.*,%1$I::double precision as a,%2$I::double precision as z,w.stability_window,
          h.horizon_days,h.ret,h.winner
        from pg_temp.flow_phase4c_base b
        cross join lateral(values('ALL'::text),(b.stability_bucket::text)) w(stability_window)
        cross join lateral(values
          (20,b.clean_forward_return_20d_pct::double precision,b.clean_hit_up_10pct_20d),
          (60,b.clean_forward_return_60d_pct::double precision,b.clean_hit_up_20pct_60d),
          (120,b.clean_forward_return_120d_pct::double precision,b.clean_hit_up_50pct_120d)
        ) h(horizon_days,ret,winner)
        where %1$I is not null and %2$I is not null and h.ret is not null
      ), th as (
        select stability_window,horizon_days,percentile_cont(0.8) within group(order by a) as a80,
          percentile_cont(0.8) within group(order by z) as z80
        from base group by 1,2
      ), tagged as (
        select b.*,t.a80,t.z80,(b.a>=t.a80) as ah,(b.z>=t.z80) as zh
        from base b join th t using(stability_window,horizon_days)
      ), ag as (
        select stability_window,horizon_days,count(*)::integer as n,
          avg(ret) as baseline,avg(ret) filter(where ah) as a_high,avg(ret) filter(where zh) as z_high,
          count(*) filter(where ah and zh)::integer as hh_n,
          avg(ret) filter(where ah and zh) as hh_mean,stddev_samp(ret) filter(where ah and zh) as hh_sd,
          count(*) filter(where not(ah and zh))::integer as rest_n,
          avg(ret) filter(where not(ah and zh)) as rest_mean,stddev_samp(ret) filter(where not(ah and zh)) as rest_sd,
          avg(case when ah and zh and winner is not null then winner::int::double precision end)*100.0 as hh_target
        from tagged group by 1,2
      )
      insert into public.flow_factor_interactions_v4(discovery_as_of,interaction_name,factor_a,factor_b,horizon_days,stability_window,
        sample_count,high_high_count,baseline_mean_return_pct,factor_a_high_mean_return_pct,factor_b_high_mean_return_pct,
        high_high_mean_return_pct,interaction_excess_return_pct,high_high_clean_target_rate_pct,effect_z,p_value,robustness_state)
      select %3$L::date,%4$L,%5$L,%6$L,horizon_days,stability_window,n,hh_n,baseline,a_high,z_high,hh_mean,
        hh_mean-a_high-z_high+baseline,hh_target,
        case when hh_n>1 and rest_n>1 and coalesce(hh_sd,0)>0 and coalesce(rest_sd,0)>0
          then (hh_mean-rest_mean)/sqrt(hh_sd*hh_sd/hh_n+rest_sd*rest_sd/rest_n) end,
        case when hh_n>1 and rest_n>1 and coalesce(hh_sd,0)>0 and coalesce(rest_sd,0)>0
          then public.flow_normal_two_sided_p_v4((hh_mean-rest_mean)/sqrt(hh_sd*hh_sd/hh_n+rest_sd*rest_sd/rest_n)) end,
        case when n<1000 or hh_n<100 then 'INSUFFICIENT_SAMPLE' else 'PENDING_FDR_STABILITY' end
      from ag;
    $q$,r.factor_a,r.factor_b,v_asof::text,r.interaction_name,r.factor_a,r.factor_b);
    execute v_sql;
    get diagnostics v_n=row_count;
    v_rows:=v_rows+v_n;
  end loop;
  perform public.flow_recompute_phase4c_fdr_v4();
  return jsonb_build_object('status','OK','as_of_date',v_asof,'base_rows',v_base,'interaction_catalog_count',(select count(*) from public.flow_factor_interaction_catalog_v4),'result_rows',v_rows);
end;
$$;
revoke all on function public.flow_refresh_interactions_v4() from public,anon,authenticated;
grant execute on function public.flow_refresh_interactions_v4() to service_role;

create or replace function public.flow_refresh_regime_effects_v4()
returns jsonb
language plpgsql
security invoker
set search_path=pg_catalog,public
as $$
declare c record; rg text; v_asof date; v_base integer; v_sql text; v_rows integer:=0; v_n integer; v_regime_expr text; v_ret_col text; v_target_col text;
begin
  v_base:=public.flow_prepare_phase4c_temp_v4();
  select max(as_of_date) into v_asof from public.flow_market_memory_manifest_v4 where feature_contract='MARKET_MEMORY_V4_1';
  delete from public.flow_factor_regime_effects_v4 where discovery_as_of=v_asof and discovery_contract='FACTOR_DISCOVERY_V4_1';
  for c in
    with ranked as (
      select f.*,row_number() over(partition by horizon_days order by abs(top_minus_bottom_return_pct) desc nulls last,factor_name) as rn
      from public.flow_factor_discovery_v4 f
      where discovery_as_of=v_asof and stability_window='ALL' and horizon_days in (5,20,60,120)
        and robustness_state='ROBUST_DISCOVERY_SIGNAL'
    ) select * from ranked where rn<=4
  loop
    v_ret_col:=case c.horizon_days when 5 then 'clean_forward_return_5d_pct' when 20 then 'clean_forward_return_20d_pct' when 60 then 'clean_forward_return_60d_pct' else 'clean_forward_return_120d_pct' end;
    v_target_col:=case c.horizon_days when 20 then 'clean_hit_up_10pct_20d' when 60 then 'clean_hit_up_20pct_60d' when 120 then 'clean_hit_up_50pct_120d' else null end;
    foreach rg in array array['MARKET_REGIME','SECTOR','VOLATILITY_BUCKET','LIQUIDITY_BUCKET'] loop
      v_regime_expr:=case rg
        when 'MARKET_REGIME' then 'coalesce(broker_market_regime,''UNKNOWN'')'
        when 'SECTOR' then 'coalesce(sector,''UNKNOWN'')'
        when 'VOLATILITY_BUCKET' then 'coalesce(volatility_bucket::text,''UNKNOWN'')'
        else '''LIQ_''||liquidity_bucket::text' end;
      v_sql:=format($q$
        with base as (
          select %1$I::double precision as factor_value,%2$I::double precision as ret,%3$s as regime_value,
            %4$s as winner
          from pg_temp.flow_phase4c_base
          where %1$I is not null and %2$I is not null
        ), ranked as (
          select *,ntile(5) over(partition by regime_value order by factor_value) as q
          from base where regime_value<>'UNKNOWN'
        ), ag as (
          select regime_value,count(*)::integer as n,
            count(*) filter(where q=1)::integer as low_n,count(*) filter(where q=5)::integer as high_n,
            avg(ret) filter(where q=1) as low_mean,avg(ret) filter(where q=5) as high_mean,
            stddev_samp(ret) filter(where q=1) as low_sd,stddev_samp(ret) filter(where q=5) as high_sd,
            avg(case when q=5 and winner is not null then winner::int::double precision end)*100.0 as high_target
          from ranked group by regime_value
        )
        insert into public.flow_factor_regime_effects_v4(discovery_as_of,factor_name,horizon_days,regime_type,regime_value,
          sample_count,bottom_quintile_count,top_quintile_count,bottom_mean_return_pct,top_mean_return_pct,top_minus_bottom_return_pct,
          top_clean_target_rate_pct,effect_z,p_value,direction_matches_all,classification_state)
        select %5$L::date,%6$L,%7$s,%8$L,regime_value,n,low_n,high_n,low_mean,high_mean,high_mean-low_mean,high_target,
          case when low_n>1 and high_n>1 and coalesce(low_sd,0)>0 and coalesce(high_sd,0)>0
            then (high_mean-low_mean)/sqrt(low_sd*low_sd/low_n+high_sd*high_sd/high_n) end,
          case when low_n>1 and high_n>1 and coalesce(low_sd,0)>0 and coalesce(high_sd,0)>0
            then public.flow_normal_two_sided_p_v4((high_mean-low_mean)/sqrt(low_sd*low_sd/low_n+high_sd*high_sd/high_n)) end,
          case when %9$s>=0 then high_mean-low_mean>=0 else high_mean-low_mean<0 end,
          case when %8$L='SECTOR' then 'CURRENT_REGISTRY_CLASSIFICATION_NOT_HISTORICAL' else 'AS_OF_OR_DERIVED_REGIME' end
        from ag where n>=200;
      $q$,c.factor_name,v_ret_col,v_regime_expr,coalesce(format('%I',v_target_col),'null::boolean'),v_asof::text,c.factor_name,c.horizon_days,rg,coalesce(c.top_minus_bottom_return_pct,0));
      execute v_sql;
      get diagnostics v_n=row_count;
      v_rows:=v_rows+v_n;
    end loop;
  end loop;

  with s as (
    select r.factor_name,r.horizon_days,count(*) filter(where sample_count>=200 and bottom_quintile_count>=40 and top_quintile_count>=40)::integer as groups,
      avg(case when direction_matches_all then 1.0 else 0.0 end) filter(where sample_count>=200 and bottom_quintile_count>=40 and top_quintile_count>=40)*100.0 as agreement
    from public.flow_factor_regime_effects_v4 r where r.discovery_as_of=v_asof group by 1,2
  )
  update public.flow_factor_discovery_v4 f set regime_group_count=s.groups,regime_sign_agreement_pct=s.agreement,
    challenger_eligible=(f.robustness_state='ROBUST_DISCOVERY_SIGNAL' and s.groups>=6 and s.agreement>=60.0)
  from s where f.discovery_as_of=v_asof and f.stability_window='ALL' and f.factor_name=s.factor_name and f.horizon_days=s.horizon_days;

  return jsonb_build_object('status','OK','as_of_date',v_asof,'base_rows',v_base,'regime_rows',v_rows);
end;
$$;
revoke all on function public.flow_refresh_regime_effects_v4() from public,anon,authenticated;
grant execute on function public.flow_refresh_regime_effects_v4() to service_role;

create or replace function public.flow_finalize_phase4c_v4()
returns jsonb
language plpgsql
security invoker
set search_path=pg_catalog,public
as $$
declare v_asof date; v_first date; v_factors integer; v_interactions integer; v_regimes integer; v_robust integer; v_challenger integer; v_robust_i integer; v_factor_catalog integer; v_interaction_catalog integer; v_complete boolean;
begin
  perform public.flow_recompute_phase4c_fdr_v4();
  select max(as_of_date),min(as_of_date) into v_asof,v_first from public.flow_market_memory_manifest_v4 where feature_contract='MARKET_MEMORY_V4_1';
  select count(*) into v_factor_catalog from public.flow_factor_catalog_v4;
  select count(*) into v_interaction_catalog from public.flow_factor_interaction_catalog_v4;
  select count(*) into v_factors from public.flow_factor_discovery_v4 where discovery_as_of=v_asof;
  select count(*) into v_interactions from public.flow_factor_interactions_v4 where discovery_as_of=v_asof;
  select count(*) into v_regimes from public.flow_factor_regime_effects_v4 where discovery_as_of=v_asof;
  select count(*) into v_robust from public.flow_factor_discovery_v4 where discovery_as_of=v_asof and stability_window='ALL' and robustness_state='ROBUST_DISCOVERY_SIGNAL';
  select count(*) into v_challenger from public.flow_factor_discovery_v4 where discovery_as_of=v_asof and stability_window='ALL' and challenger_eligible;
  select count(*) into v_robust_i from public.flow_factor_interactions_v4 where discovery_as_of=v_asof and stability_window='ALL' and robustness_state='ROBUST_DISCOVERY_SIGNAL';
  v_complete:=v_factor_catalog>=28 and v_interaction_catalog=10
    and (select count(distinct factor_name) from public.flow_factor_discovery_v4 where discovery_as_of=v_asof)=v_factor_catalog
    and (select count(distinct horizon_days) from public.flow_factor_discovery_v4 where discovery_as_of=v_asof)=5
    and (select count(distinct stability_window) from public.flow_factor_discovery_v4 where discovery_as_of=v_asof)=4
    and (select count(distinct interaction_name) from public.flow_factor_interactions_v4 where discovery_as_of=v_asof)=v_interaction_catalog;

  insert into public.flow_factor_discovery_snapshot_v4(discovery_as_of,feature_contract,label_version,clean_path_version,first_feature_date,last_feature_date,
    factor_catalog_count,interaction_catalog_count,factor_result_rows,interaction_result_rows,regime_result_rows,robust_factor_rows,challenger_factor_rows,
    robust_interaction_rows,production_scoring_changed,discovery_state)
  values(v_asof,'MARKET_MEMORY_V4_1','MARKET_LABELS_V4_1','CLEAN_CORPORATE_ACTION_GUARDED_OUTCOME_PATH_V4C_1',v_first,v_asof,
    v_factor_catalog,v_interaction_catalog,v_factors,v_interactions,v_regimes,v_robust,v_challenger,v_robust_i,false,case when v_complete then 'COMPLETE' else 'INCOMPLETE' end)
  on conflict(discovery_as_of,discovery_contract) do update set
    factor_result_rows=excluded.factor_result_rows,interaction_result_rows=excluded.interaction_result_rows,regime_result_rows=excluded.regime_result_rows,
    robust_factor_rows=excluded.robust_factor_rows,challenger_factor_rows=excluded.challenger_factor_rows,robust_interaction_rows=excluded.robust_interaction_rows,
    production_scoring_changed=false,discovery_state=excluded.discovery_state,captured_at=now();
  return jsonb_build_object('status',case when v_complete then 'PHASE4C_READY' else 'PHASE4C_INCOMPLETE' end,'as_of_date',v_asof,
    'factor_rows',v_factors,'interaction_rows',v_interactions,'regime_rows',v_regimes,'robust_factors',v_robust,'challenger_factors',v_challenger,'robust_interactions',v_robust_i);
end;
$$;
revoke all on function public.flow_finalize_phase4c_v4() from public,anon,authenticated;
grant execute on function public.flow_finalize_phase4c_v4() to service_role;

create or replace view public.flow_phase4c_quality_summary
with (security_invoker=true) as
with s as (
  select * from public.flow_factor_discovery_snapshot_v4 order by discovery_as_of desc,captured_at desc limit 1
), acl_ok as (
  select not exists(
    select 1 from information_schema.role_table_grants g
    where g.table_schema='public'
      and g.table_name in ('flow_factor_discovery_v4','flow_factor_interactions_v4','flow_factor_regime_effects_v4','flow_factor_discovery_snapshot_v4')
      and g.grantee in ('PUBLIC','anon','authenticated')
  ) as private_acl
)
select s.*,
  a.private_acl,
  case when s.discovery_state='COMPLETE' and not s.production_scoring_changed and s.source_verified and a.private_acl
    then 'PHASE4C_READY' else 'PHASE4C_NOT_READY' end as phase4c_gate_state
from s cross join acl_ok a;
revoke all on public.flow_phase4c_quality_summary from public,anon,authenticated;
grant select on public.flow_phase4c_quality_summary to service_role;

comment on table public.flow_factor_discovery_v4 is
'Phase 4C discovery-only factor evaluation over clean corporate-action-guarded future outcomes. No production scoring changes.';
comment on table public.flow_factor_interactions_v4 is
'Phase 4C bounded pre-registered interaction discovery. No brute-force Cartesian search.';
comment on table public.flow_factor_regime_effects_v4 is
'Phase 4C regime validation; sector rows explicitly use current-registry classification, not fabricated historical sector membership.';
comment on view public.flow_market_learning_labels_clean_v4c is
'Clean outcome-path extension for Phase 4C, including derived +5-session MFE/MAE and IHSG/sector alpha. Future metrics are targets only and never feature inputs.';
