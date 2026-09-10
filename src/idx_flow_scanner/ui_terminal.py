from __future__ import annotations

import html
import os
from typing import Mapping, Sequence

import pandas as pd
import streamlit as st


CANONICAL_SUPABASE_REF = "djqvhbeonmicztxfisav"
_AUTO_PERSISTENCE_LABELS = frozenset(
    {
        "Dedicated IDX Flow Supabase",
        "Saya konfirmasi project Supabase ini benar",
        "Persist hasil scan",
    }
)


TERMINAL_CSS = r"""
<style>
:root {
    --idx-bg: #06101d;
    --idx-bg-2: #081523;
    --idx-panel: rgba(12, 26, 43, 0.82);
    --idx-panel-solid: #0d1b2d;
    --idx-panel-2: #112238;
    --idx-border: rgba(132, 164, 205, 0.18);
    --idx-border-strong: rgba(83, 180, 255, 0.30);
    --idx-text: #edf5ff;
    --idx-muted: #8ca1bb;
    --idx-accent: #42c5ff;
    --idx-accent-2: #6d8fff;
    --idx-positive: #42d7a7;
    --idx-warning: #f4c95f;
    --idx-negative: #ff748f;
    --idx-shadow: 0 18px 55px rgba(0, 0, 0, 0.24);
    --idx-radius: 18px;
}

html, body, [class*="css"] {
    font-family: Inter, ui-sans-serif, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
}

.stApp {
    background:
        radial-gradient(circle at 8% -10%, rgba(66, 197, 255, 0.12), transparent 30rem),
        radial-gradient(circle at 92% 6%, rgba(109, 143, 255, 0.10), transparent 34rem),
        linear-gradient(180deg, #07121f 0%, #06101d 48%, #050d18 100%);
    color: var(--idx-text);
}

[data-testid="stAppViewContainer"] > .main { background: transparent; }

[data-testid="stHeader"] {
    background: rgba(6, 16, 29, 0.72);
    border-bottom: 1px solid rgba(132, 164, 205, 0.08);
    backdrop-filter: blur(18px);
}

[data-testid="stSidebar"] {
    background:
        radial-gradient(circle at 20% 0%, rgba(66,197,255,.08), transparent 18rem),
        linear-gradient(180deg, #091725 0%, #07111e 100%);
    border-right: 1px solid var(--idx-border);
}

[data-testid="stSidebar"] > div:first-child {
    padding-top: 0.8rem;
}

[data-testid="stSidebar"] [data-testid="stMarkdownContainer"] p,
[data-testid="stSidebar"] label,
[data-testid="stSidebar"] span {
    color: #c9d7e8;
}

[data-testid="stSidebar"] hr {
    margin: 1.0rem 0;
    border-color: rgba(132, 164, 205, 0.13);
}

[data-testid="stSidebar"] [data-baseweb="select"] > div,
[data-testid="stSidebar"] [data-testid="stSelectbox"] div[role="button"] {
    min-height: 44px;
    border-radius: 12px;
}

.block-container {
    max-width: 1580px;
    padding-top: 1.15rem;
    padding-bottom: 3.5rem;
}

.idx-terminal-header {
    position: relative;
    overflow: hidden;
    padding: 1.35rem 1.45rem 1.25rem;
    border: 1px solid var(--idx-border);
    border-radius: 22px;
    background:
        linear-gradient(125deg, rgba(66,197,255,0.11), transparent 42%),
        linear-gradient(180deg, rgba(17,35,57,0.96), rgba(10,23,39,0.96));
    box-shadow: var(--idx-shadow);
    margin-bottom: 0.85rem;
}

.idx-terminal-header:before {
    content: "";
    position: absolute;
    width: 18rem;
    height: 18rem;
    right: -6rem;
    top: -7rem;
    border-radius: 50%;
    background: radial-gradient(circle, rgba(66,197,255,.13), transparent 68%);
    pointer-events: none;
}

.idx-terminal-header:after {
    content: "";
    position: absolute;
    left: 1.45rem;
    right: 1.45rem;
    bottom: 0;
    height: 1px;
    background: linear-gradient(90deg, rgba(66,197,255,.45), rgba(109,143,255,.12), transparent);
}

.idx-kicker {
    font-size: 0.69rem;
    font-weight: 800;
    letter-spacing: 0.15em;
    text-transform: uppercase;
    color: #62d0ff;
    margin-bottom: 0.42rem;
}

.idx-title-row {
    display: flex;
    align-items: center;
    gap: 0.65rem;
    flex-wrap: wrap;
}

.idx-title {
    font-size: clamp(1.7rem, 3vw, 2.55rem);
    line-height: 1.02;
    font-weight: 800;
    letter-spacing: -0.04em;
    color: #f7fbff;
}

.idx-version {
    font-size: 0.68rem;
    line-height: 1;
    padding: 0.35rem 0.54rem;
    border-radius: 999px;
    border: 1px solid rgba(66,197,255,0.30);
    background: rgba(66,197,255,0.08);
    color: #a8e6ff;
    font-weight: 800;
}

.idx-subtitle {
    margin-top: 0.62rem;
    color: #9aacc1;
    font-size: 0.91rem;
    line-height: 1.55;
    max-width: 980px;
}

.idx-chip-row {
    display: flex;
    flex-wrap: wrap;
    gap: 0.42rem;
    margin-top: 0.92rem;
}

.idx-chip {
    display: inline-flex;
    align-items: center;
    gap: .30rem;
    padding: 0.31rem 0.58rem;
    border-radius: 999px;
    border: 1px solid var(--idx-border);
    background: rgba(255,255,255,0.026);
    color: #b4c2d4;
    font-size: 0.65rem;
    font-weight: 780;
    letter-spacing: 0.045em;
    text-transform: uppercase;
}

.idx-chip-positive {
    color: #83e8c8;
    border-color: rgba(66,215,167,0.30);
    background: rgba(66,215,167,0.075);
}

.idx-chip-warning {
    color: #f5d98a;
    border-color: rgba(244,201,95,0.30);
    background: rgba(244,201,95,0.075);
}

.idx-chip-accent {
    color: #9ce2ff;
    border-color: rgba(66,197,255,0.30);
    background: rgba(66,197,255,0.075);
}

.idx-section-head {
    display: flex;
    align-items: flex-end;
    justify-content: space-between;
    gap: 1rem;
    margin: 1.18rem 0 0.58rem;
}

.idx-section-title {
    color: #f2f7ff;
    font-size: 1.03rem;
    font-weight: 780;
    letter-spacing: -0.012em;
}

.idx-section-caption {
    color: #8599b1;
    font-size: 0.74rem;
    line-height: 1.45;
    margin-top: 0.16rem;
}

.idx-funnel {
    display: grid;
    grid-template-columns: repeat(4, minmax(0, 1fr));
    gap: 0.68rem;
    margin: 0.28rem 0 0.95rem;
}

.idx-funnel-step,
.idx-health-card,
.idx-pick-card,
.idx-audit-hero {
    backdrop-filter: blur(14px);
}

.idx-funnel-step {
    position: relative;
    overflow: hidden;
    border: 1px solid var(--idx-border);
    border-radius: 16px;
    padding: 0.90rem 0.95rem;
    background: linear-gradient(180deg, rgba(17,34,55,.88), rgba(9,21,36,.90));
    box-shadow: 0 8px 30px rgba(0,0,0,.10);
}

.idx-funnel-step:before {
    content: "";
    position: absolute;
    left: 0;
    top: 0;
    bottom: 0;
    width: 3px;
    background: linear-gradient(180deg, #42c5ff, rgba(109,143,255,.35));
}

.idx-funnel-label {
    font-size: 0.64rem;
    text-transform: uppercase;
    letter-spacing: 0.10em;
    color: #8195ad;
    font-weight: 790;
}

.idx-funnel-value {
    font-size: 1.55rem;
    color: #f6f9ff;
    font-weight: 800;
    margin-top: 0.20rem;
}

.idx-funnel-meta {
    font-size: 0.69rem;
    color: #8397ae;
    margin-top: 0.08rem;
    line-height: 1.35;
}

.idx-leaderboard {
    display: grid;
    grid-template-columns: repeat(5, minmax(0, 1fr));
    gap: 0.62rem;
    margin: 0.28rem 0 0.95rem;
}

.idx-pick-card {
    min-height: 142px;
    border: 1px solid var(--idx-border);
    border-radius: 17px;
    background:
        linear-gradient(145deg, rgba(66,197,255,.05), transparent 48%),
        linear-gradient(165deg, rgba(17,34,55,.96), rgba(9,20,35,.96));
    padding: 0.90rem 0.92rem;
    box-shadow: 0 10px 30px rgba(0,0,0,.12);
    transition: transform .15s ease, border-color .15s ease;
}

.idx-pick-card:hover {
    transform: translateY(-2px);
    border-color: rgba(66,197,255,.30);
}

.idx-pick-rank {
    font-size: 0.61rem;
    letter-spacing: 0.12em;
    text-transform: uppercase;
    color: #7187a3;
    font-weight: 780;
}

.idx-pick-ticker {
    font-size: 1.30rem;
    line-height: 1.08;
    font-weight: 840;
    color: #f6f9ff;
    margin-top: 0.27rem;
}

.idx-pick-score {
    display: inline-block;
    font-size: 0.70rem;
    color: #81e4c3;
    font-weight: 760;
    margin-top: 0.18rem;
}

.idx-pick-meta {
    font-size: 0.69rem;
    color: #8ea2ba;
    line-height: 1.45;
    margin-top: 0.44rem;
}

.idx-audit-hero {
    border: 1px solid var(--idx-border-strong);
    border-radius: 18px;
    background:
        linear-gradient(115deg, rgba(66,197,255,.09), transparent 44%),
        rgba(13,27,45,.90);
    padding: 1.05rem 1.12rem;
    margin-bottom: 0.75rem;
    box-shadow: 0 12px 35px rgba(0,0,0,.13);
}

.idx-audit-ticker {
    font-size: 1.58rem;
    font-weight: 840;
    letter-spacing: -0.025em;
    color: #f7faff;
}

.idx-audit-meta {
    color: #91a3b8;
    font-size: 0.76rem;
    margin-top: 0.22rem;
}

.idx-signal {
    display: inline-flex;
    align-items: center;
    padding: 0.29rem 0.58rem;
    border-radius: 999px;
    font-size: 0.65rem;
    font-weight: 820;
    letter-spacing: 0.045em;
    text-transform: uppercase;
    margin-top: 0.58rem;
    border: 1px solid var(--idx-border);
}

.idx-signal-positive {
    color: #87e8c8;
    background: rgba(66,215,167,.08);
    border-color: rgba(66,215,167,.30);
}

.idx-signal-warning {
    color: #f5d98a;
    background: rgba(244,201,95,.08);
    border-color: rgba(244,201,95,.28);
}

.idx-signal-negative {
    color: #ff94a8;
    background: rgba(255,116,143,.08);
    border-color: rgba(255,116,143,.28);
}

.idx-health-card {
    position: relative;
    overflow: hidden;
    border: 1px solid var(--idx-border);
    border-radius: 16px;
    background: linear-gradient(180deg, rgba(14,29,48,.86), rgba(9,21,36,.86));
    padding: 0.86rem 0.90rem;
    min-height: 96px;
    box-shadow: 0 9px 28px rgba(0,0,0,.10);
}

.idx-health-card:after {
    content: "";
    position: absolute;
    left: 0;
    right: 0;
    bottom: 0;
    height: 1px;
    background: linear-gradient(90deg, rgba(66,197,255,.28), transparent 72%);
}

.idx-health-label {
    color: #7f94ad;
    font-size: 0.62rem;
    font-weight: 780;
    letter-spacing: 0.085em;
    text-transform: uppercase;
}

.idx-health-value {
    color: #f2f7ff;
    font-size: 1.12rem;
    font-weight: 800;
    margin-top: 0.27rem;
}

.idx-health-meta {
    color: #8397af;
    font-size: 0.67rem;
    line-height: 1.35;
    margin-top: 0.12rem;
}

.idx-persistence-card {
    border: 1px solid rgba(66,215,167,.26);
    border-radius: 15px;
    padding: .85rem .88rem;
    background:
        linear-gradient(120deg, rgba(66,215,167,.08), rgba(66,197,255,.035)),
        rgba(11,24,40,.78);
    box-shadow: 0 8px 26px rgba(0,0,0,.10);
    margin: .25rem 0 .55rem;
}

.idx-persistence-card.is-off {
    border-color: rgba(244,201,95,.26);
    background:
        linear-gradient(120deg, rgba(244,201,95,.07), transparent),
        rgba(11,24,40,.78);
}

.idx-persistence-top {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: .55rem;
}

.idx-persistence-label {
    color: #edf6ff;
    font-size: .77rem;
    font-weight: 790;
}

.idx-persistence-badge {
    flex: none;
    padding: .24rem .44rem;
    border-radius: 999px;
    color: #87e8c8;
    background: rgba(66,215,167,.09);
    border: 1px solid rgba(66,215,167,.22);
    font-size: .58rem;
    font-weight: 850;
    letter-spacing: .06em;
}

.idx-persistence-card.is-off .idx-persistence-badge {
    color: #f5d98a;
    background: rgba(244,201,95,.08);
    border-color: rgba(244,201,95,.22);
}

.idx-persistence-meta {
    margin-top: .36rem;
    color: #8298b1;
    font-size: .66rem;
    line-height: 1.42;
}

[data-testid="stMetric"] {
    background: linear-gradient(180deg, rgba(15,31,51,.88), rgba(9,20,35,.90));
    border: 1px solid var(--idx-border);
    border-radius: 16px;
    padding: 0.82rem 0.90rem;
    min-height: 94px;
    box-shadow: 0 8px 26px rgba(0,0,0,.09);
}

[data-testid="stMetricLabel"] { color: #8499b2; }
[data-testid="stMetricValue"] { color: #f3f7ff; font-weight: 800; }

.stButton > button[kind="primary"] {
    min-height: 50px;
    border: 1px solid rgba(66,197,255,.45);
    border-radius: 13px;
    background: linear-gradient(135deg, #168fc9 0%, #347bdc 55%, #586ee2 100%);
    box-shadow: 0 12px 30px rgba(36, 111, 196, 0.26);
    font-weight: 800;
    letter-spacing: .01em;
}

.stButton > button[kind="primary"]:hover {
    border-color: rgba(131,221,255,.65);
    box-shadow: 0 14px 34px rgba(36, 111, 196, 0.32);
}

.stButton > button { border-radius: 12px; }

[data-testid="stSegmentedControl"] {
    margin: .30rem 0 .72rem;
}

[data-testid="stSegmentedControl"] [role="radiogroup"] {
    padding: .25rem;
    gap: .20rem;
    border: 1px solid var(--idx-border);
    border-radius: 14px;
    background: rgba(9,21,36,.72);
}

[data-testid="stSegmentedControl"] label {
    min-height: 40px;
    border-radius: 10px !important;
}

[data-baseweb="tab-list"] {
    gap: 0.15rem;
    background: rgba(9,21,36,.70);
    border: 1px solid var(--idx-border);
    border-radius: 14px;
    padding: 0.24rem;
}

[data-baseweb="tab"] {
    border-radius: 10px;
    padding: 0.46rem 0.75rem;
    font-size: 0.79rem;
}

[data-baseweb="tab"][aria-selected="true"] { background: rgba(66,197,255,.10); }

[data-testid="stDataFrame"] {
    border: 1px solid var(--idx-border);
    border-radius: 15px;
    overflow: hidden;
    box-shadow: 0 8px 26px rgba(0,0,0,.08);
}

[data-testid="stExpander"] {
    border: 1px solid var(--idx-border);
    border-radius: 14px;
    background: rgba(9,21,36,.56);
}

[data-testid="stAlert"] {
    border-radius: 14px;
    border-color: var(--idx-border);
}

[data-testid="stProgress"] > div > div > div > div {
    border-radius: 999px;
}

hr { border-color: rgba(132, 164, 205, 0.13); }

@media (max-width: 1100px) {
    .idx-leaderboard { grid-template-columns: repeat(2, minmax(0, 1fr)); }
    .idx-funnel { grid-template-columns: repeat(2, minmax(0, 1fr)); }
}

@media (max-width: 680px) {
    [data-testid="stHeader"] {
        height: 2.75rem !important;
        min-height: 2.75rem !important;
        background: rgba(6, 16, 29, 0.94) !important;
        border-bottom: 1px solid rgba(132, 164, 205, 0.12) !important;
        backdrop-filter: blur(18px);
    }
    [data-testid="stToolbar"],
    [data-testid="stHeaderActionElements"],
    [data-testid="stStatusWidget"],
    [data-testid="stDecoration"] {
        display: none !important;
    }
    [data-testid="stSidebarCollapsedControl"] {
        display: flex !important;
        position: fixed !important;
        top: 0.38rem !important;
        left: 0.45rem !important;
        z-index: 1000002 !important;
        width: 2.1rem !important;
        height: 2.1rem !important;
        align-items: center !important;
        justify-content: center !important;
        border: 1px solid rgba(132, 164, 205, 0.22) !important;
        border-radius: 10px !important;
        background: rgba(13, 27, 45, 0.94) !important;
        box-shadow: 0 8px 22px rgba(0,0,0,.24) !important;
    }
    [data-testid="stSidebar"] {
        width: min(82vw, 320px) !important;
        min-width: 0 !important;
        max-width: min(82vw, 320px) !important;
        z-index: 1000001 !important;
        box-shadow: 18px 0 42px rgba(0,0,0,.34) !important;
    }
    [data-testid="stSidebar"][aria-expanded="true"] > div:first-child {
        width: min(82vw, 320px) !important;
        min-width: min(82vw, 320px) !important;
        max-width: min(82vw, 320px) !important;
    }
    [data-testid="stSidebar"] > div:first-child {
        padding-top: 0.55rem !important;
    }
    .block-container {
        padding-left: 0.70rem;
        padding-right: 0.70rem;
        padding-top: 3.15rem !important;
        padding-bottom: 2.5rem;
    }
    .idx-terminal-header {
        border-radius: 16px;
        padding: 0.90rem 0.90rem 0.84rem;
        margin-bottom: 0.66rem;
    }
    .idx-terminal-header:after { left: 0.9rem; right: 0.9rem; }
    .idx-kicker { font-size: .58rem; letter-spacing: .12em; margin-bottom: .30rem; }
    .idx-title { font-size: 1.46rem; line-height: 1.08; }
    .idx-version { font-size: .60rem; padding: .29rem .43rem; }
    .idx-subtitle { font-size: .75rem; line-height: 1.45; margin-top: .48rem; }
    .idx-chip-row {
        flex-wrap: nowrap;
        overflow-x: auto;
        overscroll-behavior-inline: contain;
        scrollbar-width: none;
        padding-bottom: .10rem;
        margin-top: .68rem;
    }
    .idx-chip-row::-webkit-scrollbar { display: none; }
    .idx-chip { flex: 0 0 auto; white-space: nowrap; font-size: .55rem; padding: .26rem .42rem; }
    .idx-section-head { margin-top: .90rem; }
    .idx-section-title { font-size: .93rem; }
    .idx-section-caption { font-size: .67rem; }
    .idx-leaderboard { grid-template-columns: repeat(2, minmax(0, 1fr)); gap: .46rem; }
    .idx-funnel { grid-template-columns: repeat(2, minmax(0, 1fr)); gap: .46rem; }
    .idx-pick-card { min-height: 120px; padding: .70rem; }
    .idx-pick-ticker { font-size: 1.08rem; }
    .idx-pick-meta { font-size: .61rem; }
    .idx-funnel-step { padding: .70rem .74rem; }
    .idx-funnel-value { font-size: 1.28rem; }
    [data-testid="stMetric"] { min-height: 80px; padding: .66rem .70rem; }
    [data-testid="stSegmentedControl"] [role="radiogroup"],
    [data-baseweb="tab-list"] {
        overflow-x: auto !important;
        flex-wrap: nowrap !important;
        scrollbar-width: none;
    }
    [data-testid="stSegmentedControl"] [role="radiogroup"]::-webkit-scrollbar,
    [data-baseweb="tab-list"]::-webkit-scrollbar { display: none; }
}

@media (max-width: 390px) {
    .idx-leaderboard { grid-template-columns: 1fr; }
}
</style>
"""


def _secret_value(name: str) -> str:
    try:
        value = st.secrets.get(name, os.getenv(name))
    except Exception:
        value = os.getenv(name)
    return str(value or "").strip()


def canonical_persistence_ready() -> bool:
    """Return true only for the dedicated canonical IDX Flow Supabase credentials."""
    expected_url = f"https://{CANONICAL_SUPABASE_REF}.supabase.co"
    url = _secret_value("SUPABASE_URL").rstrip("/")
    key = _secret_value("SUPABASE_SECRET_KEY")
    return bool(key and url == expected_url)


def _render_auto_persistence_status(ready: bool) -> None:
    css_class = "idx-persistence-card" if ready else "idx-persistence-card is-off"
    badge = "AUTO ON" if ready else "NOT READY"
    meta = (
        "Canonical IDX Flow database terverifikasi. Hasil scan, run metadata, dan calibration outcomes disimpan otomatis."
        if ready
        else "Credential canonical IDX Flow belum terverifikasi. Persistence tetap fail-closed dan tidak menulis ke project lain."
    )
    st.html(
        f"""
        <div class="{css_class}">
          <div class="idx-persistence-top">
            <div class="idx-persistence-label">Database persistence</div>
            <div class="idx-persistence-badge">{badge}</div>
          </div>
          <div class="idx-persistence-meta">{_escape(meta)}</div>
        </div>
        """
    )


def _install_auto_persistence_controls() -> None:
    """Replace legacy manual persistence interlocks with a canonical fail-closed auto mode."""
    sentinel = "_idx_flow_original_checkbox"
    if not hasattr(st, sentinel):
        setattr(st, sentinel, st.checkbox)
    original_checkbox = getattr(st, sentinel)

    def checkbox(label, *args, **kwargs):
        if label not in _AUTO_PERSISTENCE_LABELS:
            return original_checkbox(label, *args, **kwargs)
        ready = canonical_persistence_ready()
        if label == "Dedicated IDX Flow Supabase":
            _render_auto_persistence_status(ready)
        return ready

    checkbox.__name__ = "_idx_flow_auto_persistence_checkbox"
    st.checkbox = checkbox


def inject_terminal_theme() -> None:
    st.html(TERMINAL_CSS)
    _install_auto_persistence_controls()


def _escape(value: object) -> str:
    return html.escape(str(value if value is not None else ""))


def render_header(
    *,
    version: str,
    universe_count: int,
    sector_count: int,
    database_connected: bool,
) -> None:
    db_class = "idx-chip-positive" if database_connected else "idx-chip-warning"
    db_text = "AUTO PERSISTENCE" if database_connected else "DB FAIL-CLOSED"
    st.html(
        f"""
        <div class="idx-terminal-header">
          <div class="idx-kicker">Indonesia Equity Intelligence</div>
          <div class="idx-title-row">
            <div class="idx-title">IDX Flow Scanner</div>
            <div class="idx-version">v{_escape(version)}</div>
          </div>
          <div class="idx-subtitle">
            Official-first market intelligence for ranking, evidence validation and SMC/ICT execution planning.
            Built for fast decision review without weakening production guardrails.
          </div>
          <div class="idx-chip-row">
            <span class="idx-chip idx-chip-accent">IDX OFFICIAL PRIMARY</span>
            <span class="idx-chip">ZAPI FALLBACK</span>
            <span class="idx-chip">{universe_count} TICKERS</span>
            <span class="idx-chip">{sector_count} SECTORS</span>
            <span class="idx-chip idx-chip-positive">TOP-900 CONTRACT</span>
            <span class="idx-chip {db_class}">{db_text}</span>
          </div>
        </div>
        """
    )


def render_section(title: str, caption: str | None = None) -> None:
    st.html(
        f"""
        <div class="idx-section-head">
          <div>
            <div class="idx-section-title">{_escape(title)}</div>
            <div class="idx-section-caption">{_escape(caption or "")}</div>
          </div>
        </div>
        """
    )


def render_funnel(
    *,
    valid: int,
    verified: int,
    decision: int,
    execution: int,
) -> None:
    items = [
        ("Research Universe", valid, "valid scored rows"),
        ("Verified Flow", verified, "official / verified fallback"),
        ("Decision Top", decision, "priority shortlist"),
        ("Execution Ready", execution, "authorized BUY setups"),
    ]
    cards = "".join(
        f"""
        <div class="idx-funnel-step">
          <div class="idx-funnel-label">{_escape(label)}</div>
          <div class="idx-funnel-value">{int(value)}</div>
          <div class="idx-funnel-meta">{_escape(meta)}</div>
        </div>
        """
        for label, value, meta in items
    )
    st.html(f'<div class="idx-funnel">{cards}</div>')


def _safe_num(value: object, digits: int = 1) -> str:
    number = pd.to_numeric(value, errors="coerce")
    if pd.isna(number):
        return "—"
    return f"{float(number):.{digits}f}"


def render_leaderboard(frame: pd.DataFrame | None, *, max_cards: int = 5) -> None:
    if frame is None or frame.empty:
        st.info("Belum ada kandidat yang memenuhi lane keputusan ini.")
        return
    cards: list[str] = []
    for i, (_, row) in enumerate(frame.head(max_cards).iterrows(), start=1):
        ticker = _escape(row.get("ticker", "—"))
        score = _safe_num(row.get("final_score"), 1)
        phase = _escape(row.get("phase", "UNKNOWN"))
        sector = _escape(row.get("sector", "UNKNOWN"))
        entry_low = _safe_num(row.get("entry_low"), 0)
        entry_high = _safe_num(row.get("entry_high"), 0)
        cards.append(
            f"""
            <div class="idx-pick-card">
              <div class="idx-pick-rank">Priority #{i}</div>
              <div class="idx-pick-ticker">{ticker}</div>
              <div class="idx-pick-score">Score {score}</div>
              <div class="idx-pick-meta">
                {sector}<br/>
                {phase}<br/>
                Entry {entry_low} – {entry_high}
              </div>
            </div>
            """
        )
    st.html(f'<div class="idx-leaderboard">{"".join(cards)}</div>')


def table_column_config(columns: Sequence[str]) -> dict[str, object]:
    config: dict[str, object] = {}
    for col in columns:
        if col in {
            "final_score",
            "accumulation_score",
            "foreign_institutional_score",
            "market_context_score",
            "smc_execution_score",
            "ownership_score",
            "corporate_action_score",
            "price_data_quality_score",
            "sector_regime_score",
        }:
            config[col] = st.column_config.ProgressColumn(
                col.replace("_", " ").title(),
                min_value=0.0,
                max_value=100.0,
                format="%.1f",
            )
        elif col == "distribution_risk":
            config[col] = st.column_config.ProgressColumn(
                "Distribution Risk",
                min_value=0.0,
                max_value=100.0,
                format="%.1f",
            )
        elif col in {
            "foreign_evidence_coverage_pct",
            "free_float_pct",
            "foreign_net_to_float_20d_pct",
            "foreign_ownership_change_pct",
            "recent_dilution_pct",
            "sector_relative_strength_20d_pct",
        }:
            config[col] = st.column_config.NumberColumn(
                col.replace("_", " ").title(),
                format="%.1f%%",
            )
        elif col in {"entry_low", "entry_high", "invalidation", "tp1", "tp2"}:
            config[col] = st.column_config.NumberColumn(
                col.replace("_", " ").title(),
                format="%.0f",
            )
        elif col in {"decision_rank", "execution_rank", "scanner_rank"}:
            config[col] = st.column_config.NumberColumn("Rank", format="%d")
    return config


def render_table(
    frame: pd.DataFrame,
    *,
    columns: Sequence[str],
    height: int | None = None,
) -> None:
    visible = [column for column in columns if column in frame.columns]
    if not visible:
        st.info("No displayable columns.")
        return
    kwargs: dict[str, object] = {
        "width": "stretch",
        "hide_index": True,
        "column_config": table_column_config(visible),
    }
    if height is not None:
        kwargs["height"] = height
    st.dataframe(frame[visible], **kwargs)


def _signal_class(action: object) -> str:
    text = str(action or "").upper()
    if any(token in text for token in ("BUY", "ENTRY", "READY", "ELIGIBLE")):
        return "idx-signal-positive"
    if any(token in text for token in ("REDUCE", "AVOID", "DISTRIBUTION", "REJECT")):
        return "idx-signal-negative"
    return "idx-signal-warning"


def render_ticker_hero(row: Mapping[str, object]) -> None:
    ticker = _escape(row.get("ticker", "—"))
    sector = _escape(row.get("sector", "UNKNOWN"))
    phase = _escape(row.get("phase", "UNKNOWN"))
    action = _escape(row.get("action", "RESEARCH_ONLY"))
    score = _safe_num(row.get("final_score"), 1)
    state = _escape(row.get("real_money_state", "UNKNOWN"))
    st.html(
        f"""
        <div class="idx-audit-hero">
          <div class="idx-kicker">Ticker Decision Audit</div>
          <div class="idx-audit-ticker">{ticker} <span style="color:#7f94ad;font-weight:650;">/ {sector}</span></div>
          <div class="idx-audit-meta">Score {score} · {phase} · {state}</div>
          <span class="idx-signal {_signal_class(action)}">{action}</span>
        </div>
        """
    )


def render_health_cards(items: Sequence[tuple[str, object, str]]) -> None:
    cols = st.columns(len(items))
    for col, (label, value, meta) in zip(cols, items):
        with col:
            st.html(
                f"""
                <div class="idx-health-card">
                  <div class="idx-health-label">{_escape(label)}</div>
                  <div class="idx-health-value">{_escape(value)}</div>
                  <div class="idx-health-meta">{_escape(meta)}</div>
                </div>
                """
            )
