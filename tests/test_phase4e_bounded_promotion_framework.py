from pathlib import Path

SQL = Path('supabase/migrations/20260908032000_phase4e_bounded_promotion_framework.sql').read_text()


def test_phase4e_policy_is_bounded_and_disabled_by_default():
    assert "total_budget_pct double precision" in SQL
    assert "<=1.0" in SQL
    assert "max_candidate_weight_pct double precision" in SQL
    assert "<=0.25" in SQL
    assert "max_active_candidates integer" in SQL
    assert "between 1 and 4" in SQL
    assert "production_influence_enabled boolean not null default false" in SQL


def test_phase4e_requires_phase4d_promotion_ready_and_shadow_pass():
    assert "historical_state='HISTORICAL_OOS_PASS'" in SQL
    assert "forward_shadow_state='FORWARD_SHADOW_PASS'" in SQL
    assert "s.promotion_ready" in SQL
    assert "AWAITING_PHASE4D_PROMOTION_READY" in SQL
    assert "FORWARD_SHADOW_FAIL_KILL" in SQL


def test_phase4e_does_not_change_production_scoring():
    assert "production_scoring_changed boolean not null default false" in SQL
    assert "'production_scoring_changed',false" in SQL
    assert "PHASE4E_FRAMEWORK_READY_WAITING_SHADOW" in SQL


def test_phase4e_private_acl_and_daily_order_after_shadow():
    assert "enable row level security" in SQL
    assert "revoke all on public.flow_phase4e_candidate_registry_v4 from public,anon,authenticated" in SQL
    assert "flow-phase4e-registry-refresh','31 11 * * 1-5'" in SQL
    assert "flow-phase4e-finalize','32 11 * * 1-5'" in SQL
