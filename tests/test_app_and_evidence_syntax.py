from pathlib import Path


def test_app_and_evidence_builder_compile():
    for path in (Path("app.py"), Path("scripts/build_flow_evidence_cache.py")):
        source = path.read_text(encoding="utf-8")
        compile(source, str(path), "exec")
