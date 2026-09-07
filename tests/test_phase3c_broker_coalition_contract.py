from pathlib import Path


MIGRATION = Path(
    "supabase/migrations/20260907052000_phase3c_broker_coalition_shadow.sql"
)


def _sql() -> str:
    return MIGRATION.read_text(encoding="utf-8")


def test_phase3c_uses_event_conditioned_mutual_top2_graph():
    sql = _sql()
    assert "residual_activity_z>=1.5" in sql
    assert "co_events>=10" in sql
    assert "event_lift>=1.7" in sql
    assert "jaccard>=0.15" in sql
    assert "excess_z>=2.5" in sql
    assert "a.mutual_rank<=2" in sql
    assert "b.mutual_rank<=2" in sql
    assert "35*least(event_lift/3,1)" in sql


def test_phase3c_builds_connected_components_without_overlap():
    sql = _sql()
    assert "with recursive nodes as" in sql
    assert "reach(root,node)" in sql
    assert "min(root) anchor_broker" in sql
    assert "flow_broker_coalition_members_v3_unique_broker" in sql
    assert "unique (as_of_date,broker_code)" in sql


def test_phase3c_ticker_profile_requires_two_coalition_members():
    sql = _sql()
    assert "stability_state in ('STABLE','RECENT_STRENGTHENING')" in sql
    assert "having count(distinct m.broker_code)>=2" in sql
    assert "50_MEMBER_BREADTH__35_MEAN_AFFINITY__15_MULTI_LAG" in sql
    assert "0.50*x.affinity_member_pct" in sql
    assert "0.35*x.mean_affinity_score" in sql
    assert "0.15*x.multi_lag_member_pct" in sql


def test_phase3c_sector_profile_is_derived_from_ticker_profile():
    sql = _sql()
    assert "flow_broker_coalition_sector_affinity_v3" in sql
    assert "sum(affinity_member_count)::integer member_ticker_hits" in sql
    assert "100::numeric*s.member_ticker_hits/nullif(t.total_hits,0)" in sql
    assert "sector_profile_rank" in sql


def test_phase3c_is_shadow_only_and_not_buy_sell_semantics():
    sql = _sql()
    assert "CO_ACTIVITY_COALITION_NOT_BUY_SELL" in sql
    assert "This remains SHADOW research" in sql
    assert "no_production_scoring_change" in sql
    stripped = sql.replace(
        "-- This remains SHADOW research. It does NOT change final_score, production scoring,\n",
        "",
    )
    assert "production_authorized" not in stripped
    assert "BROKER_BEHAVIOR_OVERLAY_WEIGHT" not in stripped


def test_phase3c_quality_gate_requires_phase3b_and_integrity():
    sql = _sql()
    assert "flow_phase3c_quality_summary" in sql
    assert "PHASE3C_READY" in sql
    assert "p.phase3b_gate_state='PHASE3B_READY'" in sql
    assert "s.as_of_date=p.phase3b_as_of_date" in sql
    assert "s.eligible_broker_count>=80" in sql
    assert "s.coalition_ge3_count>=3" in sql
    assert "integrity.duplicate_member_rows=0" in sql
    assert "audit.failed_audit_rows=0" in sql


def test_phase3c_tables_are_private_and_daily_after_phase3b():
    sql = _sql()
    assert sql.count("enable row level security") >= 6
    assert "from public, anon, authenticated" in sql
    assert "to service_role" in sql
    assert "flow-broker-coalition-v3-shadow-daily" in sql
    assert "20 11 * * 1-5" in sql
    assert "flow_refresh_broker_coalitions_v3" in sql
