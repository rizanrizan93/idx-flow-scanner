from pathlib import Path


def test_active_zapi_runtime_and_evidence_builder_compile():
    for path in (
        Path("app.py"),
        Path("src/idx_flow_scanner/streamlit_app.py"),
        Path("src/idx_flow_scanner/zapi_pipeline.py"),
        Path("src/idx_flow_scanner/slow_evidence.py"),
        Path("src/idx_flow_scanner/providers/zapi_slow.py"),
        Path("scripts/build_flow_evidence_cache.py"),
    ):
        source = path.read_text(encoding="utf-8")
        compile(source, str(path), "exec")


def test_warm_job_is_zapi_only_and_has_no_broker_budget():
    workflow = Path(".github/workflows/warm-flow-evidence.yml").read_text(encoding="utf-8")
    assert "ZAPI_KEY" in workflow
    assert "ZAPI_OWNERSHIP_REFRESH_WEEKDAY" in workflow
    assert "INDEX_ALPHA_DAILY_BUDGET" not in workflow
    assert "GOAPI_DAILY_BUDGET" not in workflow
    assert "INDEX_ALPHA_KEY" not in workflow
    assert "GOAPI_KEY" not in workflow
