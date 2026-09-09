from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MIG = ROOT / "supabase" / "migrations" / "20260909064146_gate14_prospective_forward_ledger_v1.sql"


def sql() -> str:
    assert MIG.exists()
    return MIG.read_text(encoding="utf-8")


def test_forward_ledger_is_untouched_and_fail_closed_before_sources_ready():
    text = sql()
    for token in (
        "date '2026-09-09'",
        "Prospective attribution signals cannot be captured before untouched start date 2026-09-09",
        "v_stock < 800",
        "v_resid < 800",
        "v_index < 12",
        "v_sector < 800",
        "SOURCE_NOT_READY",
    ):
        assert token in text
    assert text.index("if v_stock < 800") < text.index("delete from public.flow_attribution_prospective_candidate_v1")


def test_forward_ledger_reconstructs_exact_frozen_component_definitions_from_pit_sources():
    text = sql()
    for token in (
        "FLOW_FOREIGN_ACCUMULATION",
        "foreign_net_volume_pct",
        "PV_PRICE_VOLUME_CONFIRMATION",
        "greatest(b.return5,0)*greatest(b.volume_residual_z,0)",
        "TECH_TREND_STRUCTURE",
        "0.5*b.return20_rank+0.5*(case when b.close0>=b.avg20 then 1 else 0 end)",
        "MKT_SECTOR_RELATIVE_STRENGTH_20D",
        "ir.return20-h.return20",
        "FIN_BALANCE",
        "flow_financial_shadow_snapshot_v5(p_signal_date)",
        "percent_rank() over(partition by driver_id,driver_state order by raw_value)",
    ):
        assert token in text


def test_candidate_signal_is_frozen_top20_confluence_only():
    text = sql()
    for token in (
        "flow_attribution_forward_registry_v1",
        "d.driver_id=any(f.component_ids)",
        "d.normalized_value>=0.80",
        "available_components=required_components",
        "AVAILABLE_NOT_ACTIVE",
        "COMPONENT_UNAVAILABLE",
        "'ACTIVE'",
    ):
        assert token in text


def test_outcomes_use_ihsg_trading_calendar_not_ticker_specific_bar_count():
    text = sql()
    for token in (
        "i.index_code='COMPOSITE'",
        "i.trade_date>e.signal_date",
        "offset (e.horizon_days-1)",
        "s.trade_date=t.target_date",
        "alpha_vs_ihsg_pct",
        "100.0*(target_close/base_close-1)-100.0*(target_ihsg_close/base_ihsg_close-1)",
        "(values(5),(20),(60))",
    ):
        assert token in text


def test_forward_capture_is_scheduled_after_existing_eod_source_jobs():
    text = sql()
    assert "flow-attribution-pit-capture-v1','35 11 * * 1-5'" in text
    assert "flow-attribution-forward-signals-v1','40 11 * * 1-5'" in text
    assert "flow-attribution-forward-outcomes-v1','50 11 * * 1-5'" in text
    assert "Asia/Jakarta" in text


def test_forward_ledger_is_research_only_and_secured():
    text = sql().lower()
    assert text.count("production_influence_enabled boolean not null default false") >= 4
    assert text.count("enable row level security") >= 4
    assert text.count("security invoker") >= 3
    assert text.count("set search_path=''" ) >= 3
    for forbidden in (
        "update public.flow_scan_results",
        "insert into public.flow_scan_results",
        "delete from public.flow_scan_results",
        "update public.flow_phase4e",
        "insert into public.flow_phase4e",
    ):
        assert forbidden not in text
    assert "from public,anon,authenticated" in text
    assert "to service_role" in text
