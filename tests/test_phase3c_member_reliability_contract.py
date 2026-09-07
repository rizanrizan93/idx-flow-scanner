from pathlib import Path


MIGRATION = Path(
    "supabase/migrations/20260907054000_phase3c_member_reliability_closure.sql"
)


def _sql() -> str:
    return MIGRATION.read_text(encoding="utf-8")


def test_phase3c_distinguishes_pairs_from_multi_broker_clusters():
    sql = _sql()
    assert "structure_class='PAIR'" in sql
    assert "structure_class='CLUSTER'" in sql
    assert "structure_class='BROAD_CLUSTER'" in sql
    assert "member_count between 3 and 4" in sql
    assert "member_count>=5" in sql


def test_phase3c_profile_reliability_uses_independent_affinity_members():
    sql = _sql()
    assert "member_reliability_factor=least(1::numeric,affinity_member_count/3::numeric)" in sql
    assert "INDEPENDENT_AFFINITY_MEMBERS__FULL_AT_3" in sql
    assert "base_coalition_ticker_profile_score" in sql
    assert "coalition_ticker_profile_score <= base_coalition_ticker_profile_score" in sql


def test_phase3c_rebuilds_sector_profiles_after_reliability_adjustment():
    sql = _sql()
    assert "delete from public.flow_broker_coalition_sector_affinity_v3" in sql
    assert "avg(coalition_ticker_profile_score)::numeric mean_ticker_profile_score" in sql
    assert "update public.flow_broker_coalition_snapshot_v3" in sql


def test_phase3c_wrapper_always_finalizes_reliability():
    sql = _sql()
    assert "rename to flow_refresh_broker_coalitions_v3_base" in sql
    assert "flow_finalize_broker_coalition_reliability_v3" in sql
    assert "base_result := public.flow_refresh_broker_coalitions_v3_base" in sql
    assert "reliability_result := public.flow_finalize_broker_coalition_reliability_v3" in sql


def test_phase3c_quality_gate_checks_reliability_and_preserves_existing_prefix():
    sql = _sql()
    gate_pos = sql.index("end phase3c_gate_state")
    structure_pos = sql.index("integrity.bad_structure_class_rows", gate_pos)
    assert structure_pos > gate_pos
    assert "integrity.bad_structure_class_rows=0" in sql
    assert "integrity.missing_reliability_rows=0" in sql
    assert "integrity.reliability_violation_rows=0" in sql


def test_phase3c_closure_remains_shadow_only():
    sql = _sql()
    assert "This remains SHADOW-only" in sql
    assert "no_production_scoring_change" in sql
    assert "production_authorized" not in sql
    assert "final_score" not in sql
