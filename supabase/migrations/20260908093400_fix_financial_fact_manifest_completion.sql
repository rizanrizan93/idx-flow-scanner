-- Gate 5 canonical repair: the shard ingest RPC already stores relational hashes
-- per shard. The manifest finalizer must only transition the manifest state; the
-- manifest table intentionally has no per-shard relational hash columns.
--
-- This follow-up migration patches the already-deployed function fail-closed and
-- is idempotent for fresh environments where the corrected body is already present.

do $migration$
declare
  v_proc regprocedure := 'public.flow_ingest_block_idx_financial_fact_shard_v5(text,integer)'::regprocedure;
  v_definition text;
  v_bad_fragment constant text := E'    update public.flow_financial_fact_manifest_v5\n    set ingest_state = ''COMPLETE'',\n      expected_relational_sha256 = v_expected_relational,\n      actual_relational_sha256 = v_actual_relational, completed_at = now()\n    where manifest_sha256 = p_manifest_sha256;';
  v_good_fragment constant text := E'    update public.flow_financial_fact_manifest_v5\n    set ingest_state = ''COMPLETE'',\n        completed_at = now()\n    where manifest_sha256 = p_manifest_sha256;';
begin
  select pg_get_functiondef(v_proc) into v_definition;

  if v_definition is null then
    raise exception 'FINANCIAL_FACT_SHARD_INGEST_FUNCTION_MISSING';
  end if;

  if strpos(v_definition, v_bad_fragment) > 0 then
    execute replace(v_definition, v_bad_fragment, v_good_fragment);
  elsif strpos(v_definition, v_good_fragment) = 0 then
    raise exception 'FINANCIAL_FACT_MANIFEST_FINALIZER_UNEXPECTED_BODY';
  end if;
end;
$migration$;

-- Compile-time/post-patch assertion: no manifest update may reference the
-- shard-level relational hash columns.
do $assert$
declare
  v_definition text;
  v_manifest_finalizer text;
begin
  select pg_get_functiondef('public.flow_ingest_block_idx_financial_fact_shard_v5(text,integer)'::regprocedure)
    into v_definition;

  v_manifest_finalizer := substring(
    v_definition
    from 'update public\.flow_financial_fact_manifest_v5[\s\S]*?where manifest_sha256 = p_manifest_sha256;'
  );

  if v_manifest_finalizer is null
     or v_manifest_finalizer not like '%completed_at = now()%'
     or v_manifest_finalizer like '%expected_relational_sha256%'
     or v_manifest_finalizer like '%actual_relational_sha256%' then
    raise exception 'FINANCIAL_FACT_MANIFEST_FINALIZER_PATCH_ASSERTION_FAILED';
  end if;
end;
$assert$;
