from pathlib import Path


def test_terminal_ui_modules_compile():
    for path in (
        Path("src/idx_flow_scanner/ui_terminal.py"),
        Path("src/idx_flow_scanner/streamlit_app.py"),
        Path("app.py"),
    ):
        source = path.read_text(encoding="utf-8")
        compile(source, str(path), "exec")


def test_terminal_ui_is_decision_first_and_preserves_zapi_contract():
    app = Path("src/idx_flow_scanner/streamlit_app.py").read_text(encoding="utf-8")
    assert "Decision Center" in app
    assert "Research Universe" in app
    assert "Ticker Audit" in app
    assert "Evidence Health" in app
    assert "Execution Ready — Top 10" in app
    assert "ZAPI Flow Decision — Top 20" in app
    assert "Raw Research Priority — 400 Ticker" in app
    assert "ZAPI-ONLY" in app
    assert "broker_direct_enabled" in app
    assert '"broker_direct_enabled": False' in app


def test_native_streamlit_theme_matches_terminal_palette():
    config = Path(".streamlit/config.toml").read_text(encoding="utf-8")
    assert 'base = "dark"' in config
    assert 'primaryColor = "#39BDF8"' in config
    assert 'backgroundColor = "#07111F"' in config
    assert 'secondaryBackgroundColor = "#0D1A2C"' in config


def test_terminal_css_has_mobile_breakpoint_and_dense_table_shell():
    ui = Path("src/idx_flow_scanner/ui_terminal.py").read_text(encoding="utf-8")
    assert "@media (max-width: 680px)" in ui
    assert "idx-terminal-header" in ui
    assert "idx-leaderboard" in ui
    assert "idx-funnel" in ui
    assert '[data-testid="stDataFrame"]' in ui


def test_custom_terminal_components_use_native_html_renderer():
    ui = Path("src/idx_flow_scanner/ui_terminal.py").read_text(encoding="utf-8")
    assert "st.html(TERMINAL_CSS)" in ui
    assert 'st.html(f\'<div class="idx-funnel">{cards}</div>\')' in ui
    assert 'st.html(f\'<div class="idx-leaderboard">{"".join(cards)}</div>\')' in ui
    assert "unsafe_allow_html=True" not in ui


def test_supabase_persistence_requires_explicit_confirmation():
    app = Path("src/idx_flow_scanner/streamlit_app.py").read_text(encoding="utf-8")
    assert "Saya konfirmasi project Supabase ini benar" in app
    assert "persistence_armed = bool(use_database and confirm_database)" in app
    assert "connect_store(persistence_armed)" in app


def test_terminal_navigation_is_stateful_across_widget_reruns():
    app = Path("src/idx_flow_scanner/streamlit_app.py").read_text(encoding="utf-8")
    assert "st.segmented_control(" in app
    assert 'key="terminal_view"' in app
    assert 'active_view == "◎ Ticker Audit"' in app
    assert "st.tabs(" not in app
    assert 'key="audit_ticker"' in app
