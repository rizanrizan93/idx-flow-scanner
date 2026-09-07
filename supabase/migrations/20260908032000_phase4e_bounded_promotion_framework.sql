-- Phase 4E: bounded production promotion framework.
-- Framework only. No production score/weight is changed by this migration.
-- Actual influence remains disabled until Phase 4D untouched forward-shadow promotion_ready=true.

create table if not exists public.flow_phase4e_promotion_policy_v4 (
  policy_contract text primary key default 'BOUNDED_PRODUCTION_PROMOTION_V4E_1',
  total_budget_pct double precision not null check(total_budget_pct>=0 and total_budget_pct<=1.0) default 1.0,
  max_candidate_weight_pct double precision not null check(max_candidate_weight_pct>=0 and max_candidate_weight_pct<=0.25) default 0.25,
  max_active_candidates integer not null check(max_active_candidates between 1 and 4) default 4,
  require_historical_oos_pass boolean not null default true,
  require_forward_shadow_pass boolean not null default true,
  require_promotion_ready boolean not null default true,
  require_source_verified boolean not null default true,
  kill_on_shadow_fail boolean not null default true,
  production_influence_enabled boolean not null default false,
  evidence_scope text not null default 'PRICE_FLOW_LIQUIDITY_SECTOR_BROKER_EVENT_WITHOUT_HISTORICAL_FUNDAMENTAL_NARRATIVE_PANEL',
  source_verified boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

insert into public.flow_phase4e_promotion_policy_v4(policy_contract)
values('BOUNDED_PRODUCTION_PROMOTION_V4E_1')
on conflict(policy_contract) do nothing;

create table if not exists public.flow_phase4e_candidate_registry_v4 (
  freeze_cutoff_date date not null,
  promotion_contract text not null default 'BOUNDED_PRODUCTION_PROMOTION_V4E_1',
  entity_type text not null check(entity_type in ('FACTOR','INTERACTION')),
  entity_name text not null,
  horizon_days integer not null,
  historical_state text not null,
  forward_shadow_state text not null,
  promotion_ready boolean not null default false,
  source_verified boolean not null default true,
  activation_state text not null check(activation_state in ('BLOCKED_SHADOW','ELIGIBLE_STAGED','CANARY_ACTIVE','KILLED')),
  target_weight_pct double precision not null default 0 check(target_weight_pct>=0 and target_weight_pct<=0.25),
  active_weight_pct double precision not null default 0 check(active_weight_pct>=0 and active_weight_pct<=0.25),
  production_influence_enabled boolean not null default false,
  gate_reason text not null,
  last_shadow_evaluation_date date,
  refreshed_at timestamptz not null default now(),
  primary key(freeze_cutoff_date,entity_type,entity_name,horizon_days)
);

create table if not exists public.flow_phase4e_snapshot_v4 (
  snapshot_date date primary key,
  promotion_contract text not null default 'BOUNDED_PRODUCTION_PROMOTION_V4E_1',
  phase4d_freeze_cutoff_date date,
  source_shadow_gate_state text,
  registry_rows integer not null,
  promotion_ready_rows integer not null,
  eligible_staged_rows integer not null,
  active_canary_rows integer not null,
  killed_rows integer not null,
  allocated_budget_pct double precision not null,
  max_total_budget_pct double precision not null,
  production_influence_enabled boolean not null default false,
  production_scoring_changed boolean not null default false,
  phase4e_gate_state text not null,
  evidence_scope text not null,
  source_verified boolean not null default true,
  provenance_state text not null default 'PHASE4E_BOUNDED_PROMOTION_SNAPSHOT',
  captured_at timestamptz not null default now()
);

alter table public.flow_phase4e_promotion_policy_v4 enable row level security;
alter table public.flow_phase4e_candidate_registry_v4 enable row level security;
alter table public.flow_phase4e_snapshot_v4 enable row level security;
revoke all on public.flow_phase4e_promotion_policy_v4 from public,anon,authenticated;
revoke all on public.flow_phase4e_candidate_registry_v4 from public,anon,authenticated;
revoke all on public.flow_phase4e_snapshot_v4 from public,anon,authenticated;
grant select,insert,update,delete on public.flow_phase4e_promotion_policy_v4 to service_role;
grant select,insert,update,delete on public.flow_phase4e_candidate_registry_v4 to service_role;
grant select,insert,update,delete on public.flow_phase4e_snapshot_v4 to service_role;

create or replace function public.flow_refresh_phase4e_registry_v4()
returns jsonb
language plpgsql
security invoker
set search_path=pg_catalog,public
as $$
declare
  v_cutoff date;
  v_rows integer;
begin
  select max(freeze_cutoff_date) into v_cutoff from public.flow_phase4d_shadow_candidate_state_v4;
  if v_cutoff is null then return jsonb_build_object('status','NO_PHASE4D_SHADOW_STATE'); end if;

  insert into public.flow_phase4e_candidate_registry_v4(
    freeze_cutoff_date,entity_type,entity_name,horizon_days,historical_state,forward_shadow_state,
    promotion_ready,source_verified,activation_state,target_weight_pct,active_weight_pct,
    production_influence_enabled,gate_reason,last_shadow_evaluation_date,refreshed_at)
  select s.freeze_cutoff_date,s.entity_type,s.entity_name,s.horizon_days,s.historical_state,s.forward_shadow_state,
    s.promotion_ready,s.source_verified,
    case
      when s.forward_shadow_state='FORWARD_SHADOW_FAIL' then 'KILLED'
      when s.historical_state='HISTORICAL_OOS_PASS' and s.forward_shadow_state='FORWARD_SHADOW_PASS' and s.promotion_ready and s.source_verified then 'ELIGIBLE_STAGED'
      else 'BLOCKED_SHADOW' end,
    case when s.historical_state='HISTORICAL_OOS_PASS' and s.forward_shadow_state='FORWARD_SHADOW_PASS' and s.promotion_ready and s.source_verified then .25 else 0 end,
    0,false,
    case
      when not s.source_verified then 'SOURCE_NOT_VERIFIED'
      when s.forward_shadow_state='FORWARD_SHADOW_FAIL' then 'FORWARD_SHADOW_FAIL_KILL'
      when s.historical_state<>'HISTORICAL_OOS_PASS' then 'HISTORICAL_OOS_NOT_PASSED'
      when not s.promotion_ready then 'AWAITING_PHASE4D_PROMOTION_READY'
      when s.forward_shadow_state<>'FORWARD_SHADOW_PASS' then 'AWAITING_FORWARD_SHADOW_PASS'
      else 'ELIGIBLE_BUT_PRODUCTION_INFLUENCE_DISABLED' end,
    s.last_evaluation_date,now()
  from public.flow_phase4d_shadow_candidate_state_v4 s
  where s.freeze_cutoff_date=v_cutoff
  on conflict(freeze_cutoff_date,entity_type,entity_name,horizon_days) do update set
    historical_state=excluded.historical_state,
    forward_shadow_state=excluded.forward_shadow_state,
    promotion_ready=excluded.promotion_ready,
    source_verified=excluded.source_verified,
    activation_state=case
      when public.flow_phase4e_candidate_registry_v4.activation_state='CANARY_ACTIVE' and excluded.forward_shadow_state='FORWARD_SHADOW_FAIL' then 'KILLED'
      when public.flow_phase4e_candidate_registry_v4.activation_state='CANARY_ACTIVE' then 'CANARY_ACTIVE'
      else excluded.activation_state end,
    target_weight_pct=excluded.target_weight_pct,
    active_weight_pct=case when excluded.forward_shadow_state='FORWARD_SHADOW_FAIL' then 0 else public.flow_phase4e_candidate_registry_v4.active_weight_pct end,
    production_influence_enabled=case when excluded.forward_shadow_state='FORWARD_SHADOW_FAIL' then false else public.flow_phase4e_candidate_registry_v4.production_influence_enabled end,
    gate_reason=excluded.gate_reason,
    last_shadow_evaluation_date=excluded.last_shadow_evaluation_date,
    refreshed_at=now();

  select count(*) into v_rows from public.flow_phase4e_candidate_registry_v4 where freeze_cutoff_date=v_cutoff;
  return jsonb_build_object('status','OK','freeze_cutoff_date',v_cutoff,'registry_rows',v_rows,'production_scoring_changed',false);
end;
$$;

create or replace function public.flow_finalize_phase4e_v4()
returns jsonb
language plpgsql
security invoker
set search_path=pg_catalog,public
as $$
declare
  v_cutoff date;
  v_shadow_gate text;
  v_policy public.flow_phase4e_promotion_policy_v4%rowtype;
  v_rows integer;
begin
  select * into v_policy from public.flow_phase4e_promotion_policy_v4 where policy_contract='BOUNDED_PRODUCTION_PROMOTION_V4E_1';
  select max(freeze_cutoff_date) into v_cutoff from public.flow_phase4d_shadow_candidate_state_v4;
  select phase4d_shadow_gate_state into v_shadow_gate from public.flow_phase4d_shadow_snapshot_v4 where freeze_cutoff_date=v_cutoff;

  delete from public.flow_phase4e_snapshot_v4 where snapshot_date=(now() at time zone 'Asia/Jakarta')::date;
  insert into public.flow_phase4e_snapshot_v4(
    snapshot_date,phase4d_freeze_cutoff_date,source_shadow_gate_state,registry_rows,promotion_ready_rows,
    eligible_staged_rows,active_canary_rows,killed_rows,allocated_budget_pct,max_total_budget_pct,
    production_influence_enabled,production_scoring_changed,phase4e_gate_state,evidence_scope)
  select (now() at time zone 'Asia/Jakarta')::date,v_cutoff,v_shadow_gate,
    count(*)::integer,
    count(*) filter(where promotion_ready)::integer,
    count(*) filter(where activation_state='ELIGIBLE_STAGED')::integer,
    count(*) filter(where activation_state='CANARY_ACTIVE')::integer,
    count(*) filter(where activation_state='KILLED')::integer,
    coalesce(sum(active_weight_pct),0),v_policy.total_budget_pct,
    v_policy.production_influence_enabled,false,
    case
      when v_cutoff is null then 'PHASE4E_WAITING_PHASE4D'
      when coalesce(sum(active_weight_pct),0)>v_policy.total_budget_pct then 'PHASE4E_BUDGET_VIOLATION'
      when count(*) filter(where activation_state='CANARY_ACTIVE')>v_policy.max_active_candidates then 'PHASE4E_ACTIVE_COUNT_VIOLATION'
      when not v_policy.production_influence_enabled and count(*) filter(where activation_state='CANARY_ACTIVE')=0 and count(*) filter(where activation_state='ELIGIBLE_STAGED')=0 then 'PHASE4E_FRAMEWORK_READY_WAITING_SHADOW'
      when not v_policy.production_influence_enabled and count(*) filter(where activation_state='ELIGIBLE_STAGED')>0 then 'PHASE4E_CANDIDATES_STAGED_INFLUENCE_DISABLED'
      when v_policy.production_influence_enabled then 'PHASE4E_CANARY_MODE'
      else 'PHASE4E_FRAMEWORK_READY' end,
    v_policy.evidence_scope
  from public.flow_phase4e_candidate_registry_v4 where freeze_cutoff_date=v_cutoff;

  select count(*) into v_rows from public.flow_phase4e_candidate_registry_v4 where freeze_cutoff_date=v_cutoff;
  return jsonb_build_object('status','OK','freeze_cutoff_date',v_cutoff,'registry_rows',v_rows,
    'phase4e_gate_state',(select phase4e_gate_state from public.flow_phase4e_snapshot_v4 where snapshot_date=(now() at time zone 'Asia/Jakarta')::date),
    'production_scoring_changed',false);
end;
$$;

create or replace view public.flow_phase4e_quality_summary
with (security_invoker=true) as
select * from public.flow_phase4e_snapshot_v4
where snapshot_date=(select max(snapshot_date) from public.flow_phase4e_snapshot_v4);
revoke all on public.flow_phase4e_quality_summary from public,anon,authenticated;
grant select on public.flow_phase4e_quality_summary to service_role;

revoke all on function public.flow_refresh_phase4e_registry_v4() from public,anon,authenticated;
revoke all on function public.flow_finalize_phase4e_v4() from public,anon,authenticated;
grant execute on function public.flow_refresh_phase4e_registry_v4() to service_role;
grant execute on function public.flow_finalize_phase4e_v4() to service_role;

select cron.schedule('flow-phase4e-registry-refresh','31 11 * * 1-5',$$select public.flow_refresh_phase4e_registry_v4();$$)
where not exists(select 1 from cron.job where jobname='flow-phase4e-registry-refresh');
select cron.schedule('flow-phase4e-finalize','32 11 * * 1-5',$$select public.flow_finalize_phase4e_v4();$$)
where not exists(select 1 from cron.job where jobname='flow-phase4e-finalize');

comment on table public.flow_phase4e_candidate_registry_v4 is 'Phase4E bounded promotion registry. No production influence unless Phase4D promotion_ready is true and a later explicit canary integration enables it.';
comment on table public.flow_phase4e_promotion_policy_v4 is 'Phase4E policy cap: <=1% total, <=0.25% per candidate, <=4 active candidates. production_influence_enabled defaults false.';
