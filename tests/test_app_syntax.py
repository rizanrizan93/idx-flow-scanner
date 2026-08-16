from pathlib import Path


def test_streamlit_entrypoint_compiles():
    source = Path("app.py").read_text(encoding="utf-8")
    compile(source, "app.py", "exec")
