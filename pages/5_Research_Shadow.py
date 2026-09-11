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
    initial_sidebar_state="auto",
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
    border: 1px solid rgba(244, 201, 95, .30);
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


def _strategy_policy(policy: pd.DataFrame, strategy_id: str) -> dict:
    if policy is None or policy.empty or "strategy_id" not in policy.columns:
        return {}
    rows = policy[policy["strategy_id"].astype(str) == strategy_id]
    if rows.empty:
        return {}
    value = rows.iloc[0].get("thresholds", {})
    return value if isinstance(value, dict) else {}


def _latest_snapshot(snapshots: pd.DataFrame, strategy_id: str) -> pd.Series | None:
    if snapshots is None or snapshots.empty or "strategy_id" not in snapshots.columns:
        return None
    rows = snapshots[snapshots["strategy_id"].astype(str) == strategy_id].copy()
    if rows.empty:
        return None
    rows = rows.sort_values("signal_date", ascending=False)
    return rows.iloc[0]


def _render_horizon_strategy(
    strategy_id: str,
    horizon_days: int,
    title: str,
    description: str,
    *,
    extra_columns: list[str],
) -> None:
    ranking = bundle.horizon_rankings
    if ranking is None or ranking.empty or "strategy_id" not in ranking.columns:
        st.info("Current horizon ranking belum tersedia dari canonical research RPC.")
        return

    view = ranking[ranking["strategy_id"].astype(str) == strategy_id].copy()
    if view.empty:
        st.info(f"Ranking {horizon_days}D belum tersedia.")
        return

    view = view.sort_values(["research_rank", "ticker"], na_position="last")
    latest_state = _latest_snapshot(bundle.horizon_snapshots, strategy_id)
    active_now = int((view.get("signal_state", pd.Series(dtype=object)).astype(str) == "ACTIVE").sum())
    as_of = _latest(view, "as_of_date")
    gate = _latest(view, "market_gate_state")

    outcomes = bundle.horizon_outcomes
    strategy_outcomes = pd.DataFrame()
    if outcomes is not None and not outcomes.empty and "strategy_id" in outcomes.columns:
        strategy_outcomes = outcomes[outcomes["strategy_id"].astype(str) == strategy_id].copy()
    mature = pd.DataFrame()
    if not strategy_outcomes.empty and "maturity_state" in strategy_outcomes.columns:
        mature = strategy_outcomes[
            strategy_outcomes["maturity_state"].astype(str).str.startswith("MATURE")
        ]

    render_section(title, description)
    m1, m2, m3, m4 = st.columns(4)
    m1.metric("Latest close", as_of)
    m2.metric("Market gate", gate)
    m3.metric("Active candidates", active_now)
    m4.metric("Mature OOS baskets", len(mature))

    thresholds = _strategy_policy(bundle.horizon_policies, strategy_id)
    if thresholds:
        threshold_text = " · ".join(f"{key}={value}" for key, value in thresholds.items())
        st.caption(f"Frozen contract: {threshold_text}")

    if latest_state is not None:
        st.caption(
            f"Prospective snapshot: {latest_state.get('signal_date', '—')} · "
            f"state={latest_state.get('signal_state', '—')} · "
            f"eligible={latest_state.get('eligible_count', 0)} · "
            f"production influence=OFF"
        )

    c1, c2, c3 = st.columns([1, 1, 1])
    with c1:
        row_mode = st.selectbox(
            "Ranking view",
            ["Top research priority", "Active only", "All Top-900"],
            key=f"{strategy_id}_row_mode",
        )
    with c2:
        show_n = st.select_slider(
            "Rows",
            options=[20, 50, 100, 200],
            value=50,
            key=f"{strategy_id}_rows",
        )
    with c3:
        ticker_query = st.text_input(
            "Ticker",
            placeholder="Search ticker",
            key=f"{strategy_id}_ticker",
        )

    if row_mode == "Active only":
        view = view[view["signal_state"].astype(str) == "ACTIVE"]
    if ticker_query.strip():
        view = view[
            view["ticker"].astype(str).str.contains(ticker_query.strip(), case=False, regex=False)
        ]
    view = view.head(int(show_n))

    common = [
        "research_rank",
        "ticker",
        "stock_name",
        "sector",
        "signal_state",
        "research_priority_score",
        "close",
        "traded_value",
        "current_tradeable",
        "production_actionable",
    ]
    visible = []
    for column in common + extra_columns:
        if column in view.columns and column not in visible:
            visible.append(column)

    st.dataframe(
        view[visible],
        width="stretch",
        hide_index=True,
        height=620,
        column_config={
            "research_rank": _number("Research Rank", "%d"),
            "research_priority_score": _progress("research_priority_score", "Priority Score"),
            "close": _number("Last Close", "%.0f"),
            "traded_value": _number("Traded Value", "%.0f"),
            "foreign_net_volume_pct": _number("Foreign Net Vol %", "%.2f"),
            "stock_residual_activity_z": _number("Residual Z", "%.2f"),
            "fin_balance_score": _progress("fin_balance_score", "FIN Balance"),
            "ihsg_return_5d_pct": _number("IHSG 5D %", "%.2f"),
            "ihsg_return_20d_pct": _number("IHSG 20D %", "%.2f"),
            "top10_value_share_pct": _number("Top-10 Share %", "%.2f"),
            "market_activity_intensity_z": _number("Market Activity Z", "%.2f"),
            "risk_event_20d_count": _number("Risk Events 20D", "%d"),
            "capital_action_90d_count": _number("Capital Actions 90D", "%d"),
        },
    )
    st.caption(
        "Research Rank adalah priority ordering untuk inspection, bukan calibrated expected-return rank. "
        "Signal ACTIVE hanya muncul bila frozen market gate dan stock filters sama-sama terpenuhi."
    )

    with st.expander("Prospective OOS history", expanded=False):
        if strategy_outcomes.empty:
            st.info("Belum ada outcome yang mature. Scheduler akan mengisi otomatis setelah horizon selesai.")
        else:
            oos = strategy_outcomes.sort_values("signal_date", ascending=False).head(80)
            oos_visible = [
                "signal_date",
                "target_date",
                "maturity_state",
                "component_count",
                "valid_component_count",
                "coverage_pct",
                "mean_return_pct",
                "median_return_pct",
                "win_rate_pct",
                "mean_alpha_vs_ihsg_pct",
                "mean_alpha_vs_sector_pct",
                "mean_mfe_pct",
                "mean_mae_pct",
            ]
            oos_visible = [column for column in oos_visible if column in oos.columns]
            st.dataframe(
                oos[oos_visible],
                width="stretch",
                hide_index=True,
                column_config={
                    "coverage_pct": _number("Coverage %", "%.1f"),
                    "mean_return_pct": _number("Mean Return %", "%.2f"),
                    "median_return_pct": _number("Median Return %", "%.2f"),
                    "win_rate_pct": _number("Win Rate %", "%.1f"),
                    "mean_alpha_vs_ihsg_pct": _number("Alpha vs IHSG %", "%.2f"),
                    "mean_alpha_vs_sector_pct": _number("Alpha vs Sector %", "%.2f"),
                    "mean_mfe_pct": _number("MFE %", "%.2f"),
                    "mean_mae_pct": _number("MAE %", "%.2f"),
                },
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
        Read-only view of experimental horizon strategies, rankings, financial shadow scoring and Gate-15 lifecycle state.
        Production ranking remains isolated.
      </div>
      <div class="idx-chip-row">
        <span class="idx-chip idx-chip-warning">RESEARCH ONLY</span>
        <span class="idx-chip">5D / 20D / 60D</span>
        <span class="idx-chip">FORWARD OOS</span>
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
for frame in (
    predictive,
    financial,
    lifecycle,
    bundle.horizon_rankings,
    bundle.horizon_snapshots,
    bundle.horizon_outcomes,
    bundle.horizon_policies,
):
    if frame is not None and not frame.empty and "production_influence_enabled" in frame.columns:
        all_influence_off = all_influence_off and not frame["production_influence_enabled"].fillna(False).astype(bool).any()

current_horizon_date = _latest(bundle.horizon_rankings, "as_of_date")
active_horizon_rows = 0
if bundle.horizon_rankings is not None and not bundle.horizon_rankings.empty and "signal_state" in bundle.horizon_rankings.columns:
    active_horizon_rows = int((bundle.horizon_rankings["signal_state"].astype(str) == "ACTIVE").sum())

render_health_cards(
    [
        ("Horizon Ranking", current_horizon_date, f"{active_horizon_rows} active research candidates"),
        ("Research Strategies", len(lifecycle), "lifecycle candidates still outside production"),
        ("Shadow Signal", _latest(predictive, "signal_date"), f"{len(predictive)} ranking rows loaded"),
        ("Financial Shadow", _latest(financial, "as_of_date"), f"{len(financial)} comparison rows loaded"),
        ("Production Influence", "OFF" if all_influence_off else "CHECK", "research lane is isolated from execution scoring"),
    ]
)

if bundle.errors:
    with st.expander(f"Research data warnings ({len(bundle.errors)})", expanded=False):
        for message in bundle.errors:
            st.caption(message)

horizon_tab, shadow_tab, financial_tab, lifecycle_tab = st.tabs(
    [
        "⌁ Horizon Strategies",
        "🧪 Shadow Ranking",
        "◫ Financial Shadow",
        "◇ Strategy Lifecycle / Gate-15",
    ]
)

with horizon_tab:
    render_section(
        "Research Strategy Horizons",
        "Frozen 5D, 20D and 60D research contracts calculated from the latest canonical close and evaluated prospectively.",
    )
    five_tab, twenty_tab, sixty_tab = st.tabs(
        ["5D · BRFE-5", "20D · BPL-20", "60D · QBA-60"]
    )
    with five_tab:
        _render_horizon_strategy(
            "BRFE_5",
            5,
            "BRFE-5 · Bull-Regime Foreign Expansion",
            "Tactical foreign-flow expansion only when IHSG trailing 5D and 20D are both positive. Fixed forward horizon: 5 sessions.",
            extra_columns=[
                "foreign_net_volume_pct",
                "ihsg_return_5d_pct",
                "ihsg_return_20d_pct",
                "risk_event_20d_count",
                "capital_action_90d_count",
            ],
        )
    with twenty_tab:
        _render_horizon_strategy(
            "BPL_20",
            20,
            "BPL-20 · Broad Participation Liquid",
            "Broad-market participation regime when Top-10 value concentration is low; stock lane requires minimum liquidity. Fixed forward horizon: 20 sessions.",
            extra_columns=["top10_value_share_pct", "stock_residual_activity_z"],
        )
    with sixty_tab:
        _render_horizon_strategy(
            "QBA_60",
            60,
            "QBA-60 · Quiet Balance Accumulation",
            "PIT FIN_BALANCE strength plus quiet residual activity. Liquidity is displayed but intentionally not a hard filter because the historical edge weakened under a strict liquidity gate.",
            extra_columns=[
                "fin_balance_score",
                "stock_residual_activity_z",
                "market_activity_intensity_z",
                "risk_event_20d_count",
                "capital_action_90d_count",
            ],
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
            show_n = st.select_slider("Rows", options=[20, 50, 100, 200], value=50, key="shadow_rows")
        with filter_b:
            ticker_query = st.text_input("Ticker", placeholder="e.g. SIDO, PGEO, IMPC", key="shadow_ticker_query")
        with filter_c:
            timing_options = sorted(
                predictive.get("timing_quality", pd.Series(dtype=object)).dropna().astype(str).unique().tolist()
            )
            selected_timing = st.multiselect(
                "Timing quality", timing_options, default=timing_options, key="shadow_timing_filter"
            )

        view = predictive.copy()
        if ticker_query.strip():
            view = view[view["ticker"].astype(str).str.contains(ticker_query.strip(), case=False, regex=False)]
        if selected_timing and "timing_quality" in view.columns:
            view = view[view["timing_quality"].astype(str).isin(selected_timing)]
        view = view.head(int(show_n))

        visible = [
            "research_status", "shadow_rank", "ticker", "shadow_predictive_score", "timing_quality",
            "model_state", "evidence_coverage_pct", "component_strength_score", "reliability_adjusted_score",
            "current_tradeable", "production_actionable", "base_close", "production_rank", "rank_displacement",
            "active_interactions",
        ]
        visible = [column for column in visible if column in view.columns]
        st.dataframe(
            view[visible], width="stretch", hide_index=True, height=620,
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
            "Rows to display", options=[20, 50, 100, 200], value=50, key="financial_shadow_rows"
        )
        view = financial.head(int(financial_n))
        visible = [
            "research_status", "financial_shadow_rank", "ticker", "sector", "financial_state",
            "financial_shadow_score", "production_rank", "production_final_score", "evaluation_weight_pct",
            "evaluation_blend_rank", "evaluation_blend_score", "production_action", "production_real_money_state",
        ]
        visible = [column for column in visible if column in view.columns]
        st.dataframe(
            view[visible], width="stretch", hide_index=True, height=620,
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
            st.caption(" · ".join(f"{state}: {count}" for state, count in state_counts.items()))

        visible = [
            "research_status", "candidate_id", "candidate_type", "promotion_state", "integrity_state",
            "assessment_state", "robustness_state", "independent_matured_signal_dates",
            "minimum_matured_sample_across_horizons", "weight", "maximum_weight", "transition_reason",
            "assessed_at", "gate15_assessed_at",
        ]
        visible = [column for column in visible if column in lifecycle.columns]
        st.dataframe(
            lifecycle[visible], width="stretch", hide_index=True, height=600,
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
