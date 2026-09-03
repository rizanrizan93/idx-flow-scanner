from __future__ import annotations

import os
import uuid
from pathlib import Path

import pandas as pd
import streamlit as st

from .authorization import apply_production_authorization, export_scan_csv
from .broker_evidence import select_broker_evidence
from .config import ZapiFlowConfig
from .database_first import prepare_database_first_prices
from .foreign_evidence import prepare_foreign_evidence
from .decision import select_execution_ready, select_zapi_decision_top
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
from .zapi_pipeline import scan_universe_zapi
from .providers.idx_official import load_bundled_idx_official_flows, load_cached_idx_official_flows
from .providers.indexalpha import (
    INDEX_ALPHA_SOURCE,
    IndexAlphaQuotaExhausted,
    IndexAlphaUnavailable,
    fetch_indexalpha_broker_summary,
    load_bundled_indexalpha_broker_flows,
    merge_indexalpha_broker_frames,
)
from .providers.zapi import (
    fetch_zapi_stock_summary_day,
    load_bundled_zapi_foreign_flows,
    load_bundled_zapi_stock_summary,
)
from .storage import DuplicateActiveUniverseRunError, SupabaseStore
from .vendor_foreign_store import load_zapi_vendor_foreign_flows, upsert_zapi_vendor_foreign_flows
from .slow_evidence import load_bundled_zapi_capital_actions, load_bundled_zapi_ownership

APP_VERSION = "0.3.0"
ROOT = Path(__file__).resolve().parents[2]
DEFAULT_UNIVERSE_PATH = ROOT / "data" / "universe" / "idx_400_syariah.csv"
MANAGED_MIN_VALID_RATIO = 0.90
FINALIST_COUNT = 5


def create_durable_run_record(
    store: SupabaseStore,
    run_id: str,
    universe_count: int,
    config: dict[str, object],
) -> bool:
    """Create the tracked lifecycle record, stopping only duplicate executions."""
    try:
        store.create_run(run_id, universe_count, config)
        store.update_run_progress(run_id, 0, "OHLCV_PREP")
        return True
    except DuplicateActiveUniverseRunError:
        st.error(
            "Scan tidak dimulai: run aktif yang sudah ada masih memiliki lock universe ini. "
            "Lanjutkan atau tunggu run tersebut; eksekusi duplikat dihentikan sebelum pipeline OHLCV."
        )
        st.stop()
    except Exception as exc:
        st.warning(f"Could not create RUNNING record in Supabase: {exc}")
        return False


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
    rows = apply_production_authorization(results)
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
    display = apply_production_authorization(frame)
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
            "broker_latest_observation",
            "broker_latest_age_days",
            "broker_freshness_state",
            "broker_data_available",
            "broker_data_valid",
            "foreign_provider_selected",
            "foreign_provider_selection_state",
            "foreign_provider_reconciliation_state",
            "foreign_provider_conflict",
            "foreign_window_state",
            "foreign_window_coverage_ratio",
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
    """Load verified ZAPI foreign flow only; broker/direct-IDX paths are retired."""
    db_zapi = (
        load_zapi_vendor_foreign_flows(store, universe, lookback_calendar_days=120)
        if store is not None else pd.DataFrame()
    )
    bundled_zapi = load_bundled_zapi_foreign_flows(universe, lookback_calendar_days=120)
    valid = [f for f in (db_zapi, bundled_zapi) if f is not None and not f.empty]
    zapi_candidates = pd.concat(valid, ignore_index=True) if valid else pd.DataFrame()
    if store is not None and bundled_zapi is not None and not bundled_zapi.empty:
        try:
            upsert_zapi_vendor_foreign_flows(store, bundled_zapi)
        except Exception:
            pass
    foreign_flow, selection_stats = prepare_foreign_evidence(
        universe, zapi_candidates, load_price, lookback=20
    )
    zapi_stats = {**data_stats(zapi_candidates), "source": "ZAPI_IDX_FOREIGN_FLOW"}
    retired_stats = {
        "rows": 0,
        "tickers": 0,
        "days": 0,
        "verified_tickers": 0,
        "freshest": None,
        "source": "RETIRED_ZAPI_ONLY_MODE",
    }
    return foreign_flow, zapi_stats, retired_stats, selection_stats

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
        f"v{APP_VERSION} • OHLCV + ZAPI flow + sector context + free-float/ownership/corporate-action "
        "→ SMC/ICT → decision"
    )
    st.info(
        "Broker-direct dan Index Alpha telah dikeluarkan dari pipeline produksi. "
        "ZAPI adalah provider flow utama; stock-summary menyediakan listed/tradable shares, "
        "ownership-files menjadi slow-moving ownership evidence, dan capital-action feeds "
        "dipakai sebagai dilution/normalization guard."
    )

    with st.sidebar:
        st.header("Managed Scan")
        managed_auto = st.toggle("Managed auto-run", value=True)
        period = st.selectbox("OHLCV lookback", ["6mo", "1y", "2y"], index=1)
        use_database = st.checkbox("Database-first Supabase", value=True)
        use_zapi = st.checkbox("ZAPI evidence", value=True)
        persist = st.checkbox("Persist hasil scan", value=True)
        run_manual = st.button("Run / Re-run sekarang", type="primary", width="stretch")

    for key, value in {
        "last_results": None,
        "last_decision_top": None,
        "last_execution_ready": None,
        "last_errors": [],
        "last_run_id": None,
        "last_price_stats": None,
        "last_zapi_stats": None,
        "last_slow_stats": None,
        "last_foreign_selection_stats": None,
        "last_outcome_stats": None,
    }.items():
        st.session_state.setdefault(key, value)

    universe_frame = pd.read_csv(DEFAULT_UNIVERSE_PATH)
    universe = load_bundled_universe(DEFAULT_UNIVERSE_PATH)
    if not universe:
        st.error("Bundled 400-ticker universe tidak tersedia.")
        st.stop()
    sector_map = {}
    if {"ticker", "sector"}.issubset(universe_frame.columns):
        sector_map = dict(
            zip(
                universe_frame["ticker"].astype(str).str.upper(),
                universe_frame["sector"].astype(str),
            )
        )

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

    m1, m2, m3, m4 = st.columns(4)
    m1.metric("Universe", len(universe))
    m2.metric("Pipeline", "ZAPI-ONLY")
    m3.metric("Sectors", len(set(sector_map.values())) if sector_map else 0)
    m4.metric("DB", "CONNECTED" if store is not None else "UNAVAILABLE")

    trigger_scan = bool(run_manual or managed_decision.should_run)
    if managed_auto:
        st.caption(f"Managed engine: {managed_decision.reason}")

    if trigger_scan:
        config = ZapiFlowConfig()
        run_id = str(uuid.uuid4())
        run_record_created = False
        bar = st.progress(0.0, text="Preparing OHLCV...")
        status_box = st.empty()
        run_mode = "manual" if run_manual else "managed"

        if persist and store is not None:
            run_record_created = create_durable_run_record(
                store,
                run_id,
                len(universe),
                {
                    "period": period,
                    "version": APP_VERSION,
                    "mode": run_mode,
                    "universe_signature": signature,
                    "pipeline": "OHLCV__ZAPI_FLOW__SECTOR__SLOW_EVIDENCE__SMC_ICT",
                    "broker_direct_enabled": False,
                    "primary_flow_provider": "ZAPI",
                    "zapi_stock_summary": True,
                    "zapi_ownership_files": True,
                    "zapi_capital_actions": True,
                    "market_context": "MARKET_30__SECTOR_30__SECTOR_RS_25__MARKET_RS_15",
                    "calibration_policy": "SHADOW_OOS_NO_AUTO_WEIGHT_MUTATION",
                },
            )

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
        foreign_selection_stats = {
            "zapi_selected_tickers": 0,
            "foreign_unavailable_tickers": len(universe),
            "median_selected_coverage_pct": 0.0,
        }
        if use_zapi:
            status_box.caption("Stage 2/5 • ZAPI foreign-flow evidence")
            try:
                foreign_flow, zapi_stats, _, foreign_selection_stats = _zapi_first_foreign(
                    universe, store, load_price
                )
            except Exception as exc:
                st.warning(f"ZAPI foreign evidence unavailable; scanner remains research-only: {exc}")

        status_box.caption("Stage 3/5 • ZAPI slow evidence")
        stock_snapshot = load_bundled_zapi_stock_summary(universe)
        ownership = load_bundled_zapi_ownership(universe)
        capital_actions = load_bundled_zapi_capital_actions(universe)

        # Manual scans may fill a missing stock-summary snapshot directly from ZAPI.
        if use_zapi and stock_snapshot.empty and run_manual:
            try:
                latest_dates = []
                for ticker in universe[:20]:
                    px = load_price(ticker)
                    if px is not None and not px.empty:
                        latest_dates.append(pd.to_datetime(px["date"], errors="coerce").max())
                target = max([d for d in latest_dates if pd.notna(d)], default=pd.Timestamp.today())
                stock_snapshot = fetch_zapi_stock_summary_day(
                    universe,
                    pd.Timestamp(target).date(),
                    api_key=_secret("ZAPI_KEY"),
                )
            except Exception as exc:
                st.caption(f"ZAPI stock-summary live fallback unavailable: {exc}")

        slow_stats = {
            "stock_snapshot_tickers": int(stock_snapshot["ticker"].nunique()) if not stock_snapshot.empty and "ticker" in stock_snapshot.columns else 0,
            "ownership_tickers": int(ownership["ticker"].nunique()) if not ownership.empty and "ticker" in ownership.columns else 0,
            "capital_action_tickers": int(capital_actions["ticker"].nunique()) if not capital_actions.empty and "ticker" in capital_actions.columns else 0,
        }
        st.session_state.last_zapi_stats = zapi_stats
        st.session_state.last_slow_stats = slow_stats
        st.session_state.last_foreign_selection_stats = foreign_selection_stats

        def progress(i: int, total: int, ticker: str) -> None:
            bar.progress(i / max(total, 1), text=f"Stage 4/5 • {i}/{total} • {ticker}")
            status_box.caption(f"ZAPI + sector + slow evidence + SMC scoring {ticker} • {i}/{total}")
            if store is not None and run_record_created and (i == 1 or i % 20 == 0 or i == total):
                store.update_run_progress(run_id, i, ticker)

        _, results, errors = scan_universe_zapi(
            universe,
            load_price,
            progress=progress,
            run_id=run_id,
            foreign_flow_frame=foreign_flow,
            stock_summary_frame=stock_snapshot,
            ownership_frame=ownership,
            capital_action_frame=capital_actions,
            sector_map=sector_map,
            config=config,
        )
        decision_top = select_zapi_decision_top(results, top_n=20)
        execution_ready = select_execution_ready(results, top_n=10)
        st.session_state.last_results = results
        st.session_state.last_decision_top = decision_top
        st.session_state.last_execution_ready = execution_ready
        st.session_state.last_errors = errors
        st.session_state.last_run_id = run_id

        valid_ratio = len(results) / max(len(universe), 1)
        if len(results) == len(universe):
            final_status = "COMPLETED"
        elif valid_ratio >= MANAGED_MIN_VALID_RATIO:
            final_status = "COMPLETED_PARTIAL"
        else:
            final_status = "FAILED"

        outcome_stats = {
            "checked": 0,
            "updated": 0,
            "complete": 0,
            "seeded": 0,
            "mode": "SKIPPED",
            "status": "SKIPPED",
        }
        if persist and store is not None and run_record_created:
            try:
                store.save_results(run_id, results)
                try:
                    refreshed = refresh_pending_outcomes(store, universe, load_price)
                    seeded = seed_signal_outcomes(store, run_id, results, load_price)
                    outcome_stats = {**refreshed, "seeded": int(seeded), "status": "OK"}
                except Exception as exc:
                    outcome_stats = {
                        "checked": 0,
                        "updated": 0,
                        "complete": 0,
                        "seeded": 0,
                        "mode": "UNAVAILABLE",
                        "status": f"UNAVAILABLE: {exc}",
                    }
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
                if final_status == "COMPLETED":
                    st.success(
                        f"Persisted • {len(results)}/{len(universe)} valid • "
                        f"Decision Top {len(decision_top)} • Execution Ready {len(execution_ready)}"
                    )
                elif final_status == "COMPLETED_PARTIAL":
                    st.warning(f"Persisted PARTIAL • {len(results)}/{len(universe)} valid ({valid_ratio:.1%})")
                else:
                    st.error(f"Run FAILED integrity gate • valid {len(results)}/{len(universe)} ({valid_ratio:.1%})")
            except Exception as exc:
                st.warning(f"Scan selesai, persistence gagal: {exc}")
        st.session_state.last_outcome_stats = outcome_stats
        bar.progress(1.0, text="Stage 5/5 • ZAPI decision pipeline complete")
        status_box.caption("Pipeline complete")

    results = st.session_state.last_results
    decision_top = st.session_state.last_decision_top
    execution_ready = st.session_state.last_execution_ready
    errors = st.session_state.last_errors
    price_stats = st.session_state.last_price_stats or {}
    zapi_stats = st.session_state.last_zapi_stats or {}
    slow_stats = st.session_state.last_slow_stats or {}
    foreign_stats = st.session_state.last_foreign_selection_stats or {}
    outcome_stats = st.session_state.last_outcome_stats or {}

    if isinstance(results, pd.DataFrame) and not results.empty:
        display = results.copy()
        if "diagnostics" in display.columns:
            for name in (
                "sector",
                "sector_regime_score",
                "sector_regime_label",
                "sector_relative_strength_20d_pct",
                "foreign_evidence_coverage_pct",
                "foreign_window_state",
                "foreign_data_freshness",
                "free_float_pct",
                "float_turnover_20d_pct",
                "foreign_net_to_float_20d_pct",
                "ownership_score",
                "foreign_ownership_change_pct",
                "recent_dilution_pct",
                "corporate_action_score",
            ):
                if name not in display.columns:
                    display[name] = display["diagnostics"].map(
                        lambda value, key=name: _diag(value).get(key)
                    )

        decision_display = (
            decision_top.copy()
            if isinstance(decision_top, pd.DataFrame) and not decision_top.empty
            else pd.DataFrame()
        )
        ready_display = (
            execution_ready.copy()
            if isinstance(execution_ready, pd.DataFrame) and not execution_ready.empty
            else pd.DataFrame()
        )

        st.subheader("Decision Funnel")
        f1, f2, f3, f4, f5 = st.columns(5)
        f1.metric("Valid research", len(display))
        f2.metric("ZAPI flow", int(display.get("evidence_tier", pd.Series(dtype=object)).eq("ZAPI_FLOW").sum()))
        f3.metric("Decision Top", len(decision_display))
        f4.metric("Execution Ready", len(ready_display))
        f5.metric("Sectors", len(set(sector_map.values())) if sector_map else 0)

        base_cols = [
            "ticker", "final_score", "phase", "action", "real_money_state", "evidence_tier",
            "sector", "sector_regime_score", "sector_relative_strength_20d_pct",
            "accumulation_score", "foreign_institutional_score", "foreign_evidence_coverage_pct",
            "free_float_pct", "foreign_net_to_float_20d_pct", "ownership_score",
            "recent_dilution_pct", "market_context_score", "smc_execution_score",
            "price_data_quality_score", "distribution_risk",
            "entry_low", "entry_high", "invalidation", "tp1", "tp2",
        ]

        st.subheader("1. Raw Research Priority — 400 Ticker")
        st.dataframe(
            display[[c for c in base_cols if c in display.columns]],
            width="stretch",
            hide_index=True,
        )

        st.subheader("2. ZAPI Flow Decision — Top 20")
        st.caption(
            "Gate: ZAPI FULL/FRESH/VALID, price quality ≥70, distribution <70, "
            "bukan Distribution/Reduce-Avoid. Ranking memakai flow, accumulation, sector context, "
            "free-float/ownership/corporate-action evidence, dan SMC/ICT."
        )
        if decision_display.empty:
            st.warning("Belum ada kandidat yang lolos ZAPI decision gate.")
        else:
            cols = ["decision_rank"] + [c for c in base_cols if c in decision_display.columns]
            st.dataframe(decision_display[cols], width="stretch", hide_index=True)

        st.subheader("3. Execution Ready — Top 10")
        st.caption(
            "Execution Ready membutuhkan ZAPI ≥80% coverage + FULL/FRESH/VALID, score ≥65, "
            "price/SMC geometry valid, tidak ada extreme-low free float, dan tidak ada material "
            "recent dilution hard-block."
        )
        if ready_display.empty:
            st.info("Belum ada setup yang memenuhi seluruh execution gate.")
        else:
            cols = ["execution_rank"] + [c for c in base_cols if c in ready_display.columns]
            st.dataframe(ready_display[cols], width="stretch", hide_index=True)

        st.subheader("Single Ticker Audit")
        selected = st.selectbox("Ticker", display["ticker"].tolist())
        row = display[display["ticker"] == selected].iloc[0].to_dict()
        a, b, c, d, e = st.columns(5)
        a.metric("Final Score", row.get("final_score"))
        b.metric("Phase", row.get("phase"))
        c.metric("State", row.get("real_money_state"))
        d.metric("Sector", row.get("sector") or "UNKNOWN")
        ff = row.get("free_float_pct")
        e.metric("Free Float", f"{float(ff):.1f}%" if pd.notna(ff) else "N/A")
        st.write(row.get("guardrail_reason"))
        st.json(row.get("diagnostics", {}), expanded=False)

        st.subheader("Data Integrity & Calibration")
        d1, d2, d3, d4, d5, d6 = st.columns(6)
        d1.metric("OHLCV valid", len(display))
        d2.metric("ZAPI days", int(zapi_stats.get("days", 0) or 0))
        d3.metric("ZAPI tickers", int(foreign_stats.get("zapi_selected_tickers", 0) or 0))
        d4.metric("Float snapshot", int(slow_stats.get("stock_snapshot_tickers", 0) or 0))
        d5.metric("Ownership", int(slow_stats.get("ownership_tickers", 0) or 0))
        d6.metric("Capital actions", int(slow_stats.get("capital_action_tickers", 0) or 0))
        st.caption(
            f"OOS memory: seeded {int(outcome_stats.get('seeded', 0) or 0)} • "
            f"updated {int(outcome_stats.get('updated', 0) or 0)} • "
            "weights remain shadow-calibration only; no automatic retuning from a small sample."
        )

        st.download_button(
            "Download scan CSV",
            data=export_scan_csv(display),
            file_name=f"idx_flow_scan_{st.session_state.last_run_id}.csv",
            mime="text/csv",
        )

    if errors:
        err = pd.DataFrame(errors)
        with st.expander(f"Pipeline warnings/errors ({len(err)})", expanded=False):
            st.dataframe(err, width="stretch", hide_index=True)

