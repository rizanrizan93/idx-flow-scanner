from pathlib import Path

from idx_flow_scanner import ui_terminal


ROOT = Path(__file__).resolve().parents[1]


def test_streamlit_chrome_preserves_viewer_toolbar_and_navigation() -> None:
    config = (ROOT / ".streamlit" / "config.toml").read_text(encoding="utf-8")
    assert '[client]' in config
    assert 'toolbarMode = "viewer"' in config
    assert 'showSidebarNavigation = true' in config
    assert 'toolbarMode = "minimal"' not in config


def test_main_and_research_pages_use_responsive_sidebar_state() -> None:
    main_source = (ROOT / "src" / "idx_flow_scanner" / "streamlit_app.py").read_text(encoding="utf-8")
    research_source = (ROOT / "pages" / "5_Research_Shadow.py").read_text(encoding="utf-8")
    assert 'initial_sidebar_state="auto"' in main_source
    assert 'initial_sidebar_state="auto"' in research_source
    assert 'initial_sidebar_state="expanded"' not in main_source
    assert 'initial_sidebar_state="expanded"' not in research_source


def test_mobile_css_preserves_toolbar_and_separates_sidebar_drawer() -> None:
    css = ui_terminal.TERMINAL_CSS
    assert '@media (max-width: 680px)' in css
    assert '[data-testid="stToolbar"]' in css
    assert 'display: flex !important' in css
    assert 'max-width: calc(100vw - 3.8rem) !important' in css
    assert '[data-testid="stSidebarCollapsedControl"]' in css
    assert 'top: 3.6rem !important' in css
    assert 'height: calc(100dvh - 3.6rem) !important' in css
    assert 'padding-top: 4.20rem !important' in css
    assert 'width: min(84vw, 330px) !important' in css
    assert 'overflow-x: auto' in css
    assert '[data-testid="stToolbar"],\n    [data-testid="stHeaderActionElements"],\n    [data-testid="stStatusWidget"],\n    [data-testid="stDecoration"] {\n        display: none !important;' not in css


def test_scan_controls_remain_in_sidebar() -> None:
    source = (ROOT / "src" / "idx_flow_scanner" / "streamlit_app.py").read_text(encoding="utf-8")
    assert 'with st.sidebar:' in source
    assert 'OHLCV lookback' in source
    assert 'Verified flow evidence' in source
    assert 'Managed auto-run' in source
    assert 'RUN MARKET SCAN' in source
