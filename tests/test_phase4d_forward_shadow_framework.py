from pathlib import Path

MIGRATION = Path('supabase/migrations/20260907202000_phase4d_forward_shadow_framework.sql')


def text() -> str:
    return MIGRATION.read_text(encoding='utf-8')


def test_forward_shadow_is_pre_cutoff_and_private():
    sql = text()
    assert 'UNTOUCHED_FORWARD_SHADOW_V4D_1' in sql
    assert 'PRE_CUTOFF_FEATURE_ONLY_THRESHOLDS_V4D_1' in sql
    assert "as_of_date<=%3$L::date" in sql
    assert "p_as_of_date<=r.freeze_cutoff_date" in sql
    assert 'enable row level security' in sql
    assert 'revoke all on public.flow_phase4d_shadow_registry_v4 from public,anon,authenticated' in sql
    assert 'security invoker' in sql
    assert 'set search_path=pg_catalog,public' in sql


def test_historical_failures_are_not_shadow_activated():
    sql = text()
    assert "historical_state in ('HISTORICAL_OOS_PASS','INSUFFICIENT_STRICT_OOS_HISTORY')" in sql
    assert "ACTIVE_HISTORICAL_PASS" in sql
    assert "ACTIVE_PROVISIONAL_120D" in sql
    assert 'REJECTED_HISTORICAL_OOS' not in sql


def test_capture_is_immutable_and_outcome_free():
    sql = text()
    capture = sql.split('create or replace function public.flow_capture_phase4d_shadow_v4', 1)[1]
    capture = capture.split('create or replace function public.flow_evaluate_phase4d_shadow_v4', 1)[0]
    assert 'flow_market_learning_labels_clean_v4c' not in capture
    assert 'CAPTURED_FROZEN_COHORT' in sql
    assert 'payload_hash' in sql
    assert 'on conflict do nothing' in capture


def test_evaluation_uses_clean_guarded_outcomes():
    sql = text()
    evaluate = sql.split('create or replace function public.flow_evaluate_phase4d_shadow_v4', 1)[1]
    evaluate = evaluate.split('create or replace function public.flow_finalize_phase4d_shadow_v4', 1)[0]
    assert 'flow_market_learning_labels_clean_v4c' in evaluate
    assert 'CLEAN_CORPORATE_ACTION_GUARDED_FORWARD_OUTCOME' in sql
    assert 'signed_effect_pct' in evaluate
    assert 'direction_match' in evaluate


def test_120d_provisional_cannot_be_promotion_ready():
    sql = text()
    assert "r.historical_state='HISTORICAL_OOS_PASS'" in sql
    assert 'promotion_ready' in sql
    assert 'production_eligible' in sql
    assert 'false,max(o.as_of_date),max(e.as_of_date)' in sql


def test_shadow_runs_after_market_memory_and_never_changes_scoring():
    sql = text()
    assert "flow-phase4d-shadow-capture','26 11 * * 1-5'" in sql
    assert "flow-phase4d-shadow-evaluate','28 11 * * 1-5'" in sql
    assert "flow-phase4d-shadow-finalize','29 11 * * 1-5'" in sql
    assert 'production_scoring_changed boolean not null default false' in sql
    assert "'production_scoring_changed',false" in sql
