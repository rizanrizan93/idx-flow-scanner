-- Phase 4A calibration hardening: repeated scanner runs on the same date must
-- not create independent statistical observations for the same ticker.

create unique index if not exists flow_broker_adaptive_obs_one_ticker_day_idx
  on public.flow_broker_adaptive_score_observations (as_of_date,ticker);

create or replace function public.flow_capture_broker_adaptive_score_observation()
returns trigger
language plpgsql
security definer
set search_path=pg_catalog,public
as $$
declare
  d jsonb;
  evidence_date date;
  v_entry numeric;
begin
  d := coalesce(new.diagnostics,'{}'::jsonb);
  if jsonb_typeof(d) <> 'object' then
    return new;
  end if;
  if lower(coalesce(d->>'adaptive_broker_layer_loaded','false')) <> 'true' then
    return new;
  end if;
  evidence_date := nullif(d->>'adaptive_broker_evidence_as_of_date','')::date;
  if evidence_date is null or evidence_date <> new.as_of_date then
    return new;
  end if;

  select s.close into v_entry
  from public.flow_official_stock_summary s
  where s.ticker=new.ticker
    and s.trade_date=new.as_of_date
    and s.source_verified
  order by s.ingested_at desc
  limit 1;

  insert into public.flow_broker_adaptive_score_observations (
    run_id,ticker,as_of_date,evidence_as_of_date,
    phase3a_score,phase3a_eligible,phase3b_score,phase3b_eligible,
    phase3c_score,phase3c_eligible,evidence_layer_count,
    advanced_broker_score,advanced_evidence_eligible,
    family_budget,applied_v1_weight,applied_advanced_weight,
    base_score_pre_broker_family,broker_family_score_adjustment,final_score,
    entry_close,calibration_status_at_signal
  ) values (
    new.run_id,new.ticker,new.as_of_date,evidence_date,
    coalesce(nullif(d->>'phase3a_score','')::numeric,0),
    lower(coalesce(d->>'phase3a_eligible','false'))='true',
    coalesce(nullif(d->>'phase3b_score','')::numeric,0),
    lower(coalesce(d->>'phase3b_eligible','false'))='true',
    coalesce(nullif(d->>'phase3c_score','')::numeric,0),
    lower(coalesce(d->>'phase3c_eligible','false'))='true',
    coalesce(nullif(d->>'advanced_broker_evidence_layer_count','')::integer,0),
    coalesce(nullif(d->>'advanced_broker_score','')::numeric,50),
    lower(coalesce(d->>'advanced_broker_evidence_eligible','false'))='true',
    coalesce(nullif(d->>'broker_family_budget','')::numeric,0.08),
    coalesce(nullif(d->>'broker_v1_weight_effective','')::numeric,0.08),
    coalesce(nullif(d->>'advanced_broker_weight_effective','')::numeric,0),
    coalesce(nullif(d->>'base_score_pre_broker_family','')::numeric,new.final_score),
    coalesce(nullif(d->>'broker_family_score_adjustment','')::numeric,0),
    new.final_score,
    v_entry,
    coalesce(nullif(d->>'adaptive_broker_calibration_status',''),'BOOTSTRAP')
  )
  on conflict (as_of_date,ticker) do update set
    evidence_as_of_date=excluded.evidence_as_of_date,
    phase3a_score=excluded.phase3a_score,
    phase3a_eligible=excluded.phase3a_eligible,
    phase3b_score=excluded.phase3b_score,
    phase3b_eligible=excluded.phase3b_eligible,
    phase3c_score=excluded.phase3c_score,
    phase3c_eligible=excluded.phase3c_eligible,
    evidence_layer_count=excluded.evidence_layer_count,
    advanced_broker_score=excluded.advanced_broker_score,
    advanced_evidence_eligible=excluded.advanced_evidence_eligible,
    family_budget=excluded.family_budget,
    applied_v1_weight=excluded.applied_v1_weight,
    applied_advanced_weight=excluded.applied_advanced_weight,
    base_score_pre_broker_family=excluded.base_score_pre_broker_family,
    broker_family_score_adjustment=excluded.broker_family_score_adjustment,
    final_score=excluded.final_score,
    entry_close=coalesce(public.flow_broker_adaptive_score_observations.entry_close,excluded.entry_close),
    calibration_status_at_signal=excluded.calibration_status_at_signal;

  return new;
end;
$$;

revoke all on function public.flow_capture_broker_adaptive_score_observation() from public,anon,authenticated;
grant execute on function public.flow_capture_broker_adaptive_score_observation() to service_role;
