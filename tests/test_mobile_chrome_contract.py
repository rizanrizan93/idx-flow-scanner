from pathlib import Path

from idx_flow_scanner import ui_terminal


ROOT = Path(__file__).resolve().parents[1]


def test_streamlit_chrome_uses_minimal_toolbar() -> None:
    config = (ROOT / ".streamlit" / "config.toml").read_text(encoding="utf-8")
    assert '[client]' in config
    assert 'toolbarMode = "minimal"' in config
    assert 'showSidebarNavigation = true' in config


def test_main_and_research_pages_use_responsive_sidebar_state() -> None:
    main_source = (ROOT / "src" / "idx_flow_scanner" / "streamlit_app.py").read_text(encoding="utf-8")
    research_source = (ROOT / "pages" / "5_Research_Shadow.py").read_text(encoding="utf-8")
    assert 'initial_sidebar_state="auto"' in main_source
    assert 'initial_sidebar_state="auto"' in research_source
    assert 'initial_sidebar_state="expanded"' not in main_source
    assert 'initial_sidebar_state="expanded"' not in research_source


def test_mobile_css_reserves_header_space_and_bounds_sidebar_drawer() -> None:
    css = ui_terminal.TERMINAL_CSS
    assert '@media (max-width: 680px)' in css
    assert '[data-testid="stToolbar"]' in css
    assert '[data-testid="stSidebarCollapsedControl"]' in css
    assert 'padding-top: 3.15rem !important' in css
    assert 'width: min(82vw, 320px) !important' in css
    assert 'overflow-x: auto' in css
