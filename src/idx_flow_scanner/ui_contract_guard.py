from __future__ import annotations

from typing import Any

import pandas as pd


UI_CONTRACT_REVISION = "v0.3.23-truthful-output-lanes"


def install_truthful_output_lanes(streamlit_app: Any) -> None:
    """Keep the Streamlit presentation aligned with production evidence semantics.

    The core Streamlit module is intentionally left reusable for tests and small
    local experiments.  Production ``app.py`` installs this guard so Community
    Cloud cannot present stale controls or mix research-only broker states into
    the Broker-Verified Production lane.
    """
    if getattr(streamlit_app, "_idxflow_ui_contract_revision", None) == UI_CONTRACT_REVISION:
        return

    st = streamlit_app.st

    # Streamlit can retain imported modules across hot reloads. Preserve the real
    # primitives once, then always wrap those primitives rather than wrapper chains.
    original_checkbox = getattr(st, "_idxflow_original_checkbox", st.checkbox)
    original_subheader = getattr(st, "_idxflow_original_subheader", st.subheader)
    original_caption = getattr(st, "_idxflow_original_caption", st.caption)
    original_info = getattr(st, "_idxflow_original_info", st.info)
    original_dataframe = getattr(st, "_idxflow_original_dataframe", st.dataframe)

    st._idxflow_original_checkbox = original_checkbox
    st._idxflow_original_subheader = original_subheader
    st._idxflow_original_caption = original_caption
    st._idxflow_original_info = original_info
    st._idxflow_original_dataframe = original_dataframe

    lane_state = {"name": None}

    def checkbox(label: str, *args: Any, **kwargs: Any) -> Any:
        if label == "Index Alpha live pull untuk Final Top 5":
            kwargs = dict(kwargs)
            kwargs.pop("value", None)
            kwargs.pop("disabled", None)
            kwargs.pop("help", None)
            return original_checkbox(
                "Index Alpha broker evidence (cache-only)",
                *args,
                value=False,
                disabled=True,
                help=(
                    "Streamlit tidak melakukan live request Index Alpha. Budget gratis 5 request/hari "
                    "dimiliki GitHub Warm Flow Evidence; scanner hanya membaca evidence verified dari cache/DB."
                ),
                **kwargs,
            )
        return original_checkbox(label, *args, **kwargs)

    lane_titles = {
        "1. Proxy + ZAPI Research — 400 Ticker": ("raw", "1. Raw Research Priority — Proxy + ZAPI"),
        "2. Final Guarded Top 5": ("guarded", "2. Guarded Accumulation Watch — Top 5"),
        "3. Broker-Verified Top 5": ("broker_production", "3. Broker-Verified Production"),
    }

    def subheader(label: str, *args: Any, **kwargs: Any) -> Any:
        mapped = lane_titles.get(label)
        if mapped is None:
            lane_state["name"] = None
            return original_subheader(label, *args, **kwargs)
        lane_state["name"] = mapped[0]
        return original_subheader(mapped[1], *args, **kwargs)

    stale_guarded_caption = (
        "Cohort ini dipilih sebelum Index Alpha. Foreign coverage minimum 70%, score ≥65, "
        "distribution <70, dan price-quality/staleness gate harus lolos."
    )
    truthful_guarded_caption = (
        "Cohort ini dipilih sebelum broker evidence. Foreign coverage minimum 70%, distribution <70, "
        "price-quality/staleness gate, phase/action gate, dan PRICE_PROXY requirement harus lolos. "
        "Tidak ada hard absolute-score floor; lima kandidat sehat terbaik dipilih berdasarkan ranking."
    )
    stale_broker_caption = (
        "BROKER_VERIFIED = direct broker evidence + minimum quality gates. BROKER_PENDING berarti history/quorum "
        "Index Alpha belum cukup; BROKER_REJECT berarti distribusi/avoid setelah broker pass."
    )
    truthful_broker_caption = (
        "Lane production hanya menampilkan BROKER_VERIFIED yang juga BROKER_DIRECT dan ELIGIBLE. "
        "BROKER_PENDING/BROKER_GUARDED/BROKER_REJECT tetap research diagnostics dan tidak dipromosikan ke production."
    )

    def caption(body: Any, *args: Any, **kwargs: Any) -> Any:
        if body == stale_guarded_caption:
            body = truthful_guarded_caption
        elif body == stale_broker_caption:
            body = truthful_broker_caption
        return original_caption(body, *args, **kwargs)

    stale_info = (
        "Broker evidence tidak ikut menentukan Final Guarded Top 5. Index Alpha baru dibaca/ditarik setelah cohort Top 5 terbentuk. "
        "BROKER_DIRECT tetap membutuhkan ≥10 broker-days, coverage/provenance quorum, broker balance, dan price-quality gate."
    )
    truthful_info = (
        "Broker evidence tidak ikut menentukan Guarded Accumulation Watch. Streamlit hanya membaca verified Index Alpha cache/DB "
        "setelah Top 5 terbentuk; lima request/hari dimiliki audited GitHub warm-cache job. BROKER_DIRECT tetap membutuhkan "
        "minimum broker history/coverage, distinct-broker quorum, closed-book balance, verified provenance, price-quality, "
        "freshness, dan corporate-action gates."
    )

    def info(body: Any, *args: Any, **kwargs: Any) -> Any:
        if body == stale_info:
            body = truthful_info
        return original_info(body, *args, **kwargs)

    def dataframe(data: Any = None, *args: Any, **kwargs: Any) -> Any:
        if lane_state["name"] == "broker_production" and isinstance(data, pd.DataFrame):
            frame = data.copy()
            status = frame.get("broker_verification_status", pd.Series(index=frame.index, dtype=object)).astype(str)
            tier = frame.get("evidence_tier", pd.Series(index=frame.index, dtype=object)).astype(str)
            state = frame.get("real_money_state", pd.Series(index=frame.index, dtype=object)).astype(str)
            frame = frame[status.eq("BROKER_VERIFIED") & tier.eq("BROKER_DIRECT") & state.eq("ELIGIBLE")].copy()
            if frame.empty:
                return original_info(
                    "Belum ada Broker-Verified Production. Kandidat broker masih pending/guarded/reject atau strict direct gate belum terpenuhi."
                )
            data = frame
        return original_dataframe(data, *args, **kwargs)

    st.checkbox = checkbox
    st.subheader = subheader
    st.caption = caption
    st.info = info
    st.dataframe = dataframe
    streamlit_app._idxflow_ui_contract_revision = UI_CONTRACT_REVISION
