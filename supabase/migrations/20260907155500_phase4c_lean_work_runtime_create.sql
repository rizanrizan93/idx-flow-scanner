-- Phase 4C runtime-only lean staging table.
-- Paired with a later drop migration after closure; no persistent duplicated panel remains.

create unlogged table public.flow_phase4c_work_base_v4 as
select
  p.as_of_date,p.ticker,p.sector,p.broker_market_regime,p.volatility_bucket,p.traded_value,
  null::text as stability_bucket,
  p.return_1d_pct,p.return_5d_pct,p.return_20d_pct,p.return_60d_pct,
  p.volatility_range_pct,p.close_vs_20d_high_pct,p.close_vs_20d_low_pct,
  p.foreign_net_volume_pct,p.tradable_float_pct,p.market_turnover_share_pct,p.sector_turnover_share_pct,
  p.turnover_residual_z,p.volume_residual_z,p.frequency_residual_z,p.stock_residual_activity_z,
  p.market_value_z60,p.market_volume_z60,p.market_frequency_z60,p.top10_value_share_pct,
  p.activity_breadth_pct,p.market_activity_intensity_z,
  case when p.advanced_3abc_available then p.phase3a_score end as phase3a_score,
  case when p.advanced_3abc_available then p.phase3b_score end as phase3b_score,
  case when p.advanced_3abc_available then p.phase3c_score end as phase3c_score,
  case when p.advanced_3abc_available then p.advanced_broker_score end as advanced_broker_score,
  p.risk_event_20d_count,p.capital_action_90d_count,p.controller_ownership_pct,
  c.clean_forward_return_5d_pct,c.clean_forward_return_20d_pct,c.clean_forward_return_60d_pct,
  c.clean_forward_return_120d_pct,c.clean_forward_return_250d_pct,
  null::integer as liquidity_bucket
from public.flow_market_learning_panel_v4 p
join public.flow_market_learning_labels_clean_v4c c
  on c.as_of_date=p.as_of_date and c.ticker=p.ticker and c.feature_contract=p.feature_contract
where false;

alter table public.flow_phase4c_work_base_v4 enable row level security;
revoke all on public.flow_phase4c_work_base_v4 from public,anon,authenticated;
grant select,insert,delete,truncate on public.flow_phase4c_work_base_v4 to service_role;

comment on table public.flow_phase4c_work_base_v4 is
'RUNTIME_ONLY Phase4C lean staging table. Must be dropped by the paired closure migration after factor/interactions/regime discovery is complete.';
