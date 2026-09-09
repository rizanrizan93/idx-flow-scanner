from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MIG = ROOT / "supabase" / "migrations" / "20260909090000_top900_universe_v1.sql"


def sql() -> str:
    assert MIG.exists()
    return MIG.read_text(encoding="utf-8")


def test_top900_contract_is_frozen_prospective_and_not_historical_backfill():
    text = sql()
    for token in (
        "TOP_900_UNIVERSE_V1",
        "date '2026-09-09'",
        "CURRENT_TOP900_NOT_HISTORICAL",
        "cannot backfill before prospective start 2026-09-09",
        "target_count integer not null",
        "'TOP_900_UNIVERSE_V1',900",
    ):
        assert token in text


def test_top900_ranking_is_deterministic_and_pit_safe():
    text = sql()
    for token in (
        "0.50*percent_rank() over(order by ln(1+greatest(f.adtv60,0)))",
        "0.20*percent_rank() over(order by f.traded60)",
        "0.10*percent_rank() over(order by f.traded252)",
        "e.latest_traded_date desc nulls last,e.ticker",
        "s.trade_date<=v_eod",
        "limit 252",
        "limit 60",
        "row_number() over(",
    ):
        assert token in text
    lower = text.lower()
    for forbidden in ("forward_return", "alpha_vs_ihsg", "target_date", "future_return"):
        assert forbidden not in lower


def test_research_tradeable_and_actionable_states_are_separate():
    text = sql()
    for token in (
        "research_universe_eligible",
        "current_tradeable",
        "production_actionable",
        "TOP900_RESEARCH_ONLY_SURVIVORSHIP_PRESERVATION",
        "f.traded60>=5",
        "f.traded60>=20",
        "NO_RECENT_TRADES_60D",
    ):
        assert token in text
    assert "coalesce(selection_score,0)" not in text.lower()


def test_legacy700_baseline_is_exact_and_overlap_is_manifested():
    text = sql()
    assert text.count("BUNDLED_IDX_700_ALL_CURRENT_SNAPSHOT") == 700
    assert "IDX_OPERATIONAL_UNIVERSE_700_BASELINE_20260909" in text
    assert "baseline_overlap_count" in text
    assert "selection_digest" in text


def test_top900_security_and_production_isolation():
    text = sql().lower()
    assert text.count("enable row level security") >= 4
    assert text.count("security invoker") >= 2
    assert text.count("set search_path=''") >= 2
    assert "from public,anon,authenticated" in text
    assert "to service_role" in text
    assert "check(production_influence_enabled=false)" in text
    for forbidden in (
        "update public.flow_scan_results",
        "insert into public.flow_scan_results",
        "delete from public.flow_scan_results",
        "production_influence_enabled=true",
    ):
        assert forbidden not in text


def test_existing_gate14_pit_scheduler_wrapper_adds_universe_capture():
    text = sql()
    assert "flow_run_attribution_pit_capture_v1" in text
    assert "flow_capture_attribution_pit_sources_v1()" in text
    assert "flow_capture_universe_snapshot_v1(v_date)" in text
    assert "flow_refresh_attribution_data_gap_v1()" in text
