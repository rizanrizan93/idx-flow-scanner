-- Phase 4D finalizer contract fix.
-- phase4c_gate_state is computed by the Phase4C quality view; it is not a
-- physical column on flow_factor_discovery_snapshot_v4. Resolve the canonical
-- discovery snapshot from its physical completion/source/scoring invariants.

create or replace function public.flow_finalize_phase4d_historical_v4()
returns jsonb
language plpgsql
security invoker
set search_path=pg_catalog,public
as $$
declare v_asof date; v_c_asof date; v_rows integer;
begin
  select max(as_of_date) into v_asof
  from public.flow_market_memory_manifest_v4
  where feature_contract='MARKET_MEMORY_V4_1';

  select max(discovery_as_of) into v_c_asof
  from public.flow_factor_discovery_snapshot_v4
  where discovery_state='COMPLETE'
    and source_verified
    and not production_scoring_changed;
  if v_c_asof is null then
    raise exception 'No completed verified Phase4C discovery snapshot available';
  end if;

  delete from public.flow_phase4d_candidate_summary_v4 where validation_as_of=v_asof;

  insert into public.flow_phase4d_candidate_summary_v4(
    validation_as_of,entity_type,entity_name,horizon_days,phase4c_challenger,phase4c_robust,
    strict_oos_fold_count,train_selected_folds,oos_direction_match_folds,oos_direction_agreement_pct,
    mean_signed_oos_effect_pct,min_signed_oos_effect_pct,historical_oos_pass,historical_state,
    forward_shadow_required,production_eligible)
  select v_asof,'FACTOR',c.factor_name,c.horizon_days,c.challenger_eligible,(c.robustness_state='ROBUST_DISCOVERY_SIGNAL'),
    count(o.fold_no)::integer,count(*) filter(where o.train_selected)::integer,
    count(*) filter(where o.direction_matches_train)::integer,
    avg(case when o.direction_matches_train is not null then o.direction_matches_train::int::double precision end)*100.0,
    avg(o.signed_oos_effect_pct),min(o.signed_oos_effect_pct),
    case when count(o.fold_no)>=3 and count(*) filter(where o.train_selected)>=2
      and count(*) filter(where o.direction_matches_train)>=2
      and avg(o.signed_oos_effect_pct)>=case c.horizon_days when 5 then .20 when 20 then .50 when 60 then 1.00 else 2.00 end
      and min(o.signed_oos_effect_pct)>=-case c.horizon_days when 5 then .40 when 20 then 1.00 when 60 then 2.00 else 4.00 end
      then true else false end,
    case when count(o.fold_no)=0 then 'INSUFFICIENT_STRICT_OOS_HISTORY'
      when c.challenger_eligible and count(o.fold_no)>=3 and count(*) filter(where o.train_selected)>=2
        and count(*) filter(where o.direction_matches_train)>=2
        and avg(o.signed_oos_effect_pct)>=case c.horizon_days when 5 then .20 when 20 then .50 when 60 then 1.00 else 2.00 end
        and min(o.signed_oos_effect_pct)>=-case c.horizon_days when 5 then .40 when 20 then 1.00 when 60 then 2.00 else 4.00 end
        then 'HISTORICAL_OOS_PASS'
      when c.challenger_eligible then 'HISTORICAL_OOS_FAIL'
      else 'PREREGISTERED_CONTROL' end,
    c.challenger_eligible,false
  from public.flow_factor_discovery_v4 c
  left join public.flow_phase4d_factor_oos_v4 o
    on o.validation_as_of=v_asof and o.factor_name=c.factor_name and o.horizon_days=c.horizon_days
  where c.discovery_as_of=v_c_asof and c.stability_window='ALL'
  group by c.factor_name,c.horizon_days,c.challenger_eligible,c.robustness_state;

  insert into public.flow_phase4d_candidate_summary_v4(
    validation_as_of,entity_type,entity_name,horizon_days,phase4c_challenger,phase4c_robust,
    strict_oos_fold_count,train_selected_folds,oos_direction_match_folds,oos_direction_agreement_pct,
    mean_signed_oos_effect_pct,min_signed_oos_effect_pct,historical_oos_pass,historical_state,
    forward_shadow_required,production_eligible)
  select v_asof,'INTERACTION',c.interaction_name,c.horizon_days,(c.robustness_state='ROBUST_DISCOVERY_SIGNAL'),(c.robustness_state='ROBUST_DISCOVERY_SIGNAL'),
    count(o.fold_no)::integer,count(*) filter(where o.train_selected)::integer,
    count(*) filter(where o.direction_matches_train)::integer,
    avg(case when o.direction_matches_train is not null then o.direction_matches_train::int::double precision end)*100.0,
    avg(o.signed_oos_effect_pct),min(o.signed_oos_effect_pct),
    case when count(o.fold_no)>=3 and count(*) filter(where o.train_selected)>=2
      and count(*) filter(where o.direction_matches_train)>=2
      and avg(o.signed_oos_effect_pct)>=case c.horizon_days when 20 then .375 when 60 then .75 else 1.25 end
      and min(o.signed_oos_effect_pct)>=-case c.horizon_days when 20 then .75 when 60 then 1.50 else 2.50 end
      then true else false end,
    case when count(o.fold_no)=0 then 'INSUFFICIENT_STRICT_OOS_HISTORY'
      when c.robustness_state='ROBUST_DISCOVERY_SIGNAL' and count(o.fold_no)>=3 and count(*) filter(where o.train_selected)>=2
        and count(*) filter(where o.direction_matches_train)>=2
        and avg(o.signed_oos_effect_pct)>=case c.horizon_days when 20 then .375 when 60 then .75 else 1.25 end
        and min(o.signed_oos_effect_pct)>=-case c.horizon_days when 20 then .75 when 60 then 1.50 else 2.50 end
        then 'HISTORICAL_OOS_PASS'
      when c.robustness_state='ROBUST_DISCOVERY_SIGNAL' then 'HISTORICAL_OOS_FAIL'
      else 'PREREGISTERED_CONTROL' end,
    (c.robustness_state='ROBUST_DISCOVERY_SIGNAL'),false
  from public.flow_factor_interactions_v4 c
  left join public.flow_phase4d_interaction_oos_v4 o
    on o.validation_as_of=v_asof and o.interaction_name=c.interaction_name and o.horizon_days=c.horizon_days
  where c.discovery_as_of=v_c_asof and c.stability_window='ALL'
  group by c.interaction_name,c.horizon_days,c.robustness_state;

  delete from public.flow_phase4d_snapshot_v4 where validation_as_of=v_asof;
  insert into public.flow_phase4d_snapshot_v4(
    validation_as_of,phase4c_discovery_as_of,factor_oos_rows,interaction_oos_rows,factor_challenger_rows,
    factor_historical_pass_rows,factor_historical_fail_rows,factor_insufficient_history_rows,
    robust_interaction_rows,interaction_historical_pass_rows,interaction_historical_fail_rows,interaction_insufficient_history_rows,
    production_scoring_changed,phase4d_gate_state)
  select v_asof,v_c_asof,
    (select count(*) from public.flow_phase4d_factor_oos_v4 where validation_as_of=v_asof),
    (select count(*) from public.flow_phase4d_interaction_oos_v4 where validation_as_of=v_asof),
    count(*) filter(where entity_type='FACTOR' and phase4c_challenger),
    count(*) filter(where entity_type='FACTOR' and phase4c_challenger and historical_state='HISTORICAL_OOS_PASS'),
    count(*) filter(where entity_type='FACTOR' and phase4c_challenger and historical_state='HISTORICAL_OOS_FAIL'),
    count(*) filter(where entity_type='FACTOR' and phase4c_challenger and historical_state='INSUFFICIENT_STRICT_OOS_HISTORY'),
    count(*) filter(where entity_type='INTERACTION' and phase4c_robust),
    count(*) filter(where entity_type='INTERACTION' and phase4c_robust and historical_state='HISTORICAL_OOS_PASS'),
    count(*) filter(where entity_type='INTERACTION' and phase4c_robust and historical_state='HISTORICAL_OOS_FAIL'),
    count(*) filter(where entity_type='INTERACTION' and phase4c_robust and historical_state='INSUFFICIENT_STRICT_OOS_HISTORY'),
    false,
    case when (select count(*) from public.flow_phase4d_factor_oos_v4 where validation_as_of=v_asof)=252
      and (select count(*) from public.flow_phase4d_interaction_oos_v4 where validation_as_of=v_asof)=60
      then 'PHASE4D_HISTORICAL_OOS_READY' else 'PHASE4D_HISTORICAL_OOS_INCOMPLETE' end
  from public.flow_phase4d_candidate_summary_v4 where validation_as_of=v_asof;

  select count(*) into v_rows from public.flow_phase4d_candidate_summary_v4 where validation_as_of=v_asof;
  return jsonb_build_object('status','OK','validation_as_of',v_asof,'phase4c_discovery_as_of',v_c_asof,
    'summary_rows',v_rows,'phase4d_gate_state',(select phase4d_gate_state from public.flow_phase4d_snapshot_v4 where validation_as_of=v_asof),
    'production_scoring_changed',false);
end;
$$;

revoke all on function public.flow_finalize_phase4d_historical_v4() from public,anon,authenticated;
grant execute on function public.flow_finalize_phase4d_historical_v4() to service_role;
