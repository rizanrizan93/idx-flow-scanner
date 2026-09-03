from __future__ import annotations

import os
import uuid
from pathlib import Path

import pandas as pd
import streamlit as st

from .authorization import export_scan_csv
from .config import ZapiFlowConfig
from .database_first import prepare_database_first_prices
from .decision import select_execution_ready, select_zapi_decision_top
from .foreign_evidence import prepare_foreign_evidence
from .managed import (
    ManagedDecision,
    decide_managed_run,
    load_bundled_universe,
    mark_stale_managed_runs,
    recent_runs,
    universe_signature,
)
from .outcomes import refresh_pending_outcomes, seed_signal_outcomes
from .providers.zapi import (
    fetch_zapi_stock_summary_day,
    load_bundled_zapi_foreign_flows,
    load_bundled_zapi_stock_summary,
)
from .slow_evidence import (
    load_bundled_zapi_capital_actions,
    load_bundled_zapi_ownership,
)
from .storage import DuplicateActiveUniverseRunError, SupabaseStore
from .vendor_foreign_store import (
    load_zapi_vendor_foreign_flows,
    upsert_zapi_vendor_foreign_flows,
)
from .zapi_pipeline import scan_universe_zapi

APP_VERSION = "0.4.0"
ROOT = Path(__file__).resolve().parents[2]
DEFAULT_UNIVERSE_PATH = ROOT / "data" / "universe" / "idx_400_syariah.csv"
MANAGED_MIN_VALID_RATIO = 0.90


def create_durable_run_record(
    store: SupabaseStore,
    run_id: str,
    universe_count: int,
    config: dict[str, object],
) -> bool:
    try:
        store.create_run(run_id, universe_count, config)
        store.update_run_progress(run_id, 0, "OHLCV_PREP")
        return True
    except DuplicateActiveUniverseRunError:
        st.error(
            "Scan tidak dimulai: run aktif yang sudah ada masih memiliki lock universe ini."
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
        return {"rows": 0, "tickers": 0, "days": 0, "freshest": None}
    dates = pd.to_datetime(frame.get("trade_date"), errors="coerce")
    return {
        "rows": int(len(frame)),
        "tickers": int(frame["ticker"].nunique()) if "ticker" in frame.columns else 0,
        "days": int(dates.nunique()) if dates is not None else 0,
        "freshest": (
            str(dates.max().date())
            if dates is not None and pd.notna(dates.max())
            else None
        ),
    }


def _diag(value: object) -> dict[str, object]:
    return value if isinstance(value, dict) else {}


def _zapi_foreign(
    universe: list[str],
    store: SupabaseStore | None,
    load_price,
) -> tuple[pd.DataFrame, dict[str, object], dict[str, object]]:
    db_zapi = (
        load_zapi_vendor_foreign_flows(store, universe, lookback_calendar_days=120)
        if store is not None
        else pd.DataFrame()
    )
    bundled_zapi = load_bundled_zapi_foreign_flows(
        universe, lookback_calendar_days=120
    )
    valid = [
        frame
        for frame in (db_zapi, bundled_zapi)
        if frame is not None and not frame.empty
    ]
    candidates = pd.concat(valid, ignore_index=True) if valid else pd.DataFrame()
    if store is not None and bundled_zapi is not None and not bundled_zapi.empty:
        try:
            upsert_zapi_vendor_foreign_flows(store, bundled_zapi)
        except Exception:
            pass

    foreign_flow, selection_stats = prepare_foreign_evidence(
        universe, candidates, load_price, lookback=20
    )
    return (
        foreign_flow,
        {**data_stats(candidates), "source": "ZAPI_IDX_FOREIGN_FLOW"},
        selection_stats,
    )


def run() -> None:
    st.set_page_config(page_title="IDX Flow Scanner", page_icon="📡", layout="wide")
    st.title("IDX Flow Scanner")
    st.caption(
        f"v{APP_VERSION} • OHLCV + ZAPI flow + sector context + "
        "free-float/ownership/corporate-action → SMC/ICT → decision"
    )
    st.info(
        "Broker-direct, Index Alpha, GOAPI broker dan direct-IDX broker collector "
        "sudah dikeluarkan dari runtime produksi. ZAPI adalah provider flow utama."
    )

    with st.sidebar:
        st.header("Managed Scan")
        period = st.selectbox("OHLCV lookback", ["6mo", "1y", "2y"], index=1)
        use_zapi = st.checkbox("ZAPI evidence", value=True)
        use_database = st.checkbox(
            "Dedicated IDX Flow Supabase",
            value=False,
            help=(
                "Biarkan OFF sampai SUPABASE_URL/SECRET menunjuk project IDX Flow Scanner "
                "yang benar. Ini mencegah write ke project Supabase lain."
            ),
        )
        persist = st.checkbox(
            "Persist hasil scan",
            value=False,
            disabled=not use_database,
        )
        managed_auto = st.toggle(
            "Managed auto-run",
            value=False,
            disabled=not (use_database and persist),
        )
        run_manual = st.button(
            "Run / Re-run sekarang", type="primary", width="stretch"
        )

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

    sector_map: dict[str, str] = {}
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
            managed_decision = ManagedDecision(
                False, f"managed gate unavailable: {exc}"
            )

    m1, m2, m3, m4 = st.columns(4)
    m1.metric("Universe", len(universe))
    m2.metric("Pipeline", "ZAPI-ONLY")
    m3.metric("Sectors", len(set(sector_map.values())) if sector_map else 0)
    m4.metric("DB", "CONNECTED" if store is not None else "OFF")

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
                    "market_context": (
                        "MARKET_30__SECTOR_30__SECTOR_RS_25__MARKET_RS_15"
                    ),
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
        zapi_stats = {
            "rows": 0,
            "tickers": 0,
            "days": 0,
            "freshest": None,
            "source": "DISABLED",
        }
        foreign_selection_stats = {
            "zapi_selected_tickers": 0,
            "foreign_unavailable_tickers": len(universe),
            "median_selected_coverage_pct": 0.0,
        }
        if use_zapi:
            status_box.caption("Stage 2/5 • ZAPI foreign-flow evidence")
            try:
                (
                    foreign_flow,
                    zapi_stats,
                    foreign_selection_stats,
                ) = _zapi_foreign(universe, store, load_price)
            except Exception as exc:
                st.warning(
                    "ZAPI foreign evidence unavailable; scanner remains research-only: "
                    f"{exc}"
                )

        status_box.caption("Stage 3/5 • ZAPI slow evidence")
        stock_snapshot = load_bundled_zapi_stock_summary(universe)
        ownership = load_bundled_zapi_ownership(universe)
        capital_actions = load_bundled_zapi_capital_actions(universe)

        if use_zapi and stock_snapshot.empty and run_manual:
            try:
                latest_dates: list[pd.Timestamp] = []
                for ticker in universe[:20]:
                    px = load_price(ticker)
                    if px is not None and not px.empty:
                        latest_dates.append(
                            pd.to_datetime(px["date"], errors="coerce").max()
                        )
                target = max(
                    [d for d in latest_dates if pd.notna(d)],
                    default=pd.Timestamp.today(),
                )
                stock_snapshot = fetch_zapi_stock_summary_day(
                    universe,
                    pd.Timestamp(target).date(),
                    api_key=_secret("ZAPI_KEY"),
                )
            except Exception as exc:
                st.caption(f"ZAPI stock-summary live fallback unavailable: {exc}")

        slow_stats = {
            "stock_snapshot_tickers": (
                int(stock_snapshot["ticker"].nunique())
                if not stock_snapshot.empty and "ticker" in stock_snapshot.columns
                else 0
            ),
            "ownership_tickers": (
                int(ownership["ticker"].nunique())
                if not ownership.empty and "ticker" in ownership.columns
                else 0
            ),
            "capital_action_tickers": (
                int(capital_actions["ticker"].nunique())
                if not capital_actions.empty and "ticker" in capital_actions.columns
                else 0
            ),
        }
        st.session_state.last_zapi_stats = zapi_stats
        st.session_state.last_slow_stats = slow_stats
        st.session_state.last_foreign_selection_stats = foreign_selection_stats

        def progress(i: int, total: int, ticker: str) -> None:
            bar.progress(
                i / max(total, 1),
                text=f"Stage 4/5 • {i}/{total} • {ticker}",
            )
            status_box.caption(
                f"ZAPI + sector + slow evidence + SMC scoring "
                f"{ticker} • {i}/{total}"
            )
            if (
                store is not None
                and run_record_created
                and (i == 1 or i % 20 == 0 or i == total)
            ):
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
                    refreshed = refresh_pending_outcomes(
                        store, universe, load_price
                    )
                    seeded = seed_signal_outcomes(
                        store, run_id, results, load_price
                    )
                    outcome_stats = {
                        **refreshed,
                        "seeded": int(seeded),
                        "status": "OK",
                    }
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
                        "price_cache_hits": int(
                            price_stats.get("cache_hits", 0)
                        ),
                        "price_fetched": int(
                            price_stats.get("fetched_valid", 0)
                        ),
                        "price_failures": int(
                            price_stats.get("unavailable", 0)
                        ),
                    },
                )
                if final_status == "COMPLETED":
                    st.success(
                        f"Persisted • {len(results)}/{len(universe)} valid • "
                        f"Decision Top {len(decision_top)} • "
                        f"Execution Ready {len(execution_ready)}"
                    )
                elif final_status == "COMPLETED_PARTIAL":
                    st.warning(
                        f"Persisted PARTIAL • {len(results)}/{len(universe)} "
                        f"valid ({valid_ratio:.1%})"
                    )
                else:
                    st.error(
                        f"Run FAILED integrity gate • valid "
                        f"{len(results)}/{len(universe)} ({valid_ratio:.1%})"
                    )
            except Exception as exc:
                st.warning(f"Scan selesai, persistence gagal: {exc}")

        st.session_state.last_outcome_stats = outcome_stats
        bar.progress(1.0, text="Stage 5/5 • ZAPI decision pipeline complete")
        status_box.caption("Pipeline complete")

    results = st.session_state.last_results
    decision_top = st.session_state.last_decision_top
    execution_ready = st.session_state.last_execution_ready
    errors = st.session_state.last_errors
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
            if isinstance(decision_top, pd.DataFrame)
            else pd.DataFrame()
        )
        ready_display = (
            execution_ready.copy()
            if isinstance(execution_ready, pd.DataFrame)
            else pd.DataFrame()
        )

        st.subheader("Decision Funnel")
        f1, f2, f3, f4, f5 = st.columns(5)
        f1.metric("Valid research", len(display))
        f2.metric(
            "ZAPI flow",
            int(
                display.get(
                    "evidence_tier", pd.Series(dtype=object)
                ).eq("ZAPI_FLOW").sum()
            ),
        )
        f3.metric("Decision Top", len(decision_display))
        f4.metric("Execution Ready", len(ready_display))
        f5.metric("Sectors", len(set(sector_map.values())) if sector_map else 0)

        base_cols = [
            "ticker",
            "final_score",
            "phase",
            "action",
            "real_money_state",
            "evidence_tier",
            "sector",
            "sector_regime_score",
            "sector_relative_strength_20d_pct",
            "accumulation_score",
            "foreign_institutional_score",
            "foreign_evidence_coverage_pct",
            "free_float_pct",
            "foreign_net_to_float_20d_pct",
            "ownership_score",
            "recent_dilution_pct",
            "market_context_score",
            "smc_execution_score",
            "price_data_quality_score",
            "distribution_risk",
            "entry_low",
            "entry_high",
            "invalidation",
            "tp1",
            "tp2",
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
            "bukan Distribution/Reduce-Avoid."
        )
        if decision_display.empty:
            st.warning("Belum ada kandidat yang lolos ZAPI decision gate.")
        else:
            cols = ["decision_rank"] + [
                c for c in base_cols if c in decision_display.columns
            ]
            st.dataframe(
                decision_display[cols], width="stretch", hide_index=True
            )

        st.subheader("3. Execution Ready — Top 10")
        st.caption(
            "Requires ZAPI ≥80% coverage, score ≥65, valid SMC/ICT geometry, "
            "no extreme-low free float and no material dilution hard-block."
        )
        if ready_display.empty:
            st.info("Belum ada setup yang memenuhi seluruh execution gate.")
        else:
            cols = ["execution_rank"] + [
                c for c in base_cols if c in ready_display.columns
            ]
            st.dataframe(
                ready_display[cols], width="stretch", hide_index=True
            )

        st.subheader("Single Ticker Audit")
        selected = st.selectbox("Ticker", display["ticker"].tolist())
        row = display[display["ticker"] == selected].iloc[0].to_dict()
        a, b, c, d, e = st.columns(5)
        a.metric("Final Score", row.get("final_score"))
        b.metric("Phase", row.get("phase"))
        c.metric("State", row.get("real_money_state"))
        d.metric("Sector", row.get("sector") or "UNKNOWN")
        ff = row.get("free_float_pct")
        e.metric(
            "Free Float",
            f"{float(ff):.1f}%" if pd.notna(ff) else "N/A",
        )
        st.write(row.get("guardrail_reason"))
        st.json(row.get("diagnostics", {}), expanded=False)

        st.subheader("Data Integrity & Calibration")
        d1, d2, d3, d4, d5 = st.columns(5)
        d1.metric("ZAPI days", int(zapi_stats.get("days", 0) or 0))
        d2.metric(
            "ZAPI tickers",
            int(foreign_stats.get("zapi_selected_tickers", 0) or 0),
        )
        d3.metric(
            "Float snapshot",
            int(slow_stats.get("stock_snapshot_tickers", 0) or 0),
        )
        d4.metric(
            "Ownership",
            int(slow_stats.get("ownership_tickers", 0) or 0),
        )
        d5.metric(
            "Capital actions",
            int(slow_stats.get("capital_action_tickers", 0) or 0),
        )
        st.caption(
            f"OOS memory: seeded {int(outcome_stats.get('seeded', 0) or 0)} • "
            f"updated {int(outcome_stats.get('updated', 0) or 0)} • "
            "weights remain shadow-calibration only."
        )

        st.download_button(
            "Download scan CSV",
            data=export_scan_csv(display),
            file_name=f"idx_flow_scan_{st.session_state.last_run_id}.csv",
            mime="text/csv",
        )

    if errors:
        err = pd.DataFrame(errors)
        with st.expander(
            f"Pipeline warnings/errors ({len(err)})", expanded=False
        ):
            st.dataframe(err, width="stretch", hide_index=True)
