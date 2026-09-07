from pathlib import Path


MIGRATION = Path(
    "supabase/migrations/20260907113000_phase4c_advanced_evidence_mask.sql"
)
SQL = MIGRATION.read_text(encoding="utf-8")


def test_phase4c_masks_advanced_broker_history_when_not_genuinely_available():
    assert "flow_phase4c_factor_source_v4" in SQL
    for factor in ("phase3a_score", "phase3b_score", "phase3c_score", "advanced_broker_score"):
        assert f"case when p.advanced_3abc_available then p.{factor} end as {factor}" in SQL
    assert "historical BASE_MARKET absence is never converted into observed zero evidence" in SQL


def test_all_direct_discovery_paths_use_masked_source():
    for signature in (
        "flow_refresh_factor_slice_v4(text,integer,text)",
        "flow_refresh_interaction_slice_v4(text,integer,text)",
        "flow_refresh_regime_slice_v4(text,integer,text)",
    ):
        assert signature in SQL
    assert "from public.flow_phase4c_factor_source_v4 p" in SQL
    assert "from public.flow_market_learning_panel_v4 p" in SQL
    assert "replace(v_def,v_old,v_new)" in SQL


def test_invalid_pre_mask_advanced_discovery_is_deleted():
    assert "factor_family='ADVANCED_BROKER'" in SQL
    assert "delete from public.flow_factor_interactions_v4" in SQL
    assert "delete from public.flow_factor_regime_effects_v4" in SQL


def test_phase4c_mask_view_is_private_service_role_only():
    assert "revoke all on public.flow_phase4c_factor_source_v4 from public,anon,authenticated" in SQL
    assert "grant select on public.flow_phase4c_factor_source_v4 to service_role" in SQL
