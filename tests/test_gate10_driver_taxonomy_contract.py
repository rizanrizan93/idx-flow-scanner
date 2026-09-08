from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MIG = ROOT / "supabase" / "migrations" / "20260908230120_gate10_driver_taxonomy_v1.sql"


def sql() -> str:
    assert MIG.exists()
    return MIG.read_text(encoding="utf-8")


def test_gate10_has_all_families_states_and_fin_balance():
    text = sql()
    for family in (
        "FLOW_PARTICIPANT", "PRICE_VOLUME", "MARKET_SECTOR", "TECHNICAL_STRUCTURE",
        "FINANCIAL", "OWNERSHIP_FREE_FLOAT", "CORPORATE_EVENT", "LIQUIDITY_TRADABILITY",
    ):
        assert family in text
    for state in ("AVAILABLE", "MISSING", "STALE", "INVALID", "NOT_APPLICABLE", "INSUFFICIENT_HISTORY"):
        assert state in text
    assert '"id":"FIN_BALANCE"' in text
    assert "Gate 9 is discovery evidence, not independent confirmation" in text


def test_gate10_preregisters_exact_bounded_interaction_budget():
    text = sql()
    assert "max_interaction_budget" in text
    assert "IGHSG_PRIMARY" not in text
    assert text.count("('IDX_DRIVER_REGISTRY_GATE10_V1','INT_") == 12
    assert "ALL_COMPONENTS_GE_0_80" in text
    assert "PURGE_TRAIN_ROWS_UNLESS_TARGET_DATE_LE_TRAIN_END" in text


def test_gate10_security_and_production_isolation():
    text = sql().lower()
    assert text.count("enable row level security") >= 5
    assert "security invoker" in text
    assert "set search_path=''" in text
    assert "from public,anon,authenticated,service_role" in text
    forbidden = (
        "update public.flow_scan_results", "insert into public.flow_scan_results",
        "delete from public.flow_scan_results", "update public.flow_phase4e",
        "insert into public.flow_phase4e", "production_influence_enabled=true",
    )
    for token in forbidden:
        assert token not in text


def test_gate10_fails_closed_on_non_pit_sector_and_free_float():
    text = sql()
    assert "CURRENT_SECTOR_CLASSIFICATION_NOT_HISTORICAL" in text
    assert "tradable_shares/listed_shares is not regulatory free float" in text
    assert "candidate_registry_frozen_before_evaluation" in text
