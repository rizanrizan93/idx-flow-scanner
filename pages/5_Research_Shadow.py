from __future__ import annotations

import os
import sys
from pathlib import Path

import pandas as pd
import streamlit as st


ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "src"
if str(SRC) not in sys.path:
    sys.path.insert(0, str(SRC))

from idx_flow_scanner.research_shadow import load_shadow_research_bundle
from idx_flow_scanner.storage import SupabaseStore
from idx_flow_scanner.ui_terminal import (
    CANONICAL_SUPABASE_REF,
    canonical_persistence_ready,
    inject_terminal_theme,
    render_health_cards,
    render_section,
)


st.set_page_config(
    page_title="Research / Shadow | IDX Flow",
    page_icon="🧪",
    layout="wide",
    initial_sidebar_state="expanded",
)
inject_terminal_theme()


RESEARCH_CSS = r"""
<style>
.idx-research-banner {
    position: relative;
    overflow: hidden;
    border: 1px solid rgba(244, 201, 95, .30);
    border-radius: 18px;
    padding: 1rem 1.05rem;
    margin: .20rem 0 .90rem;
    background:
        linear-gradient(120deg, rgba(244,201,95,.09), rgba(66,197,255,.035)),
        rgba(11,24,40,.84);
    box-shadow: 0 10px 30px rgba(0,0,0,.11);
}
.idx-research-badge {
    display: inline-flex;
    align-items: center;
    padding: .28rem .52rem;
    border-radius: 999px;
    border: 1px solid rgba(244,201,95,.30);
    background: rgba(244,201,95,.08);
    color: #f5d98a;
    font-size: .62rem;
    font-weight: 850;
    letter-spacing: .08em;
    text-transform: uppercase;
}
.idx-research-title {
    margin-top: .50rem;
    color: #f5f8ff;
    font-size: 1.10rem;
    font-weight: 800;
}
.idx-research-copy {
    margin-top: .28rem;
    max-width: 980px;
    color: #98abc0;
    font-size: .78rem;
    line-height: 1.52;
}
@media (max-width: 680px) {
    .idx-research-banner { border-radius: 15px; padding: .88rem; }
    .idx-research-title { font-size: 1rem; }
    .idx-research-copy { font-size: .72rem; }
}
</style>
"""
st.html(RESEARCH_CSS)


def _secret(name: str) -> str | None:
    try:
        value = st.secrets.get(name, os.getenv(name))
    except Exception:
        value = os.getenv(name)
    value = str(value or "").strip()
    return value or None


def _latest(frame: pd.DataFrame, column: str) -> str:
    if frame is None or frame.empty or column not in frame.columns:
        return "—"
    values = frame[column].dropna().astype(str)
    return values.iloc[0] if not values.empty else "—"


def _progress(column: str, label: str):
    return st.column_config.ProgressColumn(
        label,
        min_value=0.0,
        max_value=100.0,
        format="%.1f",
    )


def _number(label: str, fmt: str = "%.1f"):
    return st.column_config.NumberColumn(label, format=fmt)


def _render_research_banner() -> None:
    st.html(
        """
        <div class="idx-research-banner">
          <span class="idx-research-badge">Research only</span>
          <div class="idx-research-title">Shadow Strategy Laboratory</div>
          <div class="idx-research-copy">
            Semua ranking dan score di halaman ini masih berada pada lane research/shadow.
            Data ini belum menjadi production scoring, bukan execution recommendation, dan tidak
            boleh diperlakukan sebagai sinyal BUY sampai lifecycle promotion gate benar-benar lolos.
          </div>
        </div>
        """
    )


version_path = ROOT / "VERSION"
version = version_path.read_text(encoding="utf-8").strip() if version_path.exists() else "unknown"

st.html(
    f"""
    <div class="idx-terminal-header">
      <div class="idx-kicker">Research / Shadow Intelligence</div>
      <div class="idx-title-row">
        <div class="idx-title">IDX Flow Research Lab</div>
        <div class="idx-version">v{version}</div>
      </div>
      <div class="idx-subtitle">
        Read-only view of experimental rankings, financial shadow scoring and Gate-15 lifecycle state.
        Production ranking remains isolated.
      </div>
      <div class="idx-chip-row">
        <span class="idx-chip idx-chip-warning">RESEARCH ONLY</span>
        <span class="idx-chip">SHADOW RANKING</span>
        <span class="idx-chip">GATE-15</span>
        <span class="idx-chip idx-chip-positive">PRODUCTION ISOLATED</span>
      </div>
    </div>
    """
)
_render_research_banner()

if not canonical_persistence_ready():
    st.error(
        "Canonical IDX Flow Supabase tidak tersedia. Research dashboard tetap fail-closed "
        "dan tidak akan membaca project database lain."
    )
    st.stop()

url = _secret("SUPABASE_URL")
key = _secret("SUPABASE_SECRET_KEY")
expected_url = f"https://{CANONICAL_SUPABASE_REF}.supabase.co"
if url is None or key is None or url.rstrip("/") != expected_url:
    st.error("Canonical database identity tidak dapat diverifikasi.")
    st.stop()

try:
    store = SupabaseStore(url.rstrip("/"), key)
except Exception as exc:
    st.error(f"Research database connection unavailable: {exc}")
    st.stop()

bundle = load_shadow_research_bundle(store, limit=250)
predictive = bundle.predictive_scores
financial = bundle.financial_scores
lifecycle = bundle.lifecycle

all_influence_off = True
for frame in (predictive, financial, lifecycle):
    if frame is not None and not frame.empty and "production_influence_enabled" in frame.columns:
        all_influence_off = all_influence_off and not frame["production_influence_enabled"].fillna(False).astype(bool).any()

render_health_cards(
    [
        (
            "Research Strategies",
            len(lifecycle),
            "lifecycle candidates still outside production",
        ),
        (
            "Shadow Signal",
            _latest(predictive, "signal_date"),
            f"{len(predictive)} ranking rows loaded",
        ),
        (
            "Financial Shadow",
            _latest(financial, "as_of_date"),
            f"{len(financial)} comparison rows loaded",
        ),
        (
            "Production Influence",
            "OFF" if all_influence_off else "CHECK",
            "research lane is isolated from execution scoring",
        ),
    ]
)

if bundle.errors:
    with st.expander(f"Research data warnings ({len(bundle.errors)})", expanded=False):
        for message in bundle.errors:
            st.caption(message)

shadow_tab, financial_tab, lifecycle_tab = st.tabs(
    ["🧪 Shadow Ranking", "◫ Financial Shadow", "◇ Strategy Lifecycle / Gate-15"]
)

with shadow_tab:
    render_section(
        "Combined Shadow Predictive Ranking",
        "Current experimental rank from flow_shadow_predictive_score_v1. This is not the production scanner rank.",
    )
    if predictive.empty:
        st.info("Belum ada shadow predictive snapshot yang tersedia.")
    else:
        filter_a, filter_b, filter_c = st.columns([1, 1, 1])
        with filter_a:
            show_n = st.select_slider(
                "Rows",
                options=[20, 50, 100, 200],
                value=50,
                key="shadow_rows",
            )
        with filter_b:
            ticker_query = st.text_input(
                "Ticker",
                placeholder="e.g. SIDO, PGEO, IMPC",
                key="shadow_ticker_query",
            )
        with filter_c:
            timing_options = sorted(
                predictive.get("timing_quality", pd.Series(dtype=object)).dropna().astype(str).unique().tolist()
            )
            selected_timing = st.multiselect(
                "Timing quality",
                timing_options,
                default=timing_options,
                key="shadow_timing_filter",
            )

        view = predictive.copy()
        if ticker_query.strip():
            view = view[
                view["ticker"].astype(str).str.contains(
                    ticker_query.strip(), case=False, regex=False
                )
            ]
        if selected_timing and "timing_quality" in view.columns:
            view = view[view["timing_quality"].astype(str).isin(selected_timing)]
        view = view.head(int(show_n))

        visible = [
            "research_status",
            "shadow_rank",
            "ticker",
            "shadow_predictive_score",
            "timing_quality",
            "model_state",
            "evidence_coverage_pct",
            "component_strength_score",
            "reliability_adjusted_score",
            "current_tradeable",
            "production_actionable",
            "base_close",
            "production_rank",
            "rank_displacement",
            "active_interactions",
        ]
        visible = [column for column in visible if column in view.columns]
        st.dataframe(
            view[visible],
            width="stretch",
            hide_index=True,
            height=620,
            column_config={
                "shadow_rank": _number("Shadow Rank", "%d"),
                "shadow_predictive_score": _progress("shadow_predictive_score", "Shadow Score"),
                "evidence_coverage_pct": _progress("evidence_coverage_pct", "Evidence %"),
                "component_strength_score": _progress("component_strength_score", "Component Strength"),
                "reliability_adjusted_score": _progress("reliability_adjusted_score", "Reliability Score"),
                "base_close": _number("Base Close", "%.0f"),
                "production_rank": _number("Prod Rank", "%d"),
                "rank_displacement": _number("Rank Δ", "%d"),
            },
        )
        st.caption(
            "Shadow Rank dan Shadow Score adalah experimental output. Kolom production hanya pembanding jika tersedia; "
            "tidak ada shadow row di halaman ini yang diizinkan mempengaruhi execution scoring."
        )

with financial_tab:
    render_section(
        "Financial Shadow Comparison",
        "Experimental financial factor ranking versus the production score. Evaluation blend remains research-only.",
    )
    if financial.empty:
        st.info("Belum ada financial shadow comparison yang tersedia.")
    else:
        financial_n = st.select_slider(
            "Rows to display",
            options=[20, 50, 100, 200],
            value=50,
            key="financial_shadow_rows",
        )
        view = financial.head(int(financial_n))
        visible = [
            "research_status",
            "financial_shadow_rank",
            "ticker",
            "sector",
            "financial_state",
            "financial_shadow_score",
            "production_rank",
            "production_final_score",
            "evaluation_weight_pct",
            "evaluation_blend_rank",
            "evaluation_blend_score",
            "production_action",
            "production_real_money_state",
        ]
        visible = [column for column in visible if column in view.columns]
        st.dataframe(
            view[visible],
            width="stretch",
            hide_index=True,
            height=620,
            column_config={
                "financial_shadow_rank": _number("Financial Rank", "%d"),
                "financial_shadow_score": _progress("financial_shadow_score", "Financial Shadow Score"),
                "production_rank": _number("Production Rank", "%d"),
                "production_final_score": _progress("production_final_score", "Production Score"),
                "evaluation_weight_pct": _number("Eval Weight %", "%.1f%%"),
                "evaluation_blend_rank": _number("Eval Blend Rank", "%d"),
                "evaluation_blend_score": _progress("evaluation_blend_score", "Eval Blend Score"),
            },
        )
        st.caption(
            "Evaluation weight/blend pada tabel ini adalah research evaluation only. "
            "production_influence_enabled tetap false untuk rows yang ditampilkan."
        )

with lifecycle_tab:
    render_section(
        "Strategy Lifecycle / Gate-15",
        "Individual driver and interaction candidates that have not entered production influence.",
    )
    if lifecycle.empty:
        st.info("Tidak ada research/shadow lifecycle candidate yang tersedia.")
    else:
        state_counts = lifecycle.get("promotion_state", pd.Series(dtype=object)).fillna("UNKNOWN").value_counts()
        if not state_counts.empty:
            st.caption(
                " · ".join(f"{state}: {count}" for state, count in state_counts.items())
            )

        visible = [
            "research_status",
            "candidate_id",
            "candidate_type",
            "promotion_state",
            "integrity_state",
            "assessment_state",
            "robustness_state",
            "independent_matured_signal_dates",
            "minimum_matured_sample_across_horizons",
            "weight",
            "maximum_weight",
            "transition_reason",
            "assessed_at",
            "gate15_assessed_at",
        ]
        visible = [column for column in visible if column in lifecycle.columns]
        st.dataframe(
            lifecycle[visible],
            width="stretch",
            hide_index=True,
            height=600,
            column_config={
                "independent_matured_signal_dates": _number("Mature Signal Dates", "%d"),
                "minimum_matured_sample_across_horizons": _number("Min Mature Sample", "%d"),
                "weight": _number("Current Weight", "%.3f"),
                "maximum_weight": _number("Max Weight", "%.3f"),
            },
        )
        st.warning(
            "RESEARCH ONLY: candidate pada tabel ini belum memiliki production influence. "
            "Begitu lifecycle otomatis mempromosikan candidate dan production influence benar-benar aktif, "
            "candidate tersebut tidak lagi termasuk daftar shadow-only ini."
        )
