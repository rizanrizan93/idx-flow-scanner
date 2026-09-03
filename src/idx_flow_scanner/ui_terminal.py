from __future__ import annotations

import html
from typing import Mapping, Sequence

import pandas as pd
import streamlit as st


TERMINAL_CSS = r"""
<style>
:root {
    --idx-bg: #07111f;
    --idx-bg-soft: #0b1626;
    --idx-panel: #0d1a2c;
    --idx-panel-2: #101f33;
    --idx-border: #203149;
    --idx-border-soft: rgba(125, 151, 184, 0.18);
    --idx-text: #e7eef8;
    --idx-muted: #8fa2bc;
    --idx-accent: #39bdf8;
    --idx-accent-2: #7c9cff;
    --idx-positive: #38d9a9;
    --idx-warning: #f7c65c;
    --idx-negative: #ff718c;
    --idx-shadow: 0 18px 50px rgba(0, 0, 0, 0.22);
}

html, body, [class*="css"] {
    font-family: Inter, ui-sans-serif, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
}

.stApp {
    background:
        radial-gradient(circle at 10% -10%, rgba(57, 189, 248, 0.10), transparent 26rem),
        radial-gradient(circle at 88% 0%, rgba(124, 156, 255, 0.08), transparent 32rem),
        var(--idx-bg);
    color: var(--idx-text);
}

[data-testid="stAppViewContainer"] > .main {
    background: transparent;
}

[data-testid="stHeader"] {
    background: rgba(7, 17, 31, 0.78);
    backdrop-filter: blur(14px);
}

[data-testid="stSidebar"] {
    background: linear-gradient(180deg, #091321 0%, #07111f 100%);
    border-right: 1px solid var(--idx-border-soft);
}

[data-testid="stSidebar"] [data-testid="stMarkdownContainer"] p,
[data-testid="stSidebar"] label,
[data-testid="stSidebar"] span {
    color: #c6d3e5;
}

.block-container {
    max-width: 1560px;
    padding-top: 1.4rem;
    padding-bottom: 3rem;
}

.idx-terminal-header {
    position: relative;
    overflow: hidden;
    padding: 1.25rem 1.35rem 1.15rem;
    border: 1px solid var(--idx-border);
    border-radius: 18px;
    background:
        linear-gradient(135deg, rgba(57,189,248,0.10), transparent 45%),
        linear-gradient(180deg, rgba(16,31,51,0.96), rgba(11,22,38,0.96));
    box-shadow: var(--idx-shadow);
    margin-bottom: 0.75rem;
}

.idx-terminal-header:after {
    content: "";
    position: absolute;
    right: -5rem;
    top: -7rem;
    width: 22rem;
    height: 22rem;
    border-radius: 50%;
    border: 1px solid rgba(57,189,248,0.14);
    box-shadow: 0 0 0 2rem rgba(57,189,248,0.02), 0 0 0 5rem rgba(57,189,248,0.015);
}

.idx-kicker {
    font-size: 0.70rem;
    font-weight: 750;
    letter-spacing: 0.16em;
    text-transform: uppercase;
    color: var(--idx-accent);
    margin-bottom: 0.35rem;
}

.idx-title-row {
    display: flex;
    align-items: baseline;
    gap: 0.7rem;
    flex-wrap: wrap;
}

.idx-title {
    font-size: clamp(1.65rem, 3vw, 2.5rem);
    line-height: 1.05;
    font-weight: 780;
    letter-spacing: -0.035em;
    color: #f4f8ff;
}

.idx-version {
    font-size: 0.72rem;
    line-height: 1;
    padding: 0.34rem 0.52rem;
    border-radius: 999px;
    border: 1px solid rgba(57,189,248,0.28);
    background: rgba(57,189,248,0.08);
    color: #9bddff;
    font-weight: 700;
}

.idx-subtitle {
    margin-top: 0.55rem;
    color: var(--idx-muted);
    font-size: 0.90rem;
    max-width: 980px;
}

.idx-chip-row {
    display: flex;
    flex-wrap: wrap;
    gap: 0.42rem;
    margin-top: 0.9rem;
}

.idx-chip {
    padding: 0.28rem 0.52rem;
    border-radius: 7px;
    border: 1px solid var(--idx-border-soft);
    background: rgba(255,255,255,0.025);
    color: #adbad0;
    font-size: 0.68rem;
    font-weight: 700;
    letter-spacing: 0.04em;
    text-transform: uppercase;
}

.idx-chip-positive {
    color: #76e6c0;
    border-color: rgba(56,217,169,0.28);
    background: rgba(56,217,169,0.07);
}

.idx-chip-warning {
    color: #f4cf7b;
    border-color: rgba(247,198,92,0.28);
    background: rgba(247,198,92,0.07);
}

.idx-chip-accent {
    color: #8edcff;
    border-color: rgba(57,189,248,0.28);
    background: rgba(57,189,248,0.07);
}

.idx-section-head {
    display: flex;
    align-items: flex-end;
    justify-content: space-between;
    gap: 1rem;
    margin: 1.05rem 0 0.55rem;
}

.idx-section-title {
    color: #eff5ff;
    font-size: 1.0rem;
    font-weight: 760;
    letter-spacing: -0.01em;
}

.idx-section-caption {
    color: var(--idx-muted);
    font-size: 0.74rem;
    margin-top: 0.15rem;
}

.idx-funnel {
    display: grid;
    grid-template-columns: repeat(4, minmax(0, 1fr));
    gap: 0.65rem;
    margin: 0.25rem 0 0.9rem;
}

.idx-funnel-step {
    border: 1px solid var(--idx-border-soft);
    border-radius: 13px;
    padding: 0.82rem 0.9rem;
    background: linear-gradient(180deg, rgba(16,31,51,.9), rgba(11,22,38,.9));
}

.idx-funnel-label {
    font-size: 0.67rem;
    text-transform: uppercase;
    letter-spacing: 0.10em;
    color: #7f93ad;
    font-weight: 750;
}

.idx-funnel-value {
    font-size: 1.45rem;
    color: #f2f7ff;
    font-weight: 780;
    margin-top: 0.18rem;
}

.idx-funnel-meta {
    font-size: 0.70rem;
    color: #8396af;
    margin-top: 0.06rem;
}

.idx-leaderboard {
    display: grid;
    grid-template-columns: repeat(5, minmax(0, 1fr));
    gap: 0.58rem;
    margin: 0.25rem 0 0.9rem;
}

.idx-pick-card {
    min-height: 128px;
    border: 1px solid var(--idx-border-soft);
    border-radius: 14px;
    background: linear-gradient(160deg, rgba(17,33,54,.96), rgba(10,21,36,.96));
    padding: 0.80rem 0.85rem;
}

.idx-pick-rank {
    font-size: 0.64rem;
    letter-spacing: 0.12em;
    text-transform: uppercase;
    color: #7187a3;
    font-weight: 760;
}

.idx-pick-ticker {
    font-size: 1.22rem;
    line-height: 1.1;
    font-weight: 820;
    color: #f4f8ff;
    margin-top: 0.22rem;
}

.idx-pick-score {
    font-size: 0.74rem;
    color: #7edcc0;
    font-weight: 700;
    margin-top: 0.16rem;
}

.idx-pick-meta {
    font-size: 0.70rem;
    color: #8da0b9;
    line-height: 1.35;
    margin-top: 0.42rem;
}

.idx-audit-hero {
    border: 1px solid var(--idx-border);
    border-radius: 16px;
    background:
        linear-gradient(115deg, rgba(57,189,248,.08), transparent 42%),
        var(--idx-panel);
    padding: 1.0rem 1.05rem;
    margin-bottom: 0.7rem;
}

.idx-audit-ticker {
    font-size: 1.55rem;
    font-weight: 820;
    letter-spacing: -0.02em;
    color: #f5f8ff;
}

.idx-audit-meta {
    color: var(--idx-muted);
    font-size: 0.76rem;
    margin-top: 0.20rem;
}

.idx-signal {
    display: inline-flex;
    align-items: center;
    padding: 0.28rem 0.55rem;
    border-radius: 7px;
    font-size: 0.68rem;
    font-weight: 800;
    letter-spacing: 0.04em;
    text-transform: uppercase;
    margin-top: 0.55rem;
    border: 1px solid var(--idx-border-soft);
}

.idx-signal-positive {
    color: #79e3bf;
    background: rgba(56,217,169,.08);
    border-color: rgba(56,217,169,.30);
}

.idx-signal-warning {
    color: #f5d27d;
    background: rgba(247,198,92,.08);
    border-color: rgba(247,198,92,.28);
}

.idx-signal-negative {
    color: #ff8fa4;
    background: rgba(255,113,140,.08);
    border-color: rgba(255,113,140,.28);
}

.idx-health-card {
    border: 1px solid var(--idx-border-soft);
    border-radius: 14px;
    background: rgba(13,26,44,.78);
    padding: 0.78rem 0.85rem;
    min-height: 92px;
}

.idx-health-label {
    color: #7890ab;
    font-size: 0.65rem;
    font-weight: 760;
    letter-spacing: 0.08em;
    text-transform: uppercase;
}

.idx-health-value {
    color: #eff5ff;
    font-size: 1.10rem;
    font-weight: 780;
    margin-top: 0.25rem;
}

.idx-health-meta {
    color: #8396af;
    font-size: 0.68rem;
    margin-top: 0.12rem;
}

[data-testid="stMetric"] {
    background: linear-gradient(180deg, rgba(16,31,51,.88), rgba(10,21,36,.88));
    border: 1px solid var(--idx-border-soft);
    border-radius: 14px;
    padding: 0.78rem 0.88rem;
    min-height: 92px;
}

[data-testid="stMetricLabel"] {
    color: #8398b3;
}

[data-testid="stMetricValue"] {
    color: #f0f5ff;
    font-weight: 780;
}

.stButton > button[kind="primary"] {
    border: 1px solid rgba(57,189,248,.45);
    background: linear-gradient(135deg, #1f8ec6, #3d70d7);
    box-shadow: 0 10px 24px rgba(39, 116, 188, 0.22);
    font-weight: 760;
}

.stButton > button {
    border-radius: 10px;
}

[data-baseweb="tab-list"] {
    gap: 0.15rem;
    background: rgba(11,22,38,.62);
    border: 1px solid var(--idx-border-soft);
    border-radius: 12px;
    padding: 0.22rem;
}

[data-baseweb="tab"] {
    border-radius: 9px;
    padding: 0.45rem 0.72rem;
    font-size: 0.80rem;
}

[data-baseweb="tab"][aria-selected="true"] {
    background: rgba(57,189,248,.10);
}

[data-testid="stDataFrame"] {
    border: 1px solid var(--idx-border-soft);
    border-radius: 12px;
    overflow: hidden;
}

[data-testid="stExpander"] {
    border: 1px solid var(--idx-border-soft);
    border-radius: 12px;
    background: rgba(11,22,38,.55);
}

hr {
    border-color: var(--idx-border-soft);
}

@media (max-width: 1100px) {
    .idx-leaderboard {
        grid-template-columns: repeat(2, minmax(0, 1fr));
    }
    .idx-funnel {
        grid-template-columns: repeat(2, minmax(0, 1fr));
    }
}

@media (max-width: 680px) {
    .block-container {
        padding-left: 0.72rem;
        padding-right: 0.72rem;
        padding-top: 0.75rem;
    }
    .idx-terminal-header {
        border-radius: 14px;
        padding: 1rem;
    }
    .idx-leaderboard,
    .idx-funnel {
        grid-template-columns: 1fr;
    }
}
</style>
"""


def inject_terminal_theme() -> None:
    st.markdown(TERMINAL_CSS, unsafe_allow_html=True)


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
    db_text = "DB CONNECTED" if database_connected else "DB OFF"
    st.markdown(
        f"""
        <div class="idx-terminal-header">
          <div class="idx-kicker">Market Intelligence / Indonesia Equities</div>
          <div class="idx-title-row">
            <div class="idx-title">IDX Flow Terminal</div>
            <div class="idx-version">v{_escape(version)}</div>
          </div>
          <div class="idx-subtitle">
            Flow-first decision engine combining ZAPI institutional activity, sector regime,
            free-float structure, ownership, corporate actions and SMC/ICT execution.
          </div>
          <div class="idx-chip-row">
            <span class="idx-chip idx-chip-accent">ZAPI-ONLY</span>
            <span class="idx-chip">{universe_count} TICKERS</span>
            <span class="idx-chip">{sector_count} SECTORS</span>
            <span class="idx-chip idx-chip-positive">BROKER-DIRECT RETIRED</span>
            <span class="idx-chip {db_class}">{db_text}</span>
          </div>
        </div>
        """,
        unsafe_allow_html=True,
    )


def render_section(title: str, caption: str | None = None) -> None:
    st.markdown(
        f"""
        <div class="idx-section-head">
          <div>
            <div class="idx-section-title">{_escape(title)}</div>
            <div class="idx-section-caption">{_escape(caption or "")}</div>
          </div>
        </div>
        """,
        unsafe_allow_html=True,
    )


def render_funnel(
    *,
    valid: int,
    zapi: int,
    decision: int,
    execution: int,
) -> None:
    items = [
        ("Research Universe", valid, "valid scored rows"),
        ("ZAPI Qualified", zapi, "full/fresh/valid flow"),
        ("Decision Top", decision, "guarded shortlist"),
        ("Execution Ready", execution, "entry geometry authorized"),
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
    st.markdown(f'<div class="idx-funnel">{cards}</div>', unsafe_allow_html=True)


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
              <div class="idx-pick-rank">#{i} candidate</div>
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
    st.markdown(
        f'<div class="idx-leaderboard">{"".join(cards)}</div>',
        unsafe_allow_html=True,
    )


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
        elif col in {"decision_rank", "execution_rank"}:
            config[col] = st.column_config.NumberColumn(
                "Rank",
                format="%d",
            )
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
    st.markdown(
        f"""
        <div class="idx-audit-hero">
          <div class="idx-kicker">Single Ticker Command Center</div>
          <div class="idx-audit-ticker">{ticker} <span style="color:#748ba7;font-weight:650;">/ {sector}</span></div>
          <div class="idx-audit-meta">Score {score} · {phase} · {state}</div>
          <span class="idx-signal {_signal_class(action)}">{action}</span>
        </div>
        """,
        unsafe_allow_html=True,
    )


def render_health_cards(items: Sequence[tuple[str, object, str]]) -> None:
    cols = st.columns(len(items))
    for col, (label, value, meta) in zip(cols, items):
        with col:
            st.markdown(
                f"""
                <div class="idx-health-card">
                  <div class="idx-health-label">{_escape(label)}</div>
                  <div class="idx-health-value">{_escape(value)}</div>
                  <div class="idx-health-meta">{_escape(meta)}</div>
                </div>
                """,
                unsafe_allow_html=True,
            )
