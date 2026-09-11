from pathlib import Path


def test_ui_release_version_is_052() -> None:
    root = Path(__file__).resolve().parents[1]
    assert (root / "VERSION").read_text(encoding="utf-8").strip() == "0.5.2"
