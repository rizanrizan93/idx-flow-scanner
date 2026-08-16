from __future__ import annotations

import os
import uuid
from pathlib import Path

import pandas as pd
import streamlit as st

from .broker_evidence import select_broker_evidence
from .config import ScannerConfig
from .database_first import prepare_database_first_prices
from .foreign_evidence import prepare_foreign_evidence
from .funnel import merge_verified_finalists, select_guarded_top5, verify_guarded_top5
from .managed import (
    ManagedDecision,
    decide_managed_run,
    load_bundled_universe,
    load_persisted_results,
    mark_stale_managed_runs,
    recent_runs,
    universe_signature,
)
from .outcomes import refresh_pending_outcomes, seed_signal_outcomes
from .pipeline import scan_universe
from .providers.idx_official import load_bundled_idx_official_flows, load_cached_idx_official_flows
from .providers.indexalpha import (
    INDEX_ALPHA_SOURCE,
    IndexAlphaQuotaExhausted,
    IndexAlphaUnavailable,
    fetch_indexalpha_broker_summary,
    load_bundled_indexalpha_broker_flows,
    merge_indexalpha_broker_frames,
)
from .providers.zapi import load_bundled_zapi_foreign_flows
from .storage import SupabaseStore
from .vendor_foreign_store import load_zapi_vendor_foreign_flows, upsert_zapi_vendor_foreign_flows

APP_VERSION = "0.3.0"
ROOT = Path(__file__).resolve().parents[2]
DEFAULT_UNIVERSE_PATH = ROOT / "data" / "universe" / "idx_400_syariah.csv"
MANAGED_MIN_VALID_RATIO = 0.90
FINALIST_COUNT = 5


def _secret(name: str) -> str | None:
    try:
        value = st.secrets.get(name, os.getenv(name))
    except Exception:
        value = os.getenv(name)
    value = str(value or "").strip()
    return value or None


def connect_store(enabled: bool) -> tuple[SupabaseStore | None, str | None]:
    if not enabled:
        return None, None
    try:
        url = _secret("SUPABASE_URL")
        key = _secret("SUPABASE_SECRET_KEY")
        if not url or not key:
            return None, "SUPABASE_URL / SUPABASE_SECRET_KEY belum tersedia"
        return SupabaseStore(url, key), None
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


def _diag(value: object) -> dict[str, object]:
    return value if isinstance(value, dict) else {}


def recover_funnel_views(results: pd.DataFrame) -> tuple[pd.DataFrame, pd.DataFrame]:
    if results is None or results.empty or "diagnostics" not in results.columns:
        return pd.DataFrame(), pd.DataFrame()
    rows = results.copy()
    rows["guarded_rank"] = rows["diagnostics"].map(lambda d: _diag(d).get("guarded_rank"))
    rows["guarded_score"] = rows["diagnostics"].map(lambda d: _diag(d).get("guarded_score"))
    rows["broker_verification_status"] = rows["diagnostics"].map(lambda d: _diag(d).get("broker_verification_status"))
    guarded = rows[rows["guarded_rank"].notna()].sort_values("guarded_rank", kind="stable").head(FINALIST_COUNT).copy()
    broker = guarded[guarded["broker_verification_status"].notna()].copy()
    if not broker.empty:
        order = {"BROKER_VERIFIED": 0, "BROKER_GUARDED": 1, "BROKER_PENDING": 2, "BROKER_REJECT": 3}
        broker["_order"] = broker["broker_verification_status"].map(order).fillna(9)
        broker = broker.sort_values(["_order", "final_score", "guarded_rank"], ascending=[True, False, True], kind="stable").drop(columns="_order")
        broker["broker_rank"] = range(1, len(broker) + 1)
    return guarded, broker


def _decorate(frame: pd.DataFrame) -> pd.DataFrame:
    if frame is None or frame.empty:
        return pd.DataFrame()
    display = frame.copy()
    if "diagnostics" in display.columns:
        for name in (
            "broker_verified_source_pct",
            "broker_days",
            "persistence_20d",
            "broker_cohort_stability",
            "cost_position",
            "foreign_evidence_coverage_pct",
            "foreign_evidence_source",
            "official_foreign_coverage_pct",
            "market_regime_label",
            "relative_strength_20d_pct",
            "guarded_rank",
            "guarded_score",
            "broker_verification_status",
        ):
            if name not in display.columns:
                display[name] = display["diagnostics"].map(lambda value, key=name: _diag(value).get(key))
    direct = display.get("evidence_tier", pd.Series(index=display.index, dtype=object)).eq("BROKER_DIRECT")
    display["bandar_price_est"] = pd.to_numeric(display.get("estimated_smart_money_cost"), errors="coerce").where(direct)
    display["bandar_vs_price_pct"] = pd.to_numeric(display.get("premium_to_cost_pct"), errors="coerce").where(direct)
    display["bandar_cost_position"] = display.get("cost_position", pd.Series(index=display.index, dtype=object)).where(direct, "UNVERIFIED")
    return display


def _zapi_first_foreign(
    universe: list[str],
    store: SupabaseStore | None,
    load_price,
) -> tuple[pd.DataFrame, dict[str, object], dict[str, object], dict[str, object]]:
    """Use ZAPI whenever available; direct IDX cached data is fallback only."""
    db_zapi = load_zapi_vendor_foreign_flows(store, universe, lookback_calendar_days=120) if store is not None else pd.DataFrame()
    bundled_zapi = load_bundled_zapi_foreign_flows(universe, lookback_calendar_days=120)
    zapi_candidates = pd.concat([f for f in (db_zapi, bundled_zapi) if f is not None and not f.empty], ignore_index=True) if any(f is not None and not f.empty for f in (db_zapi, bundled_zapi)) else pd.DataFrame()
    if not zapi_candidates.empty:
        zapi_candidates = zapi_candidates.drop_duplicates(["ticker", "trade_date", "source"], keep="last")
    if store is not None and bundled_zapi is not None and not bundled_zapi.empty:
        try:
            upsert_zapi_vendor_foreign_flows(store, bundled_zapi)
        except Exception:
            pass

    zapi_flow, zapi_selection = prepare_foreign_evidence(universe, zapi_candidates, load_price, lookback=20)
    selected_zapi = set(zapi_flow["ticker"].unique()) if not zapi_flow.empty else set()
    missing = [t for t in universe if t not in selected_zapi]

    direct_flow = pd.DataFrame()
    direct_selection = {"idx_direct_selected_tickers": 0, "foreign_unavailable_tickers": len(missing), "median_selected_coverage_pct": 0.0}
    direct_candidates = pd.DataFrame()
    if missing:
        db_direct = load_cached_idx_official_flows(store, missing, lookback_calendar_days=120) if store is not None else pd.DataFrame()
        bundled_direct = load_bundled_idx_official_flows(missing, lookback_calendar_days=120)
        valid_direct = [f for f in (db_direct, bundled_direct) if f is not None and not f.empty]
        direct_candidates = pd.concat(valid_direct, ignore_index=True) if valid_direct else pd.DataFrame()
        if not direct_candidates.empty:
            direct_candidates = direct_candidates.drop_duplicates(["ticker", "trade_date", "source"], keep="last")
        direct_flow, direct_selection = prepare_foreign_evidence(missing, direct_candidates, load_price, lookback=20)

    selected = [f for f in (zapi_flow, direct_flow) if f is not None and not f.empty]
    foreign_flow = pd.concat(selected, ignore_index=True) if selected else pd.DataFrame()
    zapi_stats = {**data_stats(zapi_candidates), "source": "ZAPI_IDX_FOREIGN_FLOW"}
    direct_stats = {**data_stats(direct_candidates), "source": "IDX_OFFICIAL_STOCK_SUMMARY_FALLBACK"}
    selected_count = int(foreign_flow["ticker"].nunique()) if not foreign_flow.empty else 0
    selection_stats = {
        "zapi_selected_tickers": int(len(selected_zapi)),
        "idx_direct_selected_tickers": int(direct_flow["ticker"].nunique()) if not direct_flow.empty else 0,
        "foreign_unavailable_tickers": max(0, len(universe) - selected_count),
        "median_selected_coverage_pct": float(zapi_selection.get("median_selected_coverage_pct", 0.0) or direct_selection.get("median_selected_coverage_pct", 0.0) or 0.0),
        "policy": "ZAPI_FIRST_IDX_FALLBACK",
    }
    return foreign_flow, zapi_stats, direct_stats, selection_stats


def _load_indexalpha_for_finalists(
    finalists: list[str],
    load_price,
    store: SupabaseStore | None,
    *,
    allow_live_pull: bool,
) -> tuple[pd.DataFrame, dict[str, object]]:
    if not finalists:
        return pd.DataFrame(), {"status": "NO_FINALISTS", "requests_attempted": 0, "latest_day_cache_hits": 0}
    db = pd.DataFrame()
    if store is not None:
        try:
            db = store.load_broker_flows(finalists, lookback_calendar_days=180)
            if not db.empty and "source" in db.columns:
                db = db[db["source"].eq(INDEX_ALPHA_SOURCE)].copy()
        except Exception:
            db = pd.DataFrame()
    bundled = load_bundled_indexalpha_broker_flows(finalists, lookback_calendar_days=180)
    existing = merge_indexalpha_broker_frames(db, bundled)

    key = _secret("INDEX_ALPHA_KEY")
    live_parts: list[pd.DataFrame] = []
    attempted = 0
    cache_hits = 0
    status = "CACHE_ONLY"
    present_pairs: set[tuple[str, str]] = set()
    if not existing.empty:
        work = existing[["ticker", "trade_date"]].copy()
        work["trade_date"] = pd.to_datetime(work["trade_date"], errors="coerce").dt.date.astype("string")
        present_pairs = set((str(t), str(d)) for t, d in work.dropna().itertuples(index=False, name=None))

    if allow_live_pull and key:
        status = "LIVE_OK"
        for ticker in finalists[:FINALIST_COUNT]:
            price = load_price(ticker)
            if price is None or price.empty:
                continue
            day_value = pd.to_datetime(price["date"], errors="coerce").max()
            if pd.isna(day_value):
                continue
            day = pd.Timestamp(day_value).date().isoformat()
            if (ticker, day) in present_pairs:
                cache_hits += 1
                continue
            try:
                attempted += 1
                fresh = fetch_indexalpha_broker_summary(ticker, day, api_key=key, investor="all", market="RG")
                if not fresh.empty:
                    live_parts.append(fresh)
                    present_pairs.add((ticker, day))
            except IndexAlphaQuotaExhausted as exc:
                status = f"QUOTA_EXHAUSTED: {exc}"
                break
            except IndexAlphaUnavailable as exc:
                status = f"UNAVAILABLE: {exc}"
                break
            except Exception as exc:
                status = f"ERROR: {type(exc).__name__}: {exc}"
                break
    elif allow_live_pull and not key:
        status = "NO_STREAMLIT_INDEX_ALPHA_KEY"
    elif not allow_live_pull:
        status = "CACHE_ONLY_MANAGED_AUTO"

    fresh_frame = pd.concat(live_parts, ignore_index=True) if live_parts else pd.DataFrame()
    if store is not None and not fresh_frame.empty:
        try:
            store.upsert_broker_flows(fresh_frame)
        except Exception:
            pass
    merged = merge_indexalpha_broker_frames(existing, fresh_frame)
    selected, selector_stats = select_broker_evidence(merged)
    stats = {
        "status": status,
        "requests_attempted": attempted,
        "latest_day_cache_hits": cache_hits,
        "fresh_rows": int(len(fresh_frame)),
        "finalist_count": len(finalists),
        "provider_selection": selector_stats,
        **data_stats(selected),
    }
    return selected, stats


def run() -> None:
    st.set_page_config(page_title="IDX Flow Scanner", page_icon="📡", layout="wide")
    st.title("IDX Flow Scanner")
    st.caption(
        f"v{APP_VERSION} • 400 ticker → PRICE_PROXY → ZAPI foreign flow → Final Guarded Top 5 → "
        "Index Alpha broker → Broker-Verified Top 5"
    )
    st.info(
        "Broker evidence tidak ikut menentukan Final Guarded Top 5. Index Alpha baru dibaca/ditarik setelah cohort Top 5 terbentuk. "
        "BROKER_DIRECT tetap membutuhkan ≥10 broker-days, coverage/provenance quorum, broker balance, dan price-quality gate."
    )

    with st.sidebar:
        st.header("Managed Scan")
        managed_auto = st.toggle("Managed auto-run", value=True)
        period = st.selectbox("OHLCV lookback", ["6mo", "1y", "2y"], index=1)
        use_database = st.checkbox("Database-first Supabase", value=True)
        use_foreign = st.checkbox("ZAPI foreign evidence", value=True)
        pull_indexalpha = st.checkbox(
            "Index Alpha live pull untuk Final Top 5",
            value=True,
            help="Maksimum 1 exact-day request per finalist dan hanya pada manual Run/Re-run. Cached exact-day rows tidak diminta ulang.",
        )
        persist = st.checkbox("Persist hasil scan", value=True)
        run_manual = st.button("Run / Re-run sekarang", type="primary", width="stretch")

    for key, value in {
        "last_results": None,
        "last_proxy_results": None,
        "last_guarded_top5": None,
        "last_broker_top5": None,
        "last_errors": [],
        "last_run_id": None,
        "last_price_stats": None,
        "last_broker_stats": None,
        "last_zapi_stats": None,
        "last_direct_idx_stats": None,
        "last_foreign_selection_stats": None,
        "last_outcome_stats": None,
    }.items():
        st.session_state.setdefault(key, value)

    universe = load_bundled_universe(DEFAULT_UNIVERSE_PATH)
    if not universe:
        st.error("Bundled 400-ticker universe tidak tersedia.")
        st.stop()
    signature = universe_signature(universe)
    store, store_error = connect_store(use_database)
    if store_error:
        st.warning(f"Supabase belum siap: {store_error}")

    managed_decision = ManagedDecision(False, "managed mode disabled")
    if managed_auto and persist and store is not None:
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
    m2.metric("Pipeline", "PROXY → ZAPI → TOP5 → BROKER")
    m3.metric("DB", "CONNECTED" if store is not None else "UNAVAILABLE")

    if st.session_state.last_results is None and store is not None and managed_decision.blocking_run_id and "valid" in managed_decision.reason:
        try:
            persisted = load_persisted_results(store, managed_decision.blocking_run_id)
            if not persisted.empty:
                st.session_state.last_results = persisted
                st.session_state.last_proxy_results = persisted.copy()
                guarded, broker_view = recover_funnel_views(persisted)
                st.session_state.last_guarded_top5 = guarded
                st.session_state.last_broker_top5 = broker_view
                st.session_state.last_run_id = managed_decision.blocking_run_id
        except Exception:
            pass

    trigger_scan = bool(run_manual or managed_decision.should_run)
    if managed_auto:
        st.caption(f"Managed engine: {managed_decision.reason}")

    if trigger_scan:
        config = ScannerConfig()
        run_id = str(uuid.uuid4())
        run_record_created = False
        bar = st.progress(0.0, text="Preparing OHLCV...")
        status_box = st.empty()
        run_mode = "manual" if run_manual else "managed"

        if persist and store is not None:
            try:
                store.create_run(
                    run_id,
                    len(universe),
                    {
                        "period": period,
                        "version": APP_VERSION,
                        "mode": run_mode,
                        "universe_signature": signature,
                        "pipeline": "400_PROXY__ZAPI__GUARDED_TOP5__INDEX_ALPHA__BROKER_VERIFIED_TOP5",
                        "broker_scope": "FINAL_GUARDED_TOP5_ONLY",
                        "broker_provider": INDEX_ALPHA_SOURCE,
                        "broker_min_days": config.minimum_broker_days,
                        "indexalpha_live_pull_manual_only": True,
                        "zapi_primary_foreign": bool(use_foreign),
                        "market_context": "CROSS_SECTIONAL_400_PRESERVED_IN_BROKER_PASS",
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

        foreign_flow = pd.DataFrame()
        zapi_stats = {"rows": 0, "tickers": 0, "days": 0, "freshest": None, "source": "DISABLED"}
        direct_idx_stats = {"rows": 0, "tickers": 0, "days": 0, "freshest": None, "source": "DISABLED"}
        foreign_selection_stats = {"zapi_selected_tickers": 0, "idx_direct_selected_tickers": 0, "foreign_unavailable_tickers": len(universe), "median_selected_coverage_pct": 0.0}
        if use_foreign:
            status_box.caption("Stage 2/5 • ZAPI foreign evidence")
            try:
                foreign_flow, zapi_stats, direct_idx_stats, foreign_selection_stats = _zapi_first_foreign(universe, store, load_price)
            except Exception as exc:
                st.warning(f"ZAPI/foreign evidence unavailable; Final Guarded Top 5 will fail closed: {exc}")
        st.session_state.last_zapi_stats = zapi_stats
        st.session_state.last_direct_idx_stats = direct_idx_stats
        st.session_state.last_foreign_selection_stats = foreign_selection_stats

        def progress(i: int, total: int, ticker: str) -> None:
            bar.progress(i / max(total, 1), text=f"Stage 1-3/5 • {i}/{total} • {ticker}")
            status_box.caption(f"Proxy + ZAPI scoring {ticker} • {i}/{total}")
            if store is not None and run_record_created and (i == 1 or i % 20 == 0 or i == total):
                store.update_run_progress(run_id, i, ticker)

        _, proxy_results, errors = scan_universe(
            universe,
            load_price,
            pd.DataFrame(),
            config,
            progress,
            run_id=run_id,
            official_flow_frame=foreign_flow,
        )
        guarded_top5 = select_guarded_top5(proxy_results, config, top_n=FINALIST_COUNT)
        st.session_state.last_proxy_results = proxy_results
        st.session_state.last_guarded_top5 = guarded_top5

        finalists = guarded_top5["ticker"].astype(str).tolist() if not guarded_top5.empty else []
        status_box.caption(f"Stage 4/5 • Index Alpha broker • finalists: {', '.join(finalists) if finalists else 'none'}")
        broker_frame, broker_stats = _load_indexalpha_for_finalists(
            finalists,
            load_price,
            store,
            allow_live_pull=bool(run_manual and pull_indexalpha),
        )
        st.session_state.last_broker_stats = broker_stats

        broker_top5, broker_errors = verify_guarded_top5(
            guarded_top5,
            load_price,
            broker_frame,
            config=config,
            official_flow_frame=foreign_flow,
        )
        st.session_state.last_broker_top5 = broker_top5
        results = merge_verified_finalists(proxy_results, broker_top5)
        all_errors = list(errors) + list(broker_errors)
        st.session_state.last_results = results
        st.session_state.last_errors = all_errors
        st.session_state.last_run_id = run_id

        valid_ratio = len(proxy_results) / max(len(universe), 1)
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
                store.finish_run(
                    run_id,
                    len(proxy_results),
                    len(errors),
                    status=final_status,
                    attempted_count=len(universe),
                    telemetry={
                        "price_cache_hits": int(price_stats.get("cache_hits", 0)),
                        "price_fetched": int(price_stats.get("fetched_valid", 0)),
                        "price_failures": int(price_stats.get("unavailable", 0)),
                    },
                )
                if final_status == "COMPLETED":
                    st.success(f"Persisted • {len(proxy_results)}/{len(universe)} valid • Final Guarded Top {len(guarded_top5)}")
                else:
                    st.error(f"Run FAILED integrity gate • valid {len(proxy_results)}/{len(universe)} ({valid_ratio:.1%})")
            except Exception as exc:
                st.warning(f"Scan selesai, persistence gagal: {exc}")
        st.session_state.last_outcome_stats = outcome_stats
        bar.progress(1.0, text="Stage 5/5 • Broker verification complete")
        status_box.caption("Pipeline complete")

    results = st.session_state.last_results
    proxy_results = st.session_state.last_proxy_results
    guarded_top5 = st.session_state.last_guarded_top5
    broker_top5 = st.session_state.last_broker_top5
    errors = st.session_state.last_errors
    price_stats = st.session_state.last_price_stats or {}
    broker_stats = st.session_state.last_broker_stats or {}
    zapi_stats = st.session_state.last_zapi_stats or {}
    foreign_stats = st.session_state.last_foreign_selection_stats or {}

    if isinstance(results, pd.DataFrame) and not results.empty:
        proxy_display = _decorate(proxy_results if isinstance(proxy_results, pd.DataFrame) and not proxy_results.empty else results)
        final_display = _decorate(results)
        guarded_display = _decorate(guarded_top5) if isinstance(guarded_top5, pd.DataFrame) else pd.DataFrame()
        broker_display = _decorate(broker_top5) if isinstance(broker_top5, pd.DataFrame) else pd.DataFrame()

        verified_count = int(broker_display.get("broker_verification_status", pd.Series(dtype=object)).eq("BROKER_VERIFIED").sum()) if not broker_display.empty else 0
        pending_count = int(broker_display.get("broker_verification_status", pd.Series(dtype=object)).eq("BROKER_PENDING").sum()) if not broker_display.empty else 0
        reject_count = int(broker_display.get("broker_verification_status", pd.Series(dtype=object)).eq("BROKER_REJECT").sum()) if not broker_display.empty else 0

        st.subheader("Decision Funnel")
        f1, f2, f3, f4, f5, f6 = st.columns(6)
        f1.metric("Valid proxy", len(proxy_display))
        f2.metric("ZAPI tickers", int(foreign_stats.get("zapi_selected_tickers", 0)))
        f3.metric("Final guarded", len(guarded_display))
        f4.metric("Broker verified", verified_count)
        f5.metric("Broker pending", pending_count)
        f6.metric("Broker reject", reject_count)
        st.caption(
            f"Index Alpha: {broker_stats.get('status', 'N/A')} • requests {int(broker_stats.get('requests_attempted', 0) or 0)} • "
            f"latest-day cache hits {int(broker_stats.get('latest_day_cache_hits', 0) or 0)} • broker days {int(broker_stats.get('days', 0) or 0)}"
        )
        if broker_stats.get("status") == "NO_STREAMLIT_INDEX_ALPHA_KEY":
            st.warning("INDEX_ALPHA_KEY belum tersedia di environment Streamlit. Scanner memakai cache/DB Index Alpha dan tidak menghabiskan quota live.")

        base_cols = [
            "ticker", "final_score", "phase", "action", "real_money_state",
            "accumulation_score", "foreign_institutional_score", "foreign_evidence_coverage_pct",
            "smc_execution_score", "price_data_quality_score", "distribution_risk",
            "entry_low", "entry_high", "invalidation", "tp1", "tp2",
        ]
        broker_cols = [
            "broker_rank", "guarded_rank", "ticker", "broker_verification_status", "guarded_score", "final_score",
            "phase", "action", "real_money_state", "evidence_tier", "evidence_coverage_pct", "broker_days",
            "broker_verified_source_pct", "accumulation_score", "operator_dominance_score", "persistence_20d",
            "broker_cohort_stability", "distribution_risk", "bandar_price_est", "bandar_vs_price_pct", "bandar_cost_position",
            "entry_low", "entry_high", "invalidation", "tp1", "tp2",
        ]
        column_config = {
            "bandar_price_est": st.column_config.NumberColumn("Harga Bandar Est.", format="Rp %.0f"),
            "bandar_vs_price_pct": st.column_config.NumberColumn("Harga vs Bandar", format="%.1f%%"),
        }

        st.subheader("1. Proxy + ZAPI Research — 400 Ticker")
        st.caption("Broker tidak dipakai pada ranking tahap ini.")
        st.dataframe(proxy_display[[c for c in base_cols if c in proxy_display.columns]], width="stretch", hide_index=True)

        st.subheader("2. Final Guarded Top 5")
        st.caption("Cohort ini dipilih sebelum Index Alpha. Foreign coverage minimum 70%, score ≥65, distribution <70, dan price-quality/staleness gate harus lolos.")
        if guarded_display.empty:
            st.warning("Tidak ada kandidat yang lolos Final Guarded gate. Index Alpha tidak dipanggil.")
        else:
            guarded_cols = ["guarded_rank", "ticker", "guarded_score", "phase", "accumulation_score", "foreign_institutional_score", "foreign_evidence_coverage_pct", "smc_execution_score", "price_data_quality_score", "distribution_risk", "entry_low", "entry_high", "invalidation", "tp1", "tp2"]
            st.dataframe(guarded_display[[c for c in guarded_cols if c in guarded_display.columns]], width="stretch", hide_index=True)

        st.subheader("3. Broker-Verified Top 5")
        st.caption("BROKER_VERIFIED = direct broker evidence + minimum quality gates. BROKER_PENDING berarti history/quorum Index Alpha belum cukup; BROKER_REJECT berarti distribusi/avoid setelah broker pass.")
        if broker_display.empty:
            st.info("Belum ada broker verification output.")
        else:
            st.dataframe(broker_display[[c for c in broker_cols if c in broker_display.columns]], width="stretch", hide_index=True, column_config=column_config)

        st.subheader("Single Ticker Audit")
        selected = st.selectbox("Ticker", final_display["ticker"].tolist())
        row = final_display[final_display["ticker"] == selected].iloc[0].to_dict()
        direct = row.get("evidence_tier") == "BROKER_DIRECT"
        a, b, c, d, e = st.columns(5)
        a.metric("Final Score", row.get("final_score"))
        b.metric("Phase", row.get("phase"))
        c.metric("State", row.get("real_money_state"))
        d.metric("Harga Bandar Est.", f"Rp {float(row['bandar_price_est']):,.0f}" if direct and pd.notna(row.get("bandar_price_est")) else "UNVERIFIED")
        e.metric("Harga vs Bandar", f"{float(row['bandar_vs_price_pct']):+.1f}%" if direct and pd.notna(row.get("bandar_vs_price_pct")) else "N/A")
        st.write(row.get("guardrail_reason"))
        st.json(row.get("diagnostics", {}), expanded=False)

        st.subheader("Data Integrity")
        d1, d2, d3, d4, d5 = st.columns(5)
        d1.metric("DB OHLCV hits", int(price_stats.get("cache_hits", 0) or 0))
        d2.metric("OHLCV fetched", int(price_stats.get("fetched_valid", 0) or 0))
        d3.metric("OHLCV unavailable", int(price_stats.get("unavailable", 0) or 0))
        d4.metric("ZAPI days", int(zapi_stats.get("days", 0) or 0))
        d5.metric("Broker verified tickers", int(broker_stats.get("verified_tickers", 0) or 0))

        st.download_button(
            "Download scan CSV",
            data=final_display.drop(columns=["diagnostics", "components"], errors="ignore").to_csv(index=False).encode(),
            file_name=f"idx_flow_scan_{st.session_state.last_run_id}.csv",
            mime="text/csv",
        )

    if errors:
        err = pd.DataFrame(errors)
        with st.expander(f"Pipeline warnings/errors ({len(err)})", expanded=False):
            st.dataframe(err, width="stretch", hide_index=True)
