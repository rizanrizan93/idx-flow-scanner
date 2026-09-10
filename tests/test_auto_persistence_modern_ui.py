from __future__ import annotations

from idx_flow_scanner import ui_terminal


def test_canonical_persistence_requires_exact_project_and_secret(monkeypatch) -> None:
    values = {
        "SUPABASE_URL": "https://djqvhbeonmicztxfisav.supabase.co",
        "SUPABASE_SECRET_KEY": "present-not-exposed",
    }
    monkeypatch.setattr(ui_terminal, "_secret_value", lambda name: values.get(name, ""))
    assert ui_terminal.canonical_persistence_ready() is True

    values["SUPABASE_URL"] = "https://wrong-project.supabase.co"
    assert ui_terminal.canonical_persistence_ready() is False

    values["SUPABASE_URL"] = "https://djqvhbeonmicztxfisav.supabase.co"
    values["SUPABASE_SECRET_KEY"] = ""
    assert ui_terminal.canonical_persistence_ready() is False


def test_legacy_persistence_controls_auto_arm_only_when_canonical_ready(monkeypatch) -> None:
    sentinel = "_idx_flow_original_checkbox"
    monkeypatch.delattr(ui_terminal.st, sentinel, raising=False)

    ordinary_calls: list[str] = []
    status_calls: list[bool] = []

    def original_checkbox(label, *args, **kwargs):
        ordinary_calls.append(str(label))
        return False

    monkeypatch.setattr(ui_terminal.st, "checkbox", original_checkbox)
    monkeypatch.setattr(ui_terminal, "canonical_persistence_ready", lambda: True)
    monkeypatch.setattr(
        ui_terminal,
        "_render_auto_persistence_status",
        lambda ready: status_calls.append(bool(ready)),
    )

    ui_terminal._install_auto_persistence_controls()

    assert ui_terminal.st.checkbox("Dedicated IDX Flow Supabase") is True
    assert ui_terminal.st.checkbox("Saya konfirmasi project Supabase ini benar") is True
    assert ui_terminal.st.checkbox("Persist hasil scan") is True
    assert ui_terminal.st.checkbox("Verified flow evidence") is False
    assert status_calls == [True]
    assert ordinary_calls == ["Verified flow evidence"]


def test_auto_persistence_fails_closed_when_canonical_credentials_are_not_ready(monkeypatch) -> None:
    sentinel = "_idx_flow_original_checkbox"
    monkeypatch.delattr(ui_terminal.st, sentinel, raising=False)
    monkeypatch.setattr(ui_terminal.st, "checkbox", lambda *args, **kwargs: True)
    monkeypatch.setattr(ui_terminal, "canonical_persistence_ready", lambda: False)
    monkeypatch.setattr(ui_terminal, "_render_auto_persistence_status", lambda ready: None)

    ui_terminal._install_auto_persistence_controls()

    assert ui_terminal.st.checkbox("Dedicated IDX Flow Supabase") is False
    assert ui_terminal.st.checkbox("Saya konfirmasi project Supabase ini benar") is False
    assert ui_terminal.st.checkbox("Persist hasil scan") is False


def test_modern_terminal_css_keeps_mobile_and_decision_surfaces() -> None:
    css = ui_terminal.TERMINAL_CSS
    assert ".idx-persistence-card" in css
    assert ".idx-leaderboard" in css
    assert ".idx-funnel" in css
    assert "@media (max-width: 680px)" in css
    assert "[data-testid=\"stSegmentedControl\"]" in css
    assert "min-height: 50px" in css
