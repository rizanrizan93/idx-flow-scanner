from __future__ import annotations

from typing import Callable

import pandas as pd
import streamlit as st

from .research_adaptive import AdaptiveResearchBundle


def _as_dict(value) -> dict:
    return value if isinstance(value, dict) else {}


def _as_list(value) -> list[dict]:
    if not isinstance(value, list):
        return []
    return [row for row in value if isinstance(row, dict)]


def render_adaptive_router(
    bundle: AdaptiveResearchBundle,
    *,
    render_section: Callable[[str, str], None],
    number_column: Callable[[str, str], object],
) -> None:
    render_section(
        "Adaptive Horizon Router v2 · 40/40/20",
        "Research-only portfolio router: 40% BRFE-5, 40% BPL-20 and 20% QBA-60. A sleeve whose frozen gate is OFF stays in cash; no weight is reallocated to another sleeve.",
    )

    if bundle.snapshots.empty:
        st.info("Adaptive router snapshot belum tersedia.")
        return

    latest = bundle.snapshots.sort_values("signal_date", ascending=False).iloc[0]
    mature = pd.DataFrame()
    if not bundle.outcomes.empty and "maturity_state" in bundle.outcomes.columns:
        mature = bundle.outcomes[
            bundle.outcomes["maturity_state"].astype(str).str.startswith("MATURE")
        ]

    c1, c2, c3, c4 = st.columns(4)
    c1.metric("Latest close", str(latest.get("signal_date", "—")))
    c2.metric("Router state", str(latest.get("router_state", "—")))
    c3.metric("Active allocation", f"{float(latest.get('active_weight_pct', 0) or 0):.0f}%")
    c4.metric("Cash", f"{float(latest.get('cash_weight_pct', 0) or 0):.0f}%")

    allocation = pd.DataFrame(_as_list(latest.get("allocation")))
    if not allocation.empty:
        visible = [
            "strategy_id",
            "horizon_days",
            "market_gate_state",
            "signal_state",
            "eligible_count",
            "target_weight_pct",
            "allocated_weight_pct",
        ]
        visible = [column for column in visible if column in allocation.columns]
        st.dataframe(
            allocation[visible],
            width="stretch",
            hide_index=True,
            column_config={
                "horizon_days": number_column("Horizon", "%dD"),
                "eligible_count": number_column("Candidates", "%d"),
                "target_weight_pct": number_column("Target Weight %", "%.0f"),
                "allocated_weight_pct": number_column("Allocated %", "%.0f"),
            },
        )

    st.caption(
        "Frozen routing semantics: inactive sleeve → CASH. Bobot 40/40/20 tidak dipindahkan ke sleeve lain. "
        "Prospective portfolio cohort baru dinilai selesai setelah seluruh sleeve yang ACTIVE pada tanggal sinyal sudah mature."
    )

    if not bundle.policies.empty:
        policy = bundle.policies.iloc[0]
        evidence = _as_dict(policy.get("historical_evidence"))
        portfolio = _as_dict(evidence.get("portfolio_40_40_20"))
        if portfolio:
            st.markdown("**Historical research evidence — frozen at discovery**")
            h1, h2, h3, h4 = st.columns(4)
            h1.metric("Historical compounded", f"{float(portfolio.get('historical_compounded_return_pct', 0)):.1f}%")
            h2.metric("Early block", f"{float(portfolio.get('early_return_pct', 0)):.1f}%")
            h3.metric("Middle block", f"{float(portfolio.get('middle_return_pct', 0)):.1f}%")
            h4.metric("Recent block", f"{float(portfolio.get('recent_return_pct', 0)):.1f}%")
            st.caption(
                "Historical result is post-hoc challenger evidence, not independent confirmation. "
                f"0.5% cost stress ≈ {float(portfolio.get('cost_0_5pct_per_cycle_return_pct', 0)):.1f}% · "
                f"1.0% cost stress ≈ {float(portfolio.get('cost_1_0pct_per_cycle_return_pct', 0)):.1f}% · "
                f"QBA winner-cap + 0.5% cost stress ≈ {float(portfolio.get('qba_winner_cap_20pct_plus_cost_0_5pct_return_pct', 0)):.1f}%."
            )

    st.markdown("**Prospective Adaptive OOS**")
    if bundle.outcomes.empty:
        st.info("Belum ada adaptive outcome. Scheduler akan mengisinya dari outcome 5D/20D/60D existing.")
        return

    oos = bundle.outcomes.sort_values("signal_date", ascending=False).head(120)
    visible = [
        "signal_date",
        "completion_target_date",
        "maturity_state",
        "active_sleeve_count",
        "mature_sleeve_count",
        "active_weight_pct",
        "mature_weight_pct",
        "cash_weight_pct",
        "pending_weight_pct",
        "portfolio_return_pct",
        "portfolio_alpha_vs_ihsg_pct",
        "weighted_mfe_pct",
        "weighted_mae_pct",
    ]
    visible = [column for column in visible if column in oos.columns]
    st.dataframe(
        oos[visible],
        width="stretch",
        hide_index=True,
        column_config={
            "active_sleeve_count": number_column("Active Sleeves", "%d"),
            "mature_sleeve_count": number_column("Mature Sleeves", "%d"),
            "active_weight_pct": number_column("Active %", "%.0f"),
            "mature_weight_pct": number_column("Mature %", "%.0f"),
            "cash_weight_pct": number_column("Cash %", "%.0f"),
            "pending_weight_pct": number_column("Pending %", "%.0f"),
            "portfolio_return_pct": number_column("Portfolio Return %", "%.2f"),
            "portfolio_alpha_vs_ihsg_pct": number_column("Alpha vs IHSG %", "%.2f"),
            "weighted_mfe_pct": number_column("Weighted MFE %", "%.2f"),
            "weighted_mae_pct": number_column("Weighted MAE %", "%.2f"),
        },
    )
    st.caption(
        "Weighted MFE/MAE adalah sleeve-weighted basket proxies, bukan synchronized intraportfolio path drawdown. "
        "Rows NO_ACTIVE_SLEEVES adalah cash/no-trade observations dan tidak boleh dihitung sebagai winning trades."
    )

    with st.expander("Latest sleeve outcome detail", expanded=False):
        latest_outcome = oos.iloc[0]
        sleeve_rows = pd.DataFrame(_as_list(latest_outcome.get("sleeve_outcomes")))
        if sleeve_rows.empty:
            st.info("Belum ada sleeve outcome detail.")
        else:
            st.dataframe(sleeve_rows, width="stretch", hide_index=True)

    if not mature.empty:
        realized = pd.to_numeric(mature.get("portfolio_return_pct"), errors="coerce").dropna()
        if not realized.empty:
            st.caption(
                f"Mature prospective cohorts: {len(realized)} · mean portfolio return {realized.mean():.2f}% · "
                f"positive cohorts {(realized.gt(0).mean()*100):.1f}%."
            )
