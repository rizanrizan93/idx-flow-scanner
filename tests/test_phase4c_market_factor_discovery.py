from pathlib import Path


MIGRATION = Path("supabase/migrations/20260907084500_phase4c_market_factor_discovery.sql")
SQL = MIGRATION.read_text(encoding="utf-8")
LOWER = SQL.lower()


def test_phase4c_is_discovery_only_and_storage_bounded():
    assert "Discovery only" in SQL
    assert "production_scoring_changed boolean not null default false" in SQL
    assert "flow_factor_discovery_v4" in SQL
    assert "flow_factor_interactions_v4" in SQL
    assert "flow_factor_regime_effects_v4" in SQL
    assert "flow_factor_discovery_snapshot_v4" in SQL
    assert "create table if not exists public.flow_market_learning_panel" not in LOWER


def test_phase4c_uses_clean_corporate_action_guarded_targets():
    assert "flow_market_learning_labels_clean_v4c" in SQL
    assert "share_structure_event_5d" in SQL
    for h in (20, 60, 120, 250):
        assert f"share_structure_event_{h}d" in SQL
        assert f"clean_forward_return_{h}d_pct" in SQL
    assert "CLEAN_CORPORATE_ACTION_GUARDED_OUTCOME_PATH_V4C_1" in SQL
    assert "Future metrics are targets only and never feature inputs" in SQL


def test_phase4c_covers_required_horizons_and_stability_windows():
    assert "horizon_days in (5,20,60,120,250)" in SQL
    assert "stability_window in ('ALL','EARLY','MIDDLE','RECENT')" in SQL
    assert "ntile(3) over(order by as_of_date)" in SQL
    assert "stability_sign_agreement_pct" in SQL


def test_phase4c_has_multiple_testing_control_and_nonlinear_detection():
    assert "fdr_q_value" in SQL
    assert "row_number() over(partition by discovery_as_of,discovery_contract,horizon_days,stability_window order by p_value" in SQL
    assert "MONOTONIC_UP" in SQL
    assert "MONOTONIC_DOWN" in SQL
    assert "INVERTED_U" in SQL
    assert "U_SHAPE" in SQL
    assert "TOP_BIN_CHASE_REVERSAL" in SQL


def test_phase4c_interactions_are_pre_registered_not_cartesian():
    assert "flow_factor_interaction_catalog_v4" in SQL
    assert "BOUNDED_PRE_REGISTERED_INTERACTION_DISCOVERY" in SQL
    assert "FOREIGN_X_RESIDUAL" in SQL
    assert "LIQUIDITY_X_RESIDUAL" in SQL
    assert "FLOAT_X_RESIDUAL" in SQL
    assert "ADVANCED_X_PRICE_EXTENSION" in SQL
    assert "no Cartesian brute force" in SQL


def test_phase4c_conditions_on_required_regimes():
    for regime in ("MARKET_REGIME", "SECTOR", "VOLATILITY_BUCKET", "LIQUIDITY_BUCKET"):
        assert regime in SQL
    assert "CURRENT_REGISTRY_CLASSIFICATION_NOT_HISTORICAL" in SQL
    assert "regime_sign_agreement_pct" in SQL


def test_phase4c_preserves_broker_semantics_and_sparse_advanced_history():
    assert "NOT broker buy/sell" in SQL
    assert "NOT coordinated trading proof" in SQL
    assert "INSUFFICIENT_SAMPLE" in SQL
    assert "ADVANCED_BROKER" in SQL


def test_phase4c_private_acl_and_security_invoker_contract():
    for obj in (
        "flow_factor_discovery_v4",
        "flow_factor_interactions_v4",
        "flow_factor_regime_effects_v4",
        "flow_factor_discovery_snapshot_v4",
    ):
        assert f"alter table public.{obj} enable row level security" in LOWER
        assert f"revoke all on table public.{obj} from public,anon,authenticated" in LOWER
    assert "with (security_invoker=true)" in LOWER
    assert "security definer" not in LOWER


def test_phase4c_quality_gate_and_version_contract():
    assert "FACTOR_DISCOVERY_V4_1" in SQL
    assert "MARKET_MEMORY_V4_1" in SQL
    assert "MARKET_LABELS_V4_1" in SQL
    assert "flow_phase4c_quality_summary" in SQL
    assert "PHASE4C_READY" in SQL
