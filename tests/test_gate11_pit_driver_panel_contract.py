from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MIG = ROOT / "supabase" / "migrations" / "20260908231222_gate11_pit_driver_panel_v1.sql"
COMPACT = ROOT / "supabase" / "migrations" / "20260908232126_gate11_compact_panel_finalize_v1.sql"
REUSE = ROOT / "supabase" / "migrations" / "20260908232526_gate11_reuse_only_refresh_v1.sql"
STAGED = ROOT / "supabase" / "migrations" / "20260908232957_gate11_staged_refresh_v1.sql"
FINAL = ROOT / "supabase" / "migrations" / "20260908233438_fix_gate11_compact_finalizer_v1.sql"
JOIN_FIX = ROOT / "supabase" / "migrations" / "20260908231402_fix_gate11_panel_join_v1.sql"


def sql() -> str:
    assert MIG.exists()
    assert COMPACT.exists()
    assert REUSE.exists() and STAGED.exists() and FINAL.exists() and JOIN_FIX.exists()
    return "\n".join(p.read_text(encoding="utf-8") for p in (MIG, JOIN_FIX, COMPACT, REUSE, STAGED, FINAL))


def test_gate11_reuses_sources_and_has_required_dimensions():
    text = sql()
    for token in (
        "flow_market_learning_panel_v4", "flow_financial_shadow_panel_v5",
        "signal_date", "driver_state", "raw_value", "transformed_value", "normalized_value",
        "evidence_timestamp", "effective_availability_date", "source_identity",
        "revision_identity", "stale_status", "missingness_status", "provenance",
    ):
        assert token in text


def test_gate11_targets_and_pit_rules_are_explicit():
    text = sql()
    for horizon in (5, 20, 60):
        assert f"target_date_{horizon}d" in text
        assert f"forward_return_{horizon}d_pct" in text
        assert f"alpha_vs_ihsg_{horizon}d_pct" in text
        assert f"alpha_vs_sector_{horizon}d_pct" in text
    assert "effective_availability_date>signal_date" in text
    assert "SAME_SIGNAL_DATE_CROSS_SECTION_ONLY" in text
    assert "outcome_fields_used_in_feature',false" in text


def test_gate11_fails_closed_on_sector_history_and_missing_evidence():
    text = sql()
    assert "INVALID_CURRENT_SECTOR_CLASSIFICATION_NOT_HISTORICAL" in text
    assert "future_sector_membership_feature_rows" in text
    assert "'MISSING'" in text
    assert "neutral 50" not in text.lower()


def test_gate11_is_atomic_idempotent_secured_and_production_isolated():
    text = sql().lower()
    assert "security invoker" in text
    assert "set search_path=''" in text
    assert text.count("enable row level security") >= 4
    assert "on delete cascade" in text
    assert "production_influence_enabled=false" in text
    assert "flow_finalize_driver_panel_v1" in text
    assert "with (security_invoker=true)" in text
    assert "reuse_only" in text
    assert "staged_refresh_required" in text
    assert "partial_failure_safe" in text
    for token in (
        "update public.flow_scan_results", "insert into public.flow_scan_results",
        "delete from public.flow_scan_results", "update public.flow_phase4e",
        "insert into public.flow_phase4e",
    ):
        assert token not in text
