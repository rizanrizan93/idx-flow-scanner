create function public.flow_run_research_adaptive_daily_v2()
returns jsonb
language plpgsql
set search_path=''
as $function$
declare
  v_today date := (now() at time zone 'Asia/Jakarta')::date;
  v_latest date;
  v_capture jsonb;
  v_outcomes jsonb;
begin
  select max(signal_date) into v_latest
  from public.flow_research_horizon_snapshot_v1
  where production_influence_enabled=false;

  v_outcomes := public.flow_refresh_research_adaptive_outcomes_v2();

  if v_latest is distinct from v_today then
    return jsonb_build_object(
      'status','SOURCE_NOT_READY','jakarta_date',v_today,'latest_horizon_date',v_latest,
      'adaptive_outcomes',v_outcomes,'production_influence_enabled',false
    );
  end if;

  v_capture := public.flow_capture_research_adaptive_router_v2(v_today);
  v_outcomes := public.flow_refresh_research_adaptive_outcomes_v2();

  return jsonb_build_object(
    'status','OK','signal_date',v_today,'adaptive_capture',v_capture,
    'adaptive_outcomes',v_outcomes,'production_influence_enabled',false
  );
end;
$function$;