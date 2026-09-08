-- Source-parity patch for canonical migration 20260908163516.
-- The initial Gate 8 capture implementation duplicated as_of_date in the shadow CTE.
-- This corrected body is idempotent and preserves shadow-only semantics.

create or replace function public.flow_capture_financial_shadow_scan_v5(p_run_id uuid, p_weight_pct numeric default 10)
returns jsonb
language plpgsql
security invoker
set search_path=''
as $fn$
declare
  v_weight numeric := greatest(0,least(10,coalesce(p_weight_pct,10)));
  v_result jsonb;
begin
  if not exists(select 1 from public.flow_scan_runs where id=p_run_id) then
    raise exception 'FINANCIAL_SHADOW_RUN_NOT_FOUND';
  end if;

  delete from public.flow_financial_shadow_scan_comparison_v5 where run_id=p_run_id;

  with base as (
    select r.*,
      row_number() over(order by r.final_score desc,r.ticker) as production_rank
    from public.flow_scan_results r
    where r.run_id=p_run_id
  ), dates as (
    select distinct b.as_of_date from base b
  ), shadow as (
    select s.*
    from dates d
    cross join lateral public.flow_financial_shadow_snapshot_v5(d.as_of_date) s
  ), joined as (
    select b.run_id,b.ticker,b.as_of_date,
      coalesce(s.sector,'UNKNOWN') sector,
      coalesce(s.financial_state,'MISSING') financial_state,
      b.final_score production_final_score,b.production_rank,
      b.phase production_phase,b.action production_action,b.real_money_state production_real_money_state,
      s.financial_shadow_score,s.feature_states,
      case when s.financial_shadow_score is null then b.final_score
           else (100-v_weight)/100.0*b.final_score + v_weight/100.0*s.financial_shadow_score end as evaluation_blend_score
    from base b
    left join shadow s on s.as_of_date=b.as_of_date and s.ticker=b.ticker
  ), ranked as (
    select j.*,
      case when j.financial_shadow_score is not null then row_number() over(order by j.financial_shadow_score desc nulls last,j.ticker) end as financial_shadow_rank,
      row_number() over(order by j.evaluation_blend_score desc,j.ticker) as evaluation_blend_rank
    from joined j
  )
  insert into public.flow_financial_shadow_scan_comparison_v5(
    run_id,ticker,as_of_date,sector,financial_state,
    production_final_score,production_rank,production_phase,production_action,production_real_money_state,
    financial_shadow_score,financial_shadow_rank,evaluation_weight_pct,evaluation_blend_score,evaluation_blend_rank,
    feature_states,production_influence_enabled
  )
  select run_id,ticker,as_of_date,sector,financial_state,
    production_final_score,production_rank,production_phase,production_action,production_real_money_state,
    financial_shadow_score,financial_shadow_rank,v_weight,evaluation_blend_score,evaluation_blend_rank,
    coalesce(feature_states,'{}'::jsonb),false
  from ranked;

  select jsonb_build_object(
    'status','OK',
    'run_id',p_run_id,
    'rows',count(*),
    'available_rows',count(*) filter(where financial_state='AVAILABLE'),
    'missing_rows',count(*) filter(where financial_state='MISSING'),
    'stale_rows',count(*) filter(where financial_state='STALE'),
    'insufficient_history_rows',count(*) filter(where financial_state='INSUFFICIENT_HISTORY'),
    'invalid_rows',count(*) filter(where financial_state='INVALID'),
    'scored_rows',count(*) filter(where financial_shadow_score is not null),
    'evaluation_weight_pct',v_weight,
    'top20_overlap',count(*) filter(where production_rank<=20 and evaluation_blend_rank<=20),
    'max_abs_rank_shift',max(abs(evaluation_blend_rank-production_rank)),
    'production_scoring_changed',false,
    'production_influence_enabled',false
  ) into v_result
  from public.flow_financial_shadow_scan_comparison_v5
  where run_id=p_run_id;

  return v_result;
end;
$fn$;

revoke all on function public.flow_capture_financial_shadow_scan_v5(uuid,numeric) from public,anon,authenticated,service_role;
grant execute on function public.flow_capture_financial_shadow_scan_v5(uuid,numeric) to service_role;
