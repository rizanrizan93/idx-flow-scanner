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
