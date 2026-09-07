-- Phase 4D forward-shadow capture pgcrypto schema fix.
-- Supabase installs pgcrypto digest() in extensions, not public.

create or replace function public.flow_capture_phase4d_shadow_v4(p_as_of_date date)
returns jsonb
language plpgsql
security invoker
set search_path=pg_catalog,public
set work_mem='24MB'
as $$
declare
  r record;
  v_payload jsonb;
  v_n integer;
  v_c1 integer;
  v_c2 integer;
  v_c3 integer;
  v_c4 integer;
  v_sql text;
  v_written integer:=0;
begin
  for r in select * from public.flow_phase4d_shadow_registry_v4 order by entity_type,entity_name,horizon_days
  loop
    if p_as_of_date<=r.freeze_cutoff_date then continue; end if;
    if not exists(select 1 from public.flow_market_memory_manifest_v4 m where m.as_of_date=p_as_of_date and m.feature_contract='MARKET_MEMORY_V4_1' and m.source_verified and m.stock_rows>=900 and m.residual_rows>=900) then
      continue;
    end if;
    if exists(select 1 from public.flow_phase4d_shadow_observations_v4 o where o.as_of_date=p_as_of_date and o.freeze_cutoff_date=r.freeze_cutoff_date and o.entity_type=r.entity_type and o.entity_name=r.entity_name and o.horizon_days=r.horizon_days) then
      continue;
    end if;

    if r.entity_type='FACTOR' then
      v_sql:=format($q$
        select count(*)::integer,
          count(*) filter(where case when %1$L='EVENT' then %2$I<=0 else %2$I<=%3$s end)::integer,
          count(*) filter(where case when %1$L='EVENT' then %2$I>0 else %2$I>=%4$s end)::integer,
          jsonb_build_object(
            'bottom',coalesce(jsonb_agg(ticker order by ticker) filter(where case when %1$L='EVENT' then %2$I<=0 else %2$I<=%3$s end),'[]'::jsonb),
            'top',coalesce(jsonb_agg(ticker order by ticker) filter(where case when %1$L='EVENT' then %2$I>0 else %2$I>=%4$s end),'[]'::jsonb))
        from public.flow_phase4c_factor_source_v4
        where as_of_date=%5$L::date and feature_contract='MARKET_MEMORY_V4_1' and %2$I is not null
      $q$,r.factor_kind,r.factor_a,coalesce(r.threshold_low,0),coalesce(r.threshold_high,0),p_as_of_date::text);
      execute v_sql into v_n,v_c1,v_c2,v_payload;
      v_c3:=0; v_c4:=0;
    else
      v_sql:=format($q$
        with s as (
          select ticker,
            case when %1$L='EVENT' then %2$I>0 else %2$I>=%3$s end ah,
            case when %4$L='EVENT' then %5$I>0 else %5$I>=%6$s end bh
          from public.flow_phase4c_factor_source_v4
          where as_of_date=%7$L::date and feature_contract='MARKET_MEMORY_V4_1' and %2$I is not null and %5$I is not null
        )
        select count(*)::integer,count(*) filter(where ah)::integer,count(*) filter(where bh)::integer,count(*) filter(where ah and bh)::integer,
          jsonb_build_object(
            'all',coalesce(jsonb_agg(ticker order by ticker),'[]'::jsonb),
            'a_high',coalesce(jsonb_agg(ticker order by ticker) filter(where ah),'[]'::jsonb),
            'b_high',coalesce(jsonb_agg(ticker order by ticker) filter(where bh),'[]'::jsonb),
            'hh',coalesce(jsonb_agg(ticker order by ticker) filter(where ah and bh),'[]'::jsonb))
        from s
      $q$,r.factor_a_kind,r.factor_a,coalesce(r.factor_a_threshold,0),r.factor_b_kind,r.factor_b,coalesce(r.factor_b_threshold,0),p_as_of_date::text);
      execute v_sql into v_n,v_c1,v_c2,v_c3,v_payload;
      v_c4:=v_n;
    end if;

    insert into public.flow_phase4d_shadow_observations_v4(
      as_of_date,freeze_cutoff_date,entity_type,entity_name,horizon_days,source_row_count,
      cohort_1_count,cohort_2_count,cohort_3_count,cohort_4_count,cohort_schema,cohort_payload,payload_hash)
    values(p_as_of_date,r.freeze_cutoff_date,r.entity_type,r.entity_name,r.horizon_days,coalesce(v_n,0),
      coalesce(v_c1,0),coalesce(v_c2,0),coalesce(v_c3,0),coalesce(v_c4,0),
      case when r.entity_type='FACTOR' then 'BOTTOM_TOP' else 'A_HIGH_B_HIGH_HH_ALL' end,
      coalesce(v_payload,'{}'::jsonb),encode(extensions.digest(coalesce(v_payload,'{}'::jsonb)::text,'sha256'),'hex'))
    on conflict do nothing;
    v_written:=v_written+1;
  end loop;
  return jsonb_build_object('status','OK','as_of_date',p_as_of_date,'observations_written',v_written);
end;
$$;

revoke all on function public.flow_capture_phase4d_shadow_v4(date) from public,anon,authenticated;
grant execute on function public.flow_capture_phase4d_shadow_v4(date) to service_role;
