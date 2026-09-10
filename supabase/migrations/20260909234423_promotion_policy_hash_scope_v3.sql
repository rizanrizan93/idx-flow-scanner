-- Bind the frozen lifecycle-policy digest to candidate identity and weights.
-- No forward outcome had matured when this preregistration correction was made.
update public.flow_strategy_lifecycle_policy_v3
set policy_payload=policy_payload||jsonb_build_object(
      'candidate_id',candidate_id,
      'candidate_type',candidate_type,
      'limited_weight',limited_weight,
      'full_weight',full_weight,
      'lifecycle_policy_version',lifecycle_policy_version),
    policy_hash=encode(extensions.digest(convert_to(
      (policy_payload||jsonb_build_object(
        'candidate_id',candidate_id,
        'candidate_type',candidate_type,
        'limited_weight',limited_weight,
        'full_weight',full_weight,
        'lifecycle_policy_version',lifecycle_policy_version))::text,
      'UTF8'),'sha256'),'hex')
where lifecycle_policy_version='STRATEGY_LIFECYCLE_POLICY_V3';

do $do$
begin
  if (select count(*) from public.flow_strategy_lifecycle_policy_v3
      where lifecycle_policy_version='STRATEGY_LIFECYCLE_POLICY_V3')<>13
    or exists(
      select 1 from public.flow_strategy_lifecycle_policy_v3
      where lifecycle_policy_version='STRATEGY_LIFECYCLE_POLICY_V3'
        and policy_hash<>encode(extensions.digest(
          convert_to(policy_payload::text,'UTF8'),'sha256'),'hex'))
    or (select count(distinct policy_hash)
        from public.flow_strategy_lifecycle_policy_v3
        where lifecycle_policy_version='STRATEGY_LIFECYCLE_POLICY_V3')<>13 then
    raise exception 'STRATEGY_LIFECYCLE_POLICY_V3 scoped digest verification failed';
  end if;
end
$do$;
