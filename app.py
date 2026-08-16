from __future__ import annotations

import os
import sys
import uuid
from pathlib import Path

import pandas as pd
import streamlit as st

ROOT = Path(__file__).resolve().parent
SRC = ROOT / "src"
if str(SRC) not in sys.path:
    sys.path.insert(0, str(SRC))

from idx_flow_scanner.config import ScannerConfig
from idx_flow_scanner.data import normalize_broker_summary, parse_universe
from idx_flow_scanner.database_first import prepare_database_first_prices
from idx_flow_scanner.managed import (
    ManagedDecision,
    decide_managed_run,
    load_bundled_universe,
    load_persisted_results,
    mark_stale_managed_runs,
    recent_runs,
    universe_signature,
)
from idx_flow_scanner.pipeline import scan_universe
from idx_flow_scanner.providers.idx_official import (
    fetch_idx_official_flow_history,
    load_cached_idx_official_flows,
    upsert_idx_official_flows,
)
from idx_flow_scanner.storage import SupabaseStore

APP_VERSION = "0.1.5"
DEFAULT_UNIVERSE_PATH = ROOT / "data" / "universe" / "idx_400_syariah.csv"
MANAGED_MIN_VALID_RATIO = 0.90

st.set_page_config(page_title="IDX Flow Scanner", page_icon="📡", layout="wide")
st.title("IDX Flow Scanner")
st.caption(
    f"v{APP_VERSION} • clean-room bandarmology / broker-flow research engine • "
    "database-first • managed 400-ticker mode • free official IDX foreign-flow overlay"
)


def connect_store(enabled: bool) -> tuple[SupabaseStore | None, str | None]:
    if not enabled:
        return None, None
    try:
        supabase_url = st.secrets.get("SUPABASE_URL", os.getenv("SUPABASE_URL"))
        supabase_key = st.secrets.get("SUPABASE_SECRET_KEY", os.getenv("SUPABASE_SECRET_KEY"))
        if not supabase_url or not supabase_key:
            return None, "SUPABASE_URL / SUPABASE_SECRET_KEY belum tersedia"
        return SupabaseStore(supabase_url, supabase_key), None
    except Exception as exc:
        return None, str(exc)


with st.sidebar:
    st.header("Managed Scan")
    managed_auto = st.toggle(
        "Managed auto-run",
        value=True,
        help="Dengan universe bawaan, scanner otomatis menjalankan scan bila belum ada run versi ini yang valid/fresh.",
    )
    universe_file = st.file_uploader(
        "Override universe CSV (opsional)",
        type=["csv"],
        help="Kosongkan untuk memakai universe syariah 400 ticker bawaan.",
    )
    broker_file = st.file_uploader(
        "Broker Summary CSV (opsional)",
        type=["csv"],
        help="Direct broker evidence. Tanpa data broker asli hasil tetap PRICE_PROXY / GUARDED.",
    )
    period = st.selectbox("OHLCV lookback", ["6mo", "1y", "2y"], index=1)
    use_database = st.checkbox("Database-first Supabase", value=True)
    use_idx_official = st.checkbox(
        "Official IDX foreign flow",
        value=True,
        help="Gratis. Mengambil ForeignBuy/ForeignSell market-wide dari endpoint resmi IDX, lalu menyimpan cache ke Supabase.",
    )
    persist = st.checkbox("Persist hasil scan", value=True)
    run_manual = st.button("Run / Re-run sekarang", type="primary", width="stretch")

st.info(
    "Price/volume tidak dianggap data bandar langsung. Official IDX foreign flow adalah evidence resmi "
    "tambahan, tetapi BROKER_DIRECT tetap hanya diberikan jika broker-summary per saham benar-benar tersedia."
)

if "last_results" not in st.session_state:
    st.session_state.last_results = None
    st.session_state.last_errors = []
    st.session_state.last_run_id = None
    st.session_state.last_price_stats = None
    st.session_state.last_official_stats = None

if universe_file is None:
    universe = load_bundled_universe(DEFAULT_UNIVERSE_PATH)
    universe_source = "BUNDLED_400_SYARIAH"
else:
    universe_df = pd.read_csv(universe_file)
    universe = parse_universe(universe_df)
    universe_source = "USER_UPLOAD"

if not universe:
    st.error("Universe tidak berisi ticker yang valid.")
    st.stop()

signature = universe_signature(universe)
store, store_error = connect_store(use_database)
if store_error:
    st.warning(f"Supabase belum siap: {store_error}")

managed_decision = ManagedDecision(False, "managed mode disabled")
if managed_auto and universe_source == "BUNDLED_400_SYARIAH" and persist and store is not None:
    try:
        mark_stale_managed_runs(store, max_age_minutes=60)
        runs = recent_runs(store, limit=25)
        managed_decision = decide_managed_run(
            runs,
            version=APP_VERSION,
            universe_count=len(universe),
            signature=signature,
            min_success_ratio=MANAGED_MIN_VALID_RATIO,
        )
    except Exception as exc:
        managed_decision = ManagedDecision(False, f"managed gate unavailable: {exc}")

m1, m2, m3 = st.columns(3)
m1.metric("Universe", len(universe))
m2.metric("Mode", "MANAGED" if universe_source == "BUNDLED_400_SYARIAH" else "CUSTOM")
m3.metric("DB", "CONNECTED" if store is not None else "UNAVAILABLE")

if managed_auto and universe_source == "BUNDLED_400_SYARIAH":
    if managed_decision.should_run:
        st.info(f"Managed engine: {managed_decision.reason}. Scan akan dijalankan otomatis.")
    else:
        st.caption(f"Managed engine: {managed_decision.reason}")

if (
    st.session_state.last_results is None
    and store is not None
    and managed_decision.blocking_run_id
    and "valid" in managed_decision.reason
):
    try:
        persisted = load_persisted_results(store, managed_decision.blocking_run_id)
        if not persisted.empty:
            st.session_state.last_results = persisted
            st.session_state.last_errors = []
            st.session_state.last_run_id = managed_decision.blocking_run_id
    except Exception:
        pass

trigger_scan = bool(run_manual or managed_decision.should_run)
if trigger_scan and universe_source != "BUNDLED_400_SYARIAH" and managed_decision.should_run:
    trigger_scan = bool(run_manual)

if trigger_scan:
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
            st.warning(f"Broker database read failed; continuing as PRICE_PROXY: {exc}")
            broker = pd.DataFrame()
    else:
        broker = pd.DataFrame()

    bar = st.progress(0.0, text="Preparing OHLCV...")
    status_box = st.empty()
    run_id = str(uuid.uuid4())
    run_record_created = False
    config = ScannerConfig()
    run_mode = "managed" if universe_source == "BUNDLED_400_SYARIAH" and managed_auto and not run_manual else "manual"

    if persist and store is not None:
        try:
            store.create_run(
                run_id,
                len(universe),
                {
                    "period": period,
                    "version": APP_VERSION,
                    "mode": run_mode,
                    "universe_source": universe_source,
                    "universe_signature": signature,
                    "minimum_price_bars": config.minimum_price_bars,
                    "official_idx_foreign_flow": bool(use_idx_official),
                },
            )
            store.update_run_progress(run_id, 0, "OHLCV_PREP")
            run_record_created = True
        except Exception as exc:
            st.warning(f"Could not create RUNNING record in Supabase: {exc}")

    load_price, price_stats = prepare_database_first_prices(
        universe,
        store,
        period=period,
        min_rows=config.minimum_price_bars,
        status=lambda text: status_box.caption(text),
    )
    st.session_state.last_price_stats = price_stats

    official_flow = pd.DataFrame()
    official_stats = {"days": 0, "tickers": 0, "freshest": None, "source": "DISABLED"}
    if use_idx_official:
        status_box.caption("Loading official IDX foreign flow...")
        try:
            if store is not None:
                official_flow = load_cached_idx_official_flows(store, universe, lookback_calendar_days=55)
            cached_days = int(official_flow["trade_date"].nunique()) if not official_flow.empty else 0
            latest_price_dates = []
            for ticker in universe[:20]:
                frame = load_price(ticker)
                if not frame.empty:
                    latest_price_dates.append(pd.to_datetime(frame["date"], errors="coerce").max())
            end_date = max([d for d in latest_price_dates if pd.notna(d)], default=pd.Timestamp.today())
            freshest_cached = pd.to_datetime(official_flow["trade_date"], errors="coerce").max() if not official_flow.empty else pd.NaT
            need_refresh = cached_days < 18 or pd.isna(freshest_cached) or freshest_cached.normalize() < pd.Timestamp(end_date).normalize()
            if need_refresh:
                status_box.caption(f"Refreshing official IDX foreign flow • cache {cached_days} trading days")
                fresh = fetch_idx_official_flow_history(
                    universe,
                    end_date=pd.Timestamp(end_date).date(),
                    target_trading_days=20,
                    max_calendar_days=40,
                )
                if not fresh.empty:
                    if store is not None:
                        upsert_idx_official_flows(store, fresh)
                    official_flow = pd.concat([official_flow, fresh], ignore_index=True) if not official_flow.empty else fresh
                    official_flow = official_flow.drop_duplicates(["ticker", "trade_date", "source"], keep="last")
            if not official_flow.empty:
                official_stats = {
                    "days": int(official_flow["trade_date"].nunique()),
                    "tickers": int(official_flow["ticker"].nunique()),
                    "freshest": str(pd.to_datetime(official_flow["trade_date"], errors="coerce").max().date()),
                    "source": "IDX_OFFICIAL_STOCK_SUMMARY",
                }
        except Exception as exc:
            st.warning(f"Official IDX flow unavailable; scan continues without it: {exc}")
            official_flow = pd.DataFrame()
            official_stats = {"days": 0, "tickers": 0, "freshest": None, "source": "UNAVAILABLE"}
    st.session_state.last_official_stats = official_stats

    if store is not None and run_record_created:
        store.update_run_progress(run_id, 0, "SCORING")

    def progress(i: int, total: int, ticker: str) -> None:
        bar.progress(i / max(total, 1), text=f"{i}/{total} • {ticker}")
        status_box.caption(f"Scoring {ticker} • {i}/{total}")
        if store is not None and run_record_created and (i == 1 or i % 20 == 0 or i == total):
            store.update_run_progress(run_id, i, ticker)

    _, results, errors = scan_universe(
        universe,
        load_price,
        broker,
        config,
        progress,
        run_id=run_id,
        official_flow_frame=official_flow,
    )
    st.session_state.last_results = results
    st.session_state.last_errors = errors
    st.session_state.last_run_id = run_id

    valid_ratio = len(results) / max(len(universe), 1)
    final_status = "COMPLETED" if valid_ratio >= MANAGED_MIN_VALID_RATIO else "FAILED"

    if persist and store is not None and run_record_created:
        try:
            store.save_results(run_id, results)
            store.finish_run(
                run_id,
                len(results),
                len(errors),
                status=final_status,
                attempted_count=len(universe),
                telemetry={
                    "price_cache_hits": int(price_stats.get("cache_hits", 0)),
                    "price_fetched": int(price_stats.get("fetched_valid", 0)),
                    "price_failures": int(price_stats.get("unavailable", 0)),
                },
            )
            try:
                store.client.table("flow_scan_runs").update({
                    "official_flow_days": int(official_stats.get("days", 0)),
                    "official_flow_tickers": int(official_stats.get("tickers", 0)),
                }).eq("id", run_id).execute()
            except Exception:
                pass
            if final_status == "FAILED":
                st.error(
                    f"Run {run_id} FAILED integrity gate • valid {len(results)}/{len(universe)} "
                    f"({valid_ratio:.1%}) • errors {len(errors)}. Minimum valid ratio = {MANAGED_MIN_VALID_RATIO:.0%}."
                )
            elif errors:
                st.warning(f"Run completed and persisted • {len(results)}/{len(universe)} valid • errors {len(errors)}")
            else:
                st.success(f"Persisted to Supabase • run {run_id} • {len(results)}/{len(universe)} valid")
        except Exception as exc:
            st.warning(f"Scan selesai, persistence gagal: {exc}")
    elif persist:
        st.warning("Scan selesai, tetapi Supabase RUNNING record tidak tersedia sehingga persistence belum terverifikasi.")

results = st.session_state.last_results
errors = st.session_state.last_errors
price_stats = st.session_state.last_price_stats
official_stats = st.session_state.last_official_stats

if isinstance(price_stats, dict):
    st.subheader("Data Integrity")
    p1, p2, p3, p4, p5 = st.columns(5)
    p1.metric("DB OHLCV hits", int(price_stats.get("cache_hits", 0)))
    p2.metric("OHLCV fetched", int(price_stats.get("fetched_valid", 0)))
    p3.metric("OHLCV unavailable", int(price_stats.get("unavailable", 0)))
    p4.metric("IDX flow days", int((official_stats or {}).get("days", 0)))
    p5.metric("IDX flow tickers", int((official_stats or {}).get("tickers", 0)))

if isinstance(results, pd.DataFrame) and not results.empty:
    st.subheader("Decision Priority")
    eligible = results[results["real_money_state"] == "ELIGIBLE"].copy()
    official_coverages = [
        float(d.get("official_foreign_coverage_pct", 0) or 0)
        for d in results.get("diagnostics", pd.Series(dtype=object))
        if isinstance(d, dict)
    ]
    c1, c2, c3, c4, c5 = st.columns(5)
    c1.metric("Scanned valid", len(results))
    c2.metric("Real-money eligible", len(eligible))
    c3.metric("Broker-direct", int((results["evidence_tier"] == "BROKER_DIRECT").sum()))
    c4.metric("Median broker evidence", f"{results['evidence_coverage_pct'].median():.0f}%")
    c5.metric("Median IDX foreign", f"{pd.Series(official_coverages).median():.0f}%" if official_coverages else "0%")

    cols = [
        "ticker", "final_score", "phase", "action", "real_money_state",
        "evidence_tier", "evidence_coverage_pct", "accumulation_score",
        "operator_dominance_score", "distribution_risk",
        "estimated_smart_money_cost", "premium_to_cost_pct",
        "entry_low", "entry_high", "invalidation", "tp1", "tp2",
    ]
    available_cols = [c for c in cols if c in results.columns]
    st.dataframe(results[available_cols], width="stretch", hide_index=True)

    st.subheader("Top Silent Accumulation")
    silent = results[results["phase"].isin(["ACCUMULATION", "EARLY_MARKUP"])].sort_values("final_score", ascending=False)
    st.dataframe(silent[available_cols].head(20), width="stretch", hide_index=True)

    st.subheader("Distribution Warning")
    dist = results.sort_values("distribution_risk", ascending=False)
    dist_cols = [c for c in ["ticker", "distribution_risk", "phase", "action", "final_score", "guardrail_reason"] if c in dist.columns]
    st.dataframe(dist[dist_cols].head(20), width="stretch", hide_index=True)

    st.subheader("Single Ticker Audit")
    selected = st.selectbox("Ticker", results["ticker"].tolist())
    row = results[results["ticker"] == selected].iloc[0].to_dict()
    a, b, c = st.columns(3)
    a.metric("Final Score", row["final_score"])
    b.metric("Phase", row["phase"])
    c.metric("State", row["real_money_state"])
    st.write(row.get("guardrail_reason"))
    st.json(row.get("diagnostics", {}), expanded=False)

    st.download_button(
        "Download scan CSV",
        data=results.drop(columns=["diagnostics", "components"], errors="ignore").to_csv(index=False).encode(),
        file_name=f"idx_flow_scan_{st.session_state.last_run_id}.csv",
        mime="text/csv",
    )

if errors:
    err = pd.DataFrame(errors)
    if not err.empty:
        err["category"] = err["error"].map(
            lambda text: "OHLCV_UNAVAILABLE" if "insufficient price history" in str(text).lower() else str(text)[:120]
        )
        summary = err.groupby("category", dropna=False).size().reset_index(name="count").sort_values("count", ascending=False)
        with st.expander(f"Ticker failures ({len(errors)})", expanded=not isinstance(results, pd.DataFrame) or results.empty):
            st.caption("Ticker failure tidak dihitung sebagai hasil scan valid.")
            st.dataframe(summary, width="stretch", hide_index=True)
            st.dataframe(err[["ticker", "error"]].head(100), width="stretch", hide_index=True)
