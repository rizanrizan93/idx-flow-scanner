from pathlib import Path


def test_app_and_evidence_builder_compile():
    for path in (
        Path("app.py"),
        Path("src/idx_flow_scanner/streamlit_app.py"),
        Path("src/idx_flow_scanner/funnel.py"),
        Path("scripts/build_flow_evidence_cache.py"),
    ):
        source = path.read_text(encoding="utf-8")
        compile(source, str(path), "exec")


def test_scheduled_indexalpha_quota_builds_pinned_exact_day_history():
    workflow = Path(".github/workflows/warm-flow-evidence.yml").read_text(encoding="utf-8")
    assert "INDEX_ALPHA_DAILY_BUDGET: '5'" in workflow
    assert "pinned five-ticker cohort" in workflow
    assert "vars.INDEX_ALPHA_DAILY_BUDGET" not in workflow
