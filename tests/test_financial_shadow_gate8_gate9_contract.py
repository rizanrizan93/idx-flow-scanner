from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MIG = ROOT / "supabase" / "migrations"

G8 = MIG / "20260908163424_financial_shadow_v5_gate8.sql"
G8_FIX = MIG / "20260908163516_fix_financial_shadow_gate8_capture.sql"
G9_FOUNDATION = MIG / "20260908163714_financial_shadow_v5_gate9_foundation.sql"
G9_FEATURES = MIG / "20260908163955_financial_shadow_v5_gate9_filing_features.sql"
G9_ZERO_FACT = MIG / "20260908164053_fix_financial_shadow_gate9_zero_fact_intervals.sql"
G9_PANEL = MIG / "20260908164151_financial_shadow_v5_gate9_set_based_panel.sql"
G9_OOS = MIG / "20260908164425_financial_shadow_v5_gate9_preregistered_oos.sql"


def read(path: Path) -> str:
    assert path.exists(), f"missing migration: {path.name}"
    return path.read_text(encoding="utf-8")


def test_gate8_shadow_only_and_pit_contract():
    sql = read(G8)
    assert "FINANCIAL_EVIDENCE_V5_PIT_SHADOW_GATE8_1" in sql
    assert "time '16:15'" in sql
    assert "production_influence_enabled = false" in sql
    assert "'AVAILABLE','MISSING','STALE','NOT_APPLICABLE','INVALID','INSUFFICIENT_HISTORY'" in sql
    assert "when f.sector='Keuangan' then 'NOT_APPLICABLE'" in sql
    assert "publication_time_verified" in sql
    assert "point_in_time_eligible" in sql
    assert "security invoker" in sql.lower()
    assert "set search_path = ''" in sql or "set search_path=''" in sql


def test_gate8_capture_fix_removes_duplicate_as_of_date_projection():
    sql = read(G8_FIX)
    assert "select s.*" in sql
    assert "select d.as_of_date,s.*" not in sql.replace(" ", "")
    assert "production_scoring_changed',false" in sql
    assert "production_influence_enabled',false" in sql


def test_gate9_foundation_is_shadow_only():
    sql = read(G9_FOUNDATION)
    assert "flow_financial_shadow_panel_v5" in sql
    assert "check (production_influence_enabled=false)" in sql
    assert "enable row level security" in sql.lower()


def test_zero_fact_filings_are_preserved_as_intervals():
    initial = read(G9_FEATURES)
    fixed = read(G9_ZERO_FACT)
    assert "join public.flow_financial_fact_evidence_v5 x" in initial
    assert "left join public.flow_financial_fact_evidence_v5 x" in fixed
    assert "zero_fact_filings" in fixed


def test_gate9_panel_is_set_based_and_pit_safe():
    sql = read(G9_PANEL)
    assert "FINANCIAL_V5_WEEKLY_LAST_TRADING_DAY_PIT_1" in sql
    assert "lead(f.available_from_date)" in sql
    assert "f.available_from_date<=l.as_of_date" in sql
    assert "p.available_from_date<=c.as_of_date" in sql
    assert "p.report_year=c.report_year-1" in sql
    assert "p.report_period=c.report_period" in sql
    assert "production_influence_enabled=false" in sql


def test_gate9_candidate_set_is_preregistered_and_bounded():
    sql = read(G9_OOS)
    for factor in ("FIN_QUALITY", "FIN_GROWTH", "FIN_BALANCE", "FIN_CASHFLOW", "FIN_COMPOSITE"):
        assert factor in sql
    assert "'FIN_COMPOSITE','financial_shadow_score',1,20,80,true,5,5,false" in sql
    for factor in ("FIN_QUALITY", "FIN_GROWTH", "FIN_BALANCE", "FIN_CASHFLOW"):
        assert f"'{factor}'" in sql
    assert "PURGE_TRAIN_ROWS_UNLESS_TARGET_DATE_LE_TRAIN_END" in sql
    assert "production_influence_enabled=false" in sql
    assert "READY_FOR_BOUNDED_5PCT_INTEGRATION" in sql


def test_gate8_gate9_migrations_cannot_write_production_scan_results():
    sql = "\n".join(read(p).lower() for p in (G8, G8_FIX, G9_FOUNDATION, G9_FEATURES, G9_ZERO_FACT, G9_PANEL, G9_OOS))
    forbidden = (
        "update public.flow_scan_results",
        "insert into public.flow_scan_results",
        "delete from public.flow_scan_results",
        "update flow_scan_results",
        "insert into flow_scan_results",
        "delete from flow_scan_results",
    )
    for token in forbidden:
        assert token not in sql
