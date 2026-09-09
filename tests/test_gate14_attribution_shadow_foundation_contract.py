from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MIG = ROOT / "supabase" / "migrations" / "20260909062945_gate14_attribution_shadow_foundation_v1.sql"


def sql() -> str:
    assert MIG.exists()
    return MIG.read_text(encoding="utf-8")


def test_gate14_is_shadow_only_and_uses_phase1_v2_contracts():
    text = sql()
    for token in (
        "IDX_PREDICTIVE_ATTRIBUTION_SHADOW_V1",
        "IDX_DRIVER_REGISTRY_GATE10_V2",
        "IDX_DRIVER_WEEKLY_PIT_PANEL_V2",
        "IDX_DRIVER_PURGED_EXPANDING_WF_V2",
        "IDX_DRIVER_BOUNDED_CONFLUENCE_WF_V2",
        "production_influence_enabled boolean not null default false",
    ):
        assert token in text
    low = text.lower()
    for forbidden in (
        "update public.flow_scan_results",
        "insert into public.flow_scan_results",
        "delete from public.flow_scan_results",
        "update public.flow_phase4e",
        "insert into public.flow_phase4e",
    ):
        assert forbidden not in low


def test_gate14_starts_prospective_sector_and_ownership_pit_without_backfill():
    text = sql()
    for token in (
        "flow_sector_membership_snapshot_v1",
        "flow_ownership_snapshot_v1",
        "CURRENT_REGISTRY_CAPTURED_PROSPECTIVELY",
        "OFFICIAL_SHAREHOLDER_PROFILE_PROSPECTIVE_PIT",
        "Historical issuer-sector membership before the first captured snapshot remains unavailable",
        "unreported_float_upper_bound_pct is not official free float",
        "clock_timestamp() at time zone 'Asia/Jakarta'",
    ):
        assert token in text
    assert "CURRENT_REGISTRY_CLASSIFICATION_NOT_HISTORICAL" not in text


def test_gate14_forward_registry_tracks_fin_balance_and_exact_bounded_interactions():
    text = sql()
    assert "'FIN_BALANCE','DRIVER'" in text
    assert "'CONFIRMATION_CANDIDATE'" in text
    assert "'2026-09-09'" in text
    interactions = (
        "INT_FLOW_SECTOR",
        "INT_FLOW_TECHNICAL",
        "INT_FLOW_PRICE_VOLUME",
        "INT_FLOW_FIN_BALANCE",
        "INT_SECTOR_TECHNICAL",
        "INT_SECTOR_PRICE_VOLUME",
        "INT_TECHNICAL_FIN_BALANCE",
        "INT_FLOW_SECTOR_TECHNICAL",
        "INT_FLOW_SECTOR_PRICE_VOLUME",
        "INT_FLOW_SECTOR_FIN_BALANCE",
        "INT_FLOW_TECHNICAL_FIN_BALANCE",
        "INT_FLOW_SECTOR_TECHNICAL_FIN_BALANCE",
    )
    for interaction in interactions:
        assert text.count(f"'{interaction}'") >= 1
    assert text.count("'INTERACTION'") == 12
    assert "no post-hoc promotion" in text


def test_gate14_shadow_attribution_separates_evidence_from_predictive_validation():
    text = sql()
    for token in (
        "dominant_observed_evidence",
        "supporting_diagnostic_evidence",
        "contradicting_evidence",
        "PROMISING_UNCONFIRMED_EVIDENCE_PRESENT",
        "NO_VALIDATED_PREDICTIVE_DRIVER",
        "VALIDATED_PREDICTIVE_EVIDENCE_PRESENT",
        "classification='PROMISING'",
        "classification in ('WEAK','UNSTABLE','LIQUIDITY_SENSITIVE')",
        "normalized_value>=0.80",
        "normalized_value<=0.20",
        "REJECTED never supports a thesis",
        "no causal wording",
    ):
        assert token in text


def test_gate14_events_are_context_only_and_pit_bounded():
    text = sql()
    for token in (
        "PIT_HISTORY_AVAILABLE_BUT_SPARSE",
        "context-only until separately preregistered and validated",
        "e.source_verified",
        "e.validation_state='VERIFIED'",
        "coalesce(e.publication_date,e.observed_on,e.event_date)<=v_date",
        "coalesce(e.publication_date,e.observed_on,e.event_date)>=(v_date-60)",
    ):
        assert token in text


def test_gate14_security_is_service_role_only():
    text = sql().lower()
    assert text.count("enable row level security") >= 6
    assert text.count("security invoker") >= 3
    assert text.count("set search_path=''" ) >= 3
    assert "revoke all on table" in text
    assert "from public,anon,authenticated" in text
    assert "grant execute on function" in text
    assert "to service_role" in text
