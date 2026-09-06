from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def _text(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


def test_runtime_hard_locks_canonical_supabase_project() -> None:
    app = _text("app.py")
    assert 'EXPECTED_SUPABASE_PROJECT_REF = "djqvhbeonmicztxfisav"' in app
    assert "mbtsvflwszcgdtijdgas" not in app


def test_official_foreign_uses_existing_retrieved_at_contract() -> None:
    sql = _text("supabase/migrations/20260906090000_official_idx_foreign_refresh.sql")
    assert "https://block.idx.id/primary/TradingSummary/GetStockSummary" in sql
    assert "retrieved_at" in sql
    assert "ingested_at" not in sql


def test_official_issuer_registry_is_block_idx_only() -> None:
    sql = _text("supabase/migrations/20260906083000_official_idx_issuer_registry.sql")
    assert "https://block.idx.id/primary/ListedCompany/GetCompanyProfiles" in sql
    assert "flow_refresh_official_idx_issuers" in sql
    assert "flow_issuers" in sql


def test_capital_action_dependency_is_flow_namespaced_and_private() -> None:
    sql = _text("supabase/migrations/20260906110000_canonical_capital_action_evidence_base.sql")
    compact = "".join(sql.split()).lower()
    assert "public.flow_capital_action_evidence" in sql
    assert "enablerowlevelsecurity" in compact
    assert "frompublic,anon,authenticated" in compact


def test_shareholder_rotation_covers_full_official_registry() -> None:
    sql = _text("supabase/migrations/20260906132000_canonical_flow_security_and_shareholder_rotation.sql")
    compact = "".join(sql.split()).lower()
    assert "whereactive" in compact
    assert "%10" in compact
    assert "https://block.idx.id/primary/ListedCompany/GetCompanyProfilesDetail" in sql
