from __future__ import annotations

import json
import os
import sys
from pathlib import Path

import pandas as pd
import streamlit as st

ROOT = Path(__file__).resolve().parent
SRC = ROOT / "src"
if str(SRC) not in sys.path:
    sys.path.insert(0, str(SRC))

from idx_flow_scanner.config import ScannerConfig
from idx_flow_scanner.data import fetch_yfinance_prices, normalize_broker_summary, parse_universe
from idx_flow_scanner.pipeline import scan_universe
from idx_flow_scanner.storage import SupabaseStore
from idx_flow_scanner.database_first import database_first_price_loader

st.set_page_config(page_title="IDX Flow Scanner", page_icon="📡", layout="wide")
st.title("IDX Flow Scanner")
st.caption("Clean-room bandarmology / broker-flow research engine • direct evidence first • SMC/ICT execution overlay")

with st.sidebar:
    st.header("Input")
    universe_file = st.file_uploader("Universe CSV", type=["csv"], help="Kolom ticker. Contoh tersedia di data/templates.")
    broker_file = st.file_uploader(
        "Broker Summary CSV",
        type=["csv"],
        help="Direct broker evidence. Tanpa file ini hasil otomatis berstatus PRICE_PROXY / RESEARCH_ONLY.",
    )
    period = st.selectbox("OHLCV lookback", ["6mo", "1y", "2y"], index=1)
    use_database = st.checkbox("Database-first Supabase", value=True, help="Jika secret tersedia: baca cache/broker DB terlebih dulu, lalu backfill harga yang kurang.")
    persist = st.checkbox("Persist hasil scan", value=True)
    run = st.button("Run Scan", type="primary", use_container_width=True)

st.info(
    "Scanner tidak menganggap price/volume proxy sebagai data bandar langsung. "
    "Eligibility real-money membutuhkan broker evidence yang cukup dan lolos guardrail."
)

if "last_results" not in st.session_state:
    st.session_state.last_results = None
    st.session_state.last_errors = []
    st.session_state.last_run_id = None

if run:
    if universe_file is None:
        st.error("Upload universe CSV terlebih dahulu.")
        st.stop()
    universe_df = pd.read_csv(universe_file)
    universe = parse_universe(universe_df)
    if not universe:
        st.error("Universe tidak berisi ticker yang valid.")
        st.stop()

    store = None
    if use_database:
        try:
            supabase_url = st.secrets.get("SUPABASE_URL", os.getenv("SUPABASE_URL"))
            supabase_key = st.secrets.get("SUPABASE_SECRET_KEY", os.getenv("SUPABASE_SECRET_KEY"))
            if supabase_url and supabase_key:
                store = SupabaseStore(supabase_url, supabase_key)
        except Exception:
            store = None

    if broker_file is not None:
        try:
            broker = normalize_broker_summary(pd.read_csv(broker_file))
            if store is not None:
                store.upsert_broker_flows(broker)
        except Exception as exc:
            st.error(f"Broker Summary invalid: {exc}")
            st.stop()
    elif store is not None:
        try:
            broker = store.load_broker_flows(universe)
        except Exception as exc:
            st.warning(f"Broker database read failed; continuing as proxy: {exc}")
            broker = pd.DataFrame()
    else:
        broker = pd.DataFrame()

    bar = st.progress(0.0, text="Starting...")
    status = st.empty()

    load_price = database_first_price_loader(store, period=period)

    def progress(i: int, total: int, ticker: str) -> None:
        bar.progress(i / max(total, 1), text=f"{i}/{total} • {ticker}")
        status.caption(f"Processing {ticker}")

    config = ScannerConfig()
    run_id, results, errors = scan_universe(universe, load_price, broker, config, progress)
    st.session_state.last_results = results
    st.session_state.last_errors = errors
    st.session_state.last_run_id = run_id

    if persist and store is not None:
        try:
            store.create_run(run_id, len(universe), {"period": period, "version": "0.1.1"})
            store.save_results(run_id, results)
            store.finish_run(run_id, len(results), len(errors))
            st.success(f"Persisted to Supabase • run {run_id}")
        except Exception as exc:
            st.warning(f"Scan selesai, persistence gagal: {exc}")
    elif persist:
        st.warning("Scan selesai, tetapi Supabase secrets belum tersedia sehingga hasil belum dipersist.")

results = st.session_state.last_results
errors = st.session_state.last_errors
if isinstance(results, pd.DataFrame) and not results.empty:
    st.subheader("Decision Priority")
    eligible = results[results["real_money_state"] == "ELIGIBLE"].copy()
    c1, c2, c3, c4 = st.columns(4)
    c1.metric("Scanned", len(results))
    c2.metric("Real-money eligible", len(eligible))
    c3.metric("Broker-direct", int((results["evidence_tier"] == "BROKER_DIRECT").sum()))
    c4.metric("Median evidence", f"{results['evidence_coverage_pct'].median():.0f}%")

    cols = [
        "ticker", "final_score", "phase", "action", "real_money_state",
        "evidence_tier", "evidence_coverage_pct", "accumulation_score",
        "operator_dominance_score", "distribution_risk",
        "estimated_smart_money_cost", "premium_to_cost_pct",
        "entry_low", "entry_high", "invalidation", "tp1", "tp2",
    ]
    st.dataframe(results[cols], use_container_width=True, hide_index=True)

    st.subheader("Top Silent Accumulation")
    silent = results[results["phase"].isin(["ACCUMULATION", "EARLY_MARKUP"])].sort_values("final_score", ascending=False)
    st.dataframe(silent[cols].head(20), use_container_width=True, hide_index=True)

    st.subheader("Distribution Warning")
    dist = results.sort_values("distribution_risk", ascending=False)
    st.dataframe(dist[["ticker", "distribution_risk", "phase", "action", "final_score", "guardrail_reason"]].head(20), use_container_width=True, hide_index=True)

    st.subheader("Single Ticker Audit")
    selected = st.selectbox("Ticker", results["ticker"].tolist())
    row = results[results["ticker"] == selected].iloc[0].to_dict()
    a, b, c = st.columns(3)
    a.metric("Final Score", row["final_score"])
    b.metric("Phase", row["phase"])
    c.metric("State", row["real_money_state"])
    st.write(row["guardrail_reason"])
    st.json(row.get("diagnostics", {}), expanded=False)

    st.download_button(
        "Download scan CSV",
        data=results.drop(columns=["diagnostics"], errors="ignore").to_csv(index=False).encode(),
        file_name=f"idx_flow_scan_{st.session_state.last_run_id}.csv",
        mime="text/csv",
    )

if errors:
    with st.expander(f"Errors ({len(errors)})"):
        st.dataframe(pd.DataFrame(errors), use_container_width=True, hide_index=True)
