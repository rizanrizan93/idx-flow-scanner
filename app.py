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
from idx_flow_scanner.foreign_evidence import prepare_foreign_evidence
from idx_flow_scanner.managed import (
    ManagedDecision,
    decide_managed_run,
    load_bundled_universe,
    load_persisted_results,
    mark_stale_managed_runs,
    recent_runs,
    universe_signature,
)
from idx_flow_scanner.outcomes import refresh_pending_outcomes, seed_signal_outcomes
from idx_flow_scanner.pipeline import scan_universe
from idx_flow_scanner.providers.goapi import (
    load_bundled_goapi_broker_flows,
    merge_goapi_broker_frames,
)
from idx_flow_scanner.providers.indexalpha import load_bundled_indexalpha_broker_flows
from idx_flow_scanner.providers.idx_official import (
    fetch_idx_official_flow_history,
    load_bundled_idx_official_flows,
    load_cached_idx_official_flows,
    merge_official_flow_frames,
    upsert_idx_official_flows,
)
from idx_flow_scanner.providers.zapi import load_bundled_zapi_foreign_flows
from idx_flow_scanner.vendor_foreign_store import (
    ZAPI_VENDOR_SOURCES,
    load_zapi_vendor_foreign_flows,
    upsert_zapi_vendor_foreign_flows,
)
from idx_flow_scanner.storage import SupabaseStore

APP_VERSION = "0.2.6"
DEFAULT_UNIVERSE_PATH = ROOT / "data" / "universe" / "idx_400_syariah.csv"
MANAGED_MIN_VALID_RATIO = 0.90

st.set_page_config(page_title="IDX Flow Scanner", page_icon="📡", layout="wide")
st.title("IDX Flow Scanner")
st.caption(
    f"v{APP_VERSION} • clean-room bandarmology / accumulation engine • database-first • "
    "managed 400-ticker mode • direct IDX + Zapi IDX-derived foreign shares • "
    "optional Index Alpha / GOAPI stock-level broker evidence • provenance-gated bandar cost • OOS memory"
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


def data_stats(frame: pd.DataFrame) -> dict[str, object]:
    if frame is None or frame.empty:
        return {"rows": 0, "tickers": 0, "days": 0, "verified_tickers": 0, "freshest": None}
    dates = pd.to_datetime(frame.get("trade_date"), errors="coerce")
    verified_tickers = 0
    if "source_verified" in frame.columns:
        raw = frame["source_verified"]
        verified = raw.fillna(False) if pd.api.types.is_bool_dtype(raw) else raw.astype(str).str.strip().str.lower().isin({"1", "true", "yes", "y", "verified"})
        verified_tickers = int(frame.loc[verified, "ticker"].nunique())
    return {
        "rows": int(len(frame)),
        "tickers": int(frame["ticker"].nunique()) if "ticker" in frame.columns else 0,
        "days": int(dates.nunique()) if dates is not None else 0,
        "verified_tickers": verified_tickers,
        "freshest": str(dates.max().date()) if dates is not None and pd.notna(dates.max()) else None,
    }


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
        help=(
            "Direct broker evidence harus punya source_verified=true dan provenance yang dapat diaudit. "
            "File tanpa provenance tetap research-only."
        ),
    )
    period = st.selectbox("OHLCV lookback", ["6mo", "1y", "2y"], index=1)
    use_database = st.checkbox("Database-first Supabase", value=True)
    use_foreign = st.checkbox(
        "Foreign flow evidence",
        value=True,
        help=(
            "Sumber share-unit: direct IDX dan Zapi IDX-derived. Satu sumber dipilih per ticker berdasarkan "
            "coverage; tie selalu memilih direct IDX agar tidak terjadi double counting."
        ),
    )
    persist = st.checkbox("Persist hasil scan", value=True)
    run_manual = st.button("Run / Re-run sekarang", type="primary", width="stretch")

st.info(
    "Evidence hierarchy: verified stock-level broker summary > IDX-derived foreign flow > OHLCV proxy. "
    "Harga Bandar Est. hanya ditampilkan jika broker summary lolos BROKER_DIRECT. Foreign flow dan OHLCV tidak pernah "
    "dipromosikan menjadi harga bandar. Broker direct tetap harus lolos coverage, history, broker quorum, buy/sell balance, "
    "verified provenance, dan price-quality gate."
)

for key, value in {
    "last_results": None,
    "last_errors": [],
    "last_run_id": None,
    "last_price_stats": None,
    "last_broker_stats": None,
    "last_direct_idx_stats": None,
    "last_zapi_stats": None,
    "last_foreign_selection_stats": None,
    "last_outcome_stats": None,
}.items():
    st.session_state.setdefault(key, value)

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
    db_broker = pd.DataFrame()
    bundled_broker = pd.DataFrame()
    if broker_file is not None:
        try:
            broker = normalize_broker_summary(pd.read_csv(broker_file))
            if store is not None:
                store.upsert_broker_flows(broker)
        except Exception as exc:
            st.error(f"Broker Summary invalid: {exc}")
            st.stop()
    else:
        if store is not None:
            try:
                db_broker = store.load_broker_flows(universe)
            except Exception as exc:
                st.warning(f"Broker database read failed; continuing with bundled evidence/PRICE_PROXY: {exc}")
        bundled_goapi = load_bundled_goapi_broker_flows(universe)
        bundled_indexalpha = load_bundled_indexalpha_broker_flows(universe)
        bundled_broker = merge_goapi_broker_frames(bundled_goapi, bundled_indexalpha)
        broker = merge_goapi_broker_frames(db_broker, bundled_broker)
        if store is not None and not bundled_broker.empty:
            try:
                store.upsert_broker_flows(bundled_broker)
            except Exception as exc:
                st.caption(f"Bundled verified broker cache could not be persisted: {exc}")
    broker_stats = data_stats(broker)
    st.session_state.last_broker_stats = broker_stats

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
                    "foreign_flow_enabled": bool(use_foreign),
                    "direct_idx_transport_cache": True,
                    "zapi_idx_foreign_transport_cache": True,
                    "zapi_vendor_foreign_db": True,
                    "foreign_evidence_selector": "BEST_COVERAGE_DIRECT_IDX_TIE_BREAK",
                    "goapi_broker_transport_cache": True,
                    "indexalpha_broker_transport_cache": True,
                    "broker_contract": "VERIFIED_STOCK_LEVEL_PROVIDER_ROWS",
                    "broker_provenance_gate": True,
                    "bandar_cost_display": "BROKER_DIRECT_ONLY",
                    "market_context": "CROSS_SECTIONAL_400",
                    "price_integrity_gate": True,
                    "bulk_price_cache_rpc": True,
                    "oos_outcome_memory": True,
                },
            )
            store.update_run_progress(run_id, 0, "OHLCV_PREP")
            run_record_created = True
        except Exception as exc:
            st.warning(f"Could not create RUNNING record in Supabase: {exc}")

    def price_status(text: str) -> None:
        status_box.caption(text)
        if store is not None and run_record_created:
            store.update_run_progress(run_id, 0, "OHLCV_PREP")

    load_price, price_stats = prepare_database_first_prices(
        universe,
        store,
        period=period,
        min_rows=config.minimum_price_bars,
        status=price_status,
    )
    st.session_state.last_price_stats = price_stats

    foreign_candidates = pd.DataFrame()
    foreign_flow = pd.DataFrame()
    direct_idx_stats = {"days": 0, "tickers": 0, "freshest": None, "source": "DISABLED"}
    zapi_stats = {"days": 0, "tickers": 0, "freshest": None, "source": "DISABLED"}
    foreign_selection_stats = {
        "idx_direct_selected_tickers": 0,
        "zapi_selected_tickers": 0,
        "other_selected_tickers": 0,
        "foreign_unavailable_tickers": len(universe),
        "median_selected_coverage_pct": 0.0,
    }

    if use_foreign:
        status_box.caption("Loading share-unit foreign flow evidence...")
        try:
            db_flow = load_cached_idx_official_flows(store, universe, lookback_calendar_days=120) if store is not None else pd.DataFrame()
            db_vendor_flow = load_zapi_vendor_foreign_flows(store, universe, lookback_calendar_days=120) if store is not None else pd.DataFrame()
            bundled_direct = load_bundled_idx_official_flows(universe, lookback_calendar_days=120)
            bundled_zapi = load_bundled_zapi_foreign_flows(universe, lookback_calendar_days=120)
            foreign_candidates = merge_official_flow_frames(db_flow, db_vendor_flow, bundled_direct, bundled_zapi)

            if store is not None:
                if bundled_direct is not None and not bundled_direct.empty:
                    try:
                        upsert_idx_official_flows(store, bundled_direct)
                    except Exception as exc:
                        st.caption(f"Direct IDX cache could not be persisted: {exc}")
                if bundled_zapi is not None and not bundled_zapi.empty:
                    try:
                        upsert_zapi_vendor_foreign_flows(store, bundled_zapi)
                    except Exception as exc:
                        st.caption(f"Zapi vendor cache could not be persisted: {exc}")

            latest_price_dates = []
            for ticker in universe[:20]:
                frame = load_price(ticker)
                if not frame.empty:
                    latest_price_dates.append(pd.to_datetime(frame["date"], errors="coerce").max())
            end_date = max([d for d in latest_price_dates if pd.notna(d)], default=pd.Timestamp.today())

            # Direct IDX refresh is only attempted if no cached source already
            # covers the current price date. This avoids repeated Cloudflare cost.
            freshest_any = pd.to_datetime(foreign_candidates["trade_date"], errors="coerce").max() if not foreign_candidates.empty else pd.NaT
            cached_days = int(foreign_candidates["trade_date"].nunique()) if not foreign_candidates.empty else 0
            need_direct_refresh = cached_days < 18 or pd.isna(freshest_any) or freshest_any.normalize() < pd.Timestamp(end_date).normalize()
            if need_direct_refresh:
                status_box.caption(f"Trying direct IDX foreign refresh • cached evidence {cached_days} trading days")
                fresh_direct = fetch_idx_official_flow_history(
                    universe,
                    end_date=pd.Timestamp(end_date).date(),
                    target_trading_days=20,
                    max_calendar_days=40,
                )
                if not fresh_direct.empty:
                    if store is not None:
                        upsert_idx_official_flows(store, fresh_direct)
                    foreign_candidates = merge_official_flow_frames(foreign_candidates, fresh_direct)

            direct_rows = foreign_candidates[
                foreign_candidates["source"].eq("IDX_OFFICIAL_STOCK_SUMMARY")
            ].copy() if not foreign_candidates.empty and "source" in foreign_candidates.columns else pd.DataFrame()
            zapi_rows = foreign_candidates[
                foreign_candidates["source"].isin(ZAPI_VENDOR_SOURCES)
            ].copy() if not foreign_candidates.empty and "source" in foreign_candidates.columns else pd.DataFrame()
            direct_idx_stats = {**data_stats(direct_rows), "source": "IDX_OFFICIAL_STOCK_SUMMARY"}
            zapi_stats = {**data_stats(zapi_rows), "source": "ZAPI_IDX_FOREIGN_FLOW"}
            foreign_flow, foreign_selection_stats = prepare_foreign_evidence(
                universe,
                foreign_candidates,
                load_price,
                lookback=20,
            )
        except Exception as exc:
            st.warning(f"Foreign-flow evidence unavailable; continuing neutral/guarded: {exc}")
            foreign_candidates = pd.DataFrame()
            foreign_flow = pd.DataFrame()

    st.session_state.last_direct_idx_stats = direct_idx_stats
    st.session_state.last_zapi_stats = zapi_stats
    st.session_state.last_foreign_selection_stats = foreign_selection_stats

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
        official_flow_frame=foreign_flow,
    )
    st.session_state.last_results = results
    st.session_state.last_errors = errors
    st.session_state.last_run_id = run_id

    valid_ratio = len(results) / max(len(universe), 1)
    final_status = "COMPLETED" if valid_ratio >= MANAGED_MIN_VALID_RATIO else "FAILED"
    outcome_stats = {"checked": 0, "updated": 0, "complete": 0, "seeded": 0, "mode": "SKIPPED", "status": "SKIPPED"}

    if persist and store is not None and run_record_created:
        try:
            store.save_results(run_id, results)
            try:
                refreshed = refresh_pending_outcomes(store, universe, load_price)
                seeded = seed_signal_outcomes(store, run_id, results, load_price)
                outcome_stats = {**refreshed, "seeded": int(seeded), "status": "OK"}
            except Exception as exc:
                outcome_stats = {"checked": 0, "updated": 0, "complete": 0, "seeded": 0, "mode": "UNAVAILABLE", "status": f"UNAVAILABLE: {exc}"}
            st.session_state.last_outcome_stats = outcome_stats

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
                selected_days = int(foreign_flow["trade_date"].nunique()) if not foreign_flow.empty else 0
                selected_tickers = int(foreign_flow["ticker"].nunique()) if not foreign_flow.empty else 0
                direct_selected = foreign_flow[foreign_flow["source"].eq("IDX_OFFICIAL_STOCK_SUMMARY")].copy() if not foreign_flow.empty and "source" in foreign_flow.columns else pd.DataFrame()
                direct_days = int(direct_selected["trade_date"].nunique()) if not direct_selected.empty else 0
                direct_tickers = int(direct_selected["ticker"].nunique()) if not direct_selected.empty else 0
                source_col = "foreign_evidence_source" if not foreign_flow.empty and "foreign_evidence_source" in foreign_flow.columns else "source"
                source_counts = foreign_flow.groupby(source_col, observed=True)["ticker"].nunique().astype(int).to_dict() if not foreign_flow.empty and source_col in foreign_flow.columns else {}
                store.client.table("flow_scan_runs").update({
                    "official_flow_days": direct_days,
                    "official_flow_tickers": direct_tickers,
                    "foreign_evidence_days": selected_days,
                    "foreign_evidence_tickers": selected_tickers,
                    "foreign_evidence_sources": source_counts,
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
broker_stats = st.session_state.last_broker_stats
direct_idx_stats = st.session_state.last_direct_idx_stats
zapi_stats = st.session_state.last_zapi_stats
foreign_selection_stats = st.session_state.last_foreign_selection_stats
outcome_stats = st.session_state.last_outcome_stats

if isinstance(price_stats, dict):
    st.subheader("Data Integrity")
    p1, p2, p3, p4, p5 = st.columns(5)
    p1.metric("DB OHLCV hits", int(price_stats.get("cache_hits", 0)))
    p2.metric("OHLCV fetched", int(price_stats.get("fetched_valid", 0)))
    p3.metric("OHLCV unavailable", int(price_stats.get("unavailable", 0)))
    p4.metric("Broker days", int((broker_stats or {}).get("days", 0)))
    p5.metric("Broker verified tickers", int((broker_stats or {}).get("verified_tickers", 0)))
    q1, q2, q3, q4, q5 = st.columns(5)
    q1.metric("Direct IDX days", int((direct_idx_stats or {}).get("days", 0)))
    q2.metric("Direct IDX tickers", int((direct_idx_stats or {}).get("tickers", 0)))
    q3.metric("Zapi IDX days", int((zapi_stats or {}).get("days", 0)))
    q4.metric("Zapi IDX tickers", int((zapi_stats or {}).get("tickers", 0)))
    q5.metric("OOS seeded", int((outcome_stats or {}).get("seeded", 0)))
    if foreign_selection_stats:
        st.caption(
            "Foreign selector: "
            f"direct IDX {int(foreign_selection_stats.get('idx_direct_selected_tickers', 0))} ticker • "
            f"Zapi {int(foreign_selection_stats.get('zapi_selected_tickers', 0))} • "
            f"unavailable {int(foreign_selection_stats.get('foreign_unavailable_tickers', 0))} • "
            f"median coverage {float(foreign_selection_stats.get('median_selected_coverage_pct', 0.0)):.0f}%"
        )
    if broker_stats:
        st.caption(
            f"Broker cache: {int(broker_stats.get('rows', 0))} rows • "
            f"{int(broker_stats.get('tickers', 0))} tickers • freshest {broker_stats.get('freshest') or 'N/A'}"
        )
    if outcome_stats:
        st.caption(
            f"OOS refresh mode: {outcome_stats.get('mode', 'N/A')} • "
            f"updated: {int(outcome_stats.get('updated', 0) or 0)}"
        )
    if outcome_stats and outcome_stats.get("status") not in {None, "OK", "SKIPPED"}:
        st.caption(f"OOS memory: {outcome_stats.get('status')}")

if isinstance(results, pd.DataFrame) and not results.empty:
    display = results.copy()
    if "diagnostics" in display.columns:
        for name in (
            "broker_verified_source_pct", "persistence_20d", "broker_cohort_stability", "cost_position",
            "foreign_evidence_coverage_pct", "foreign_evidence_source", "official_foreign_coverage_pct", "market_regime_label", "relative_strength_20d_pct",
        ):
            display[name] = display["diagnostics"].map(
                lambda value, key=name: (value or {}).get(key) if isinstance(value, dict) else None
            )

    direct_mask = display["evidence_tier"].eq("BROKER_DIRECT")
    display["bandar_price_est"] = pd.to_numeric(
        display.get("estimated_smart_money_cost"), errors="coerce"
    ).where(direct_mask)
    display["bandar_vs_price_pct"] = pd.to_numeric(
        display.get("premium_to_cost_pct"), errors="coerce"
    ).where(direct_mask)
    display["bandar_cost_position"] = display.get("cost_position", pd.Series(index=display.index, dtype=object)).where(
        direct_mask, "UNVERIFIED"
    )

    eligible = display[
        (display["real_money_state"] == "ELIGIBLE")
        & (display["evidence_tier"] == "BROKER_DIRECT")
    ].copy()
    broker_direct = display[display["evidence_tier"] == "BROKER_DIRECT"].copy()
    foreign_coverages = [
        float(d.get("foreign_evidence_coverage_pct", d.get("official_foreign_coverage_pct", 0)) or 0)
        for d in results.get("diagnostics", pd.Series(dtype=object))
        if isinstance(d, dict)
    ]

    st.subheader("Decision Integrity")
    c1, c2, c3, c4, c5, c6 = st.columns(6)
    c1.metric("Scanned valid", len(display))
    c2.metric("Production eligible", len(eligible))
    c3.metric("Broker-direct", len(broker_direct))
    c4.metric("Median broker evidence", f"{display['evidence_coverage_pct'].median():.0f}%")
    c5.metric("Median foreign evidence", f"{pd.Series(foreign_coverages).median():.0f}%" if foreign_coverages else "0%")
    c6.metric("Median price quality", f"{display['price_data_quality_score'].median():.0f}%" if "price_data_quality_score" in display else "N/A")

    cols = [
        "ticker", "final_score", "phase", "action", "real_money_state",
        "bandar_price_est", "bandar_vs_price_pct", "bandar_cost_position",
        "evidence_tier", "evidence_coverage_pct", "broker_verified_source_pct",
        "accumulation_score", "operator_dominance_score", "persistence_20d",
        "broker_cohort_stability", "foreign_institutional_score",
        "foreign_evidence_source", "foreign_evidence_coverage_pct", "official_foreign_coverage_pct", "market_context_score", "market_regime_label",
        "relative_strength_20d_pct", "price_data_quality_score", "distribution_risk",
        "entry_low", "entry_high", "invalidation", "tp1", "tp2",
    ]
    available_cols = [c for c in cols if c in display.columns]
    column_config = {
        "bandar_price_est": st.column_config.NumberColumn(
            "Harga Bandar Est.",
            help="Estimasi inventory cost cohort broker akumulator. Hanya ditampilkan untuk BROKER_DIRECT terverifikasi.",
            format="Rp %.0f",
        ),
        "bandar_vs_price_pct": st.column_config.NumberColumn(
            "Harga vs Bandar",
            help="Premium/diskon harga terakhir terhadap Harga Bandar Est. Nilai positif = harga di atas cost bandar.",
            format="%.1f%%",
        ),
        "bandar_cost_position": st.column_config.TextColumn(
            "Posisi vs Cost Bandar",
            help="UNDER_COST / NEAR_COST / HEALTHY_MARKUP / MARKUP / EXTENDED / OVEREXTENDED. UNVERIFIED jika bukan BROKER_DIRECT.",
        ),
    }

    st.subheader("1. Raw Research Priority")
    st.caption("Seluruh kandidat termasuk PRICE_PROXY. Harga bandar hanya terisi pada row BROKER_DIRECT.")
    st.dataframe(display[available_cols], width="stretch", hide_index=True, column_config=column_config)

    st.subheader("2. Guarded Accumulation Watch")
    guarded_acc = display[
        display["phase"].isin(["ACCUMULATION", "EARLY_MARKUP"])
        & (display["real_money_state"] != "ELIGIBLE")
    ].sort_values(["final_score", "accumulation_score"], ascending=False)
    if guarded_acc.empty:
        st.info("Tidak ada kandidat guarded accumulation pada run ini.")
    else:
        st.dataframe(guarded_acc[available_cols].head(20), width="stretch", hide_index=True, column_config=column_config)

    st.subheader("3. Broker-Verified Production")
    st.caption("Hanya BROKER_DIRECT + ELIGIBLE. Lane ini menampilkan Harga Bandar Est. yang sudah lolos evidence/provenance gate.")
    production = eligible.sort_values(["final_score", "accumulation_score"], ascending=False)
    if production.empty:
        st.info("Belum ada kandidat production-eligible. Harga bandar tidak akan dipaksakan dari OHLCV/foreign-flow proxy.")
    else:
        st.dataframe(production[available_cols].head(20), width="stretch", hide_index=True, column_config=column_config)

    st.subheader("Distribution Warning")
    dist = display.sort_values("distribution_risk", ascending=False)
    dist_cols = [c for c in [
        "ticker", "distribution_risk", "phase", "action", "final_score", "evidence_tier",
        "bandar_price_est", "bandar_vs_price_pct", "bandar_cost_position",
        "broker_verified_source_pct", "price_data_quality_score", "guardrail_reason"
    ] if c in dist.columns]
    st.dataframe(dist[dist_cols].head(20), width="stretch", hide_index=True, column_config=column_config)

    st.subheader("Single Ticker Audit")
    selected = st.selectbox("Ticker", display["ticker"].tolist())
    row = display[display["ticker"] == selected].iloc[0].to_dict()
    bandar_price = row.get("bandar_price_est")
    bandar_delta = row.get("bandar_vs_price_pct")
    is_direct = row.get("evidence_tier") == "BROKER_DIRECT"
    a, b, c, d, e = st.columns(5)
    a.metric("Final Score", row["final_score"])
    b.metric("Phase", row["phase"])
    c.metric("State", row["real_money_state"])
    d.metric(
        "Harga Bandar Est.",
        f"Rp {float(bandar_price):,.0f}" if is_direct and pd.notna(bandar_price) else "UNVERIFIED",
    )
    e.metric(
        "Harga vs Bandar",
        f"{float(bandar_delta):+.1f}%" if is_direct and pd.notna(bandar_delta) else "N/A",
    )
    if not is_direct:
        st.caption("Harga bandar sengaja tidak ditampilkan: evidence belum BROKER_DIRECT terverifikasi.")
    st.write(row.get("guardrail_reason"))
    st.json(row.get("diagnostics", {}), expanded=False)

    st.download_button(
        "Download scan CSV",
        data=display.drop(columns=["diagnostics", "components"], errors="ignore").to_csv(index=False).encode(),
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
