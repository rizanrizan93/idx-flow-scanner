-- Phase 4C semantic hardening: advanced 3A/3B/3C evidence must be genuinely available.
-- Historical BASE_MARKET rows must not learn zero-filled advanced scores as if observed.

create or replace view public.flow_phase4c_factor_source_v4
with (security_invoker=true) as
select
  p.as_of_date,
  p.feature_contract,
  p.ticker,
  p.sector,
  p.broker_market_regime,
  p.volatility_bucket,
  p.traded_value,
  p.return_1d_pct,
  p.return_5d_pct,
  p.return_20d_pct,
  p.return_60d_pct,
  p.volatility_range_pct,
  p.close_vs_20d_high_pct,
  p.close_vs_20d_low_pct,
  p.foreign_net_volume_pct,
  p.tradable_float_pct,
  p.market_turnover_share_pct,
  p.sector_turnover_share_pct,
  p.turnover_residual_z,
  p.volume_residual_z,
  p.frequency_residual_z,
  p.stock_residual_activity_z,
  p.market_value_z60,
  p.market_volume_z60,
  p.market_frequency_z60,
  p.top10_value_share_pct,
  p.activity_breadth_pct,
  p.market_activity_intensity_z,
  case when p.advanced_3abc_available then p.phase3a_score end as phase3a_score,
  case when p.advanced_3abc_available then p.phase3b_score end as phase3b_score,
  case when p.advanced_3abc_available then p.phase3c_score end as phase3c_score,
  case when p.advanced_3abc_available then p.advanced_broker_score end as advanced_broker_score,
  p.risk_event_20d_count,
  p.capital_action_90d_count,
  p.controller_ownership_pct,
  p.advanced_3abc_available,
  case when p.advanced_3abc_available then p.advanced_broker_evidence_eligible else false end as advanced_broker_evidence_eligible
from public.flow_market_learning_panel_v4 p
where p.feature_contract='MARKET_MEMORY_V4_1';

revoke all on public.flow_phase4c_factor_source_v4 from public,anon,authenticated;
grant select on public.flow_phase4c_factor_source_v4 to service_role;

comment on view public.flow_phase4c_factor_source_v4 is
'Phase4C discovery source. Advanced broker factors are NULL unless the as-of manifest genuinely has FULL_ADVANCED 3A/3B/3C evidence; historical BASE_MARKET absence is never converted into observed zero evidence.';

do $$
declare
  v_proc regprocedure;
  v_def text;
  v_old constant text := 'from public.flow_market_learning_panel_v4 p';
  v_new constant text := 'from public.flow_phase4c_factor_source_v4 p';
begin
  foreach v_proc in array array[
    'public.flow_refresh_factor_slice_v4(text,integer,text)'::regprocedure,
    'public.flow_refresh_interaction_slice_v4(text,integer,text)'::regprocedure,
    'public.flow_refresh_regime_slice_v4(text,integer,text)'::regprocedure
  ]
  loop
    select pg_get_functiondef(v_proc) into v_def;
    if position(v_new in v_def)=0 then
      if position(v_old in v_def)=0 then
        raise exception 'Phase4C source rewrite target not found for %',v_proc;
      end if;
      v_def:=replace(v_def,v_old,v_new);
      execute v_def;
    end if;
  end loop;
end;
$$;

-- Remove any discovery rows produced before this mask existed. They are not valid evidence.
delete from public.flow_factor_discovery_v4
where discovery_contract='FACTOR_DISCOVERY_V4_1'
  and factor_family='ADVANCED_BROKER';

delete from public.flow_factor_interactions_v4
where discovery_contract='FACTOR_DISCOVERY_V4_1'
  and (
    factor_a in ('phase3a_score','phase3b_score','phase3c_score','advanced_broker_score')
    or factor_b in ('phase3a_score','phase3b_score','phase3c_score','advanced_broker_score')
  );

delete from public.flow_factor_regime_effects_v4
where discovery_contract='FACTOR_DISCOVERY_V4_1'
  and factor_name in ('phase3a_score','phase3b_score','phase3c_score','advanced_broker_score');
