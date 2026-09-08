from __future__ import annotations

import sys
from pathlib import Path

import streamlit as st

ROOT = Path(__file__).resolve().parent
SRC = ROOT / "src"
if str(SRC) not in sys.path:
    sys.path.insert(0, str(SRC))

import idx_flow_scanner.streamlit_app as streamlit_app
import idx_flow_scanner.zapi_pipeline as zapi_pipeline
from idx_flow_scanner.adaptive_broker_scoring import (
    apply_adaptive_broker_overlay,
    load_adaptive_broker_context,
    set_adaptive_broker_context,
)
from idx_flow_scanner.broker_behavior import load_official_broker_activity
from idx_flow_scanner.broker_behavior_runtime import (
    apply_broker_behavior_overlay,
    set_broker_activity_context,
    verified_daily_foreign_ready,
)
from idx_flow_scanner.canonical_slow_evidence import (
    compute_slow_evidence_canonical,
    load_canonical_capital_actions,
    load_canonical_ownership,
    merge_canonical_capital_actions,
    merge_canonical_ownership,
)
from idx_flow_scanner.evidence_database import (
    load_stock_summary,
    merge_stock_summary,
    upsert_capital_actions,
    upsert_ownership,
    upsert_stock_summary,
)
from idx_flow_scanner.foreign_evidence import prepare_foreign_evidence
from idx_flow_scanner.large_universe_prices import prepare_large_universe_prices
from idx_flow_scanner.official_controller_ownership import (
    apply_official_controller_overlay,
    load_official_controller_profiles,
    set_official_controller_context,
)
from idx_flow_scanner.official_idx_risk import (
    apply_official_risk_overlay,
    load_official_idx_risk_events,
    set_official_risk_context,
)
from idx_flow_scanner.official_index_context import (
    apply_official_index_overlay,
    load_official_index_summary,
    set_official_index_context,
)
from idx_flow_scanner.run_metadata_guard import install_truthful_run_metadata
from idx_flow_scanner.runtime_persistence import install_current_result_persistence
from idx_flow_scanner.storage import SupabaseStore
from idx_flow_scanner.ui_truth import load_calibration_truth, summarize_effective_evidence
from idx_flow_scanner.universe_700 import materialize_universe_700
from idx_flow_scanner.verified_foreign_store import (
    IDX_OFFICIAL_STOCK_SUMMARY_SOURCE,
    load_verified_daily_foreign_flows,
)

BASE_UNIVERSE_PATH = ROOT / "data" / "universe" / "idx_400_syariah.csv"
BUNDLED_UNIVERSE_700_PATH = ROOT / "data" / "universe" / "idx_700_all.csv"
RUNTIME_UNIVERSE_PATH = Path("/tmp/idx_flow_runtime_universe_700.csv")
SEED_700_PATH = ROOT / "data" / "cache" / "idx_700_ohlcv_1y.csv.gz"
SEED_400_PATH = ROOT / "data" / "cache" / "idx_400_ohlcv_1y.csv.gz"
# Canonical Supabase project for IDX Flow Scanner. Project separation remains
# enforced at table level: IDX Flow reads/writes only the flow_* namespace.
EXPECTED_SUPABASE_PROJECT_REF = "djqvhbeonmicztxfisav"


@st.cache_data(ttl=1800, show_spinner=False)
def _resolved_universe_path(api_key: str | None) -> str:
    if BUNDLED_UNIVERSE_700_PATH.exists():
        return str(BUNDLED_UNIVERSE_700_PATH)
    path = materialize_universe_700(
        BASE_UNIVERSE_PATH,
        api_key=api_key,
        output_path=RUNTIME_UNIVERSE_PATH,
        target_size=700,
        strict=False,
    )
    return str(path)


@st.cache_resource(show_spinner=False)
def _dedicated_evidence_store(url: str | None, key: str | None):
    clean_url = str(url or "").strip().rstrip("/")
    clean_key = str(key or "").strip()
    expected = f"https://{EXPECTED_SUPABASE_PROJECT_REF}.supabase.co"
    if clean_url != expected or not clean_key:
        return None
    try:
        return SupabaseStore(clean_url, clean_key)
    except Exception:
        return None


DEDICATED_EVIDENCE_STORE = _dedicated_evidence_store(
    streamlit_app._secret("SUPABASE_URL"),
    streamlit_app._secret("SUPABASE_SECRET_KEY"),
)


@st.cache_data(ttl=30, show_spinner=False)
def _cached_calibration_truth() -> dict[str, object]:
    return load_calibration_truth(DEDICATED_EVIDENCE_STORE)


def _prepare_prices(
    universe,
    store,
    period="1y",
    *,
    min_rows=80,
    status=None,
    seed_path=None,
):
    preferred_seed = seed_path or (SEED_700_PATH if SEED_700_PATH.exists() else SEED_400_PATH)
    return prepare_large_universe_prices(
        universe,
        store or DEDICATED_EVIDENCE_STORE,
        period=period,
        min_rows=min_rows,
        status=status,
        seed_path=preferred_seed,
    )


def _database_first_slow_loader(original_loader, database_loader, merger, writer):
    def load(universe, *args, **kwargs):
        bundled = original_loader(universe, *args, **kwargs)
        store = DEDICATED_EVIDENCE_STORE
        if store is None:
            return bundled
        database = database_loader(store, universe)
        merged = merger(database, bundled)
        if bundled is not None and not bundled.empty and writer is not None:
            try:
                writer(store, bundled)
            except Exception:
                pass
        return merged if merged is not None and not merged.empty else bundled

    return load


_original_connect_store = streamlit_app.connect_store


def _locked_connect_store(enabled: bool):
    if not enabled:
        return None, None
    if DEDICATED_EVIDENCE_STORE is not None:
        return DEDICATED_EVIDENCE_STORE, None
    url = str(streamlit_app._secret("SUPABASE_URL") or "").strip()
    if url and EXPECTED_SUPABASE_PROJECT_REF not in url:
        return None, (
            "SUPABASE_URL bukan physical database IDX Flow yang diizinkan "
            f"({EXPECTED_SUPABASE_PROJECT_REF}); koneksi ditolak oleh hard lock"
        )
    return _original_connect_store(enabled)


_original_zapi_foreign = streamlit_app._zapi_foreign


def _database_first_zapi_foreign(universe, store, load_price):
    resolved_store = store or DEDICATED_EVIDENCE_STORE
    if resolved_store is not None:
        verified = load_verified_daily_foreign_flows(
            resolved_store,
            universe,
            lookback_calendar_days=120,
            allow_zapi_fallback=True,
        )
        if (
            verified is not None
            and not verified.empty
            and "source" in verified.columns
            and verified["source"].eq(IDX_OFFICIAL_STOCK_SUMMARY_SOURCE).any()
        ):
            foreign_flow, selection_stats = prepare_foreign_evidence(
                universe,
                verified,
                load_price,
                lookback=20,
            )
            return (
                foreign_flow,
                {
                    **streamlit_app.data_stats(verified),
                    "source": IDX_OFFICIAL_STOCK_SUMMARY_SOURCE,
                    "transport": "OFFICIAL_IDX_BLOCK",
                    "zapi_role": "FALLBACK_ONLY_WHEN_OFFICIAL_ABSENT",
                },
                selection_stats,
            )
    return _original_zapi_foreign(
        universe,
        resolved_store,
        load_price,
    )


_original_scan_one_zapi = zapi_pipeline.scan_one_zapi
_original_scan_universe_zapi = streamlit_app.scan_universe_zapi
_original_ticker_market_features = zapi_pipeline.ticker_market_features


def _official_index_market_features(ticker, context):
    base = _original_ticker_market_features(ticker, context)
    return apply_official_index_overlay(
        ticker,
        base,
        reference_date=context.get("reference_date") if isinstance(context, dict) else None,
    )


def _controller_enriched_slow_evidence(ticker, price, foreign_features, **kwargs):
    base = compute_slow_evidence_canonical(
        ticker,
        price,
        foreign_features,
        **kwargs,
    )
    return apply_official_controller_overlay(
        ticker,
        price,
        base,
    )


def _broker_scored_base(ticker, price, **kwargs):
    return apply_broker_behavior_overlay(
        _original_scan_one_zapi,
        ticker,
        price,
        **kwargs,
    )


def _adaptive_broker_scored_base(ticker, price, **kwargs):
    return apply_adaptive_broker_overlay(
        _broker_scored_base,
        ticker,
        price,
        **kwargs,
    )


def _broker_risk_scored_scan_one(ticker, price, **kwargs):
    return apply_official_risk_overlay(
        _adaptive_broker_scored_base,
        ticker,
        price,
        **kwargs,
    )


def _database_first_scan_universe(*args, **kwargs):
    activity = load_official_broker_activity(
        DEDICATED_EVIDENCE_STORE,
        lookback_calendar_days=120,
    )
    set_broker_activity_context(activity)
    universe = args[0] if args else kwargs.get("universe", [])
    universe_list = list(universe or [])
    adaptive_context = load_adaptive_broker_context(
        DEDICATED_EVIDENCE_STORE,
        universe_list,
    )
    set_adaptive_broker_context(adaptive_context)
    risk_events = load_official_idx_risk_events(
        DEDICATED_EVIDENCE_STORE,
        universe_list,
        lookback_calendar_days=270,
    )
    set_official_risk_context(risk_events)
    index_summary = load_official_index_summary(
        DEDICATED_EVIDENCE_STORE,
        lookback_calendar_days=140,
    )
    set_official_index_context(index_summary)
    controller_profiles = load_official_controller_profiles(
        DEDICATED_EVIDENCE_STORE,
        universe_list,
        lookback_calendar_days=90,
    )
    set_official_controller_context(controller_profiles)
    return _original_scan_universe_zapi(*args, **kwargs)


# UI truth adapters. The base Streamlit module historically displayed several
# pre-scan input-frame counts. These adapters replace only presentation semantics:
# the values now come from the scored rows users actually see and from canonical
# OOS memory. Production scoring, ranking and authorization are untouched.
_original_render_health_cards = streamlit_app.render_health_cards
_original_render_section = streamlit_app.render_section
_original_st_columns = st.columns
_original_create_durable_run_record = streamlit_app.create_durable_run_record
_UI_TRUTH_STATE = {"suppress_legacy_calibration_metrics": False}


class _SilentMetricColumn:
    def metric(self, *_args, **_kwargs):
        return None

    def __enter__(self):
        return self

    def __exit__(self, *_args):
        return False


def _truthful_health_cards(cards):
    labels = [str(card[0]) for card in cards or [] if isinstance(card, (list, tuple)) and card]
    if "Foreign History" not in labels:
        return _original_render_health_cards(cards)

    results = st.session_state.get("last_results")
    truth = summarize_effective_evidence(results)
    total = int(truth.get("total", 0) or 0)
    if total <= 0:
        return _original_render_health_cards(cards)

    first = next((card for card in cards if str(card[0]) == "Foreign History"), None)
    foreign_history = first or ("Foreign History", "0 days", "no freshness date")
    truthful_cards = [
        foreign_history,
        (
            "Verified Flow",
            f"{truth['verified_flow']}/{total}",
            f"official {truth['official_flow']} · fallback {truth['fallback_flow']} · proxy {truth['price_proxy']}",
        ),
        (
            "Stock Structure",
            f"{truth['stock_structure']}/{total}",
            "effective scored rows with listed/tradable shares",
        ),
        (
            "Ownership",
            f"{truth['ownership']}/{total}",
            f"KSEI+controller {truth['ownership_ksei_controller']} · controller-only {truth['ownership_controller_only']}",
        ),
        (
            "Corp Actions",
            f"{truth['corporate_action_history']}/{total}",
            f"history available · recent-event tickers {truth['recent_corporate_actions']}",
        ),
    ]
    return _original_render_health_cards(truthful_cards)


def _truthful_render_section(title, description):
    if title == "Verified Flow Decision — Top 20":
        description = (
            "FULL/FRESH/VALID official IDX or verified fallback flow, "
            "price-data quality ≥70 and distribution risk <70."
        )

    if title != "Calibration Memory":
        return _original_render_section(title, description)

    _original_render_section(
        "Calibration Memory — Canonical Truth",
        "Actual OOS maturity from canonical flow_signal_outcomes; RPC telemetry is shown separately.",
    )
    truth = _cached_calibration_truth()
    if bool(truth.get("available")):
        c1, c2, c3, c4, c5 = _original_st_columns(5)
        c1.metric("Total Signals", int(truth.get("total", 0) or 0))
        c2.metric("Mature 5D", int(truth.get("mature_5d", 0) or 0))
        c3.metric("Mature 20D", int(truth.get("mature_20d", 0) or 0))
        c4.metric("Mature 60D", int(truth.get("mature_60d", 0) or 0))
        c5.metric("Pending", int(truth.get("pending", 0) or 0))
        if bool(truth.get("truncated")):
            st.warning("Calibration truth query reached its safety row limit; counts are partial.")
    else:
        st.caption("Canonical calibration memory unavailable; no value is inferred.")

    telemetry = st.session_state.get("last_outcome_stats") or {}
    st.caption(
        "Last scan telemetry · "
        f"seeded {int(telemetry.get('seeded', 0) or 0)} · "
        f"RPC processed {int(telemetry.get('updated', 0) or 0)} · "
        f"mode {telemetry.get('mode', 'SKIPPED')}"
    )
    _UI_TRUTH_STATE["suppress_legacy_calibration_metrics"] = True
    return None


def _truthful_columns(spec, *args, **kwargs):
    if _UI_TRUTH_STATE.get("suppress_legacy_calibration_metrics") and spec == 4:
        _UI_TRUTH_STATE["suppress_legacy_calibration_metrics"] = False
        return tuple(_SilentMetricColumn() for _ in range(4))
    return _original_st_columns(spec, *args, **kwargs)


def _stale_safe_create_durable_run_record(store, run_id, universe_count, config):
    # Manual retries previously remained blocked by an orphaned OHLCV_PREP row.
    # Clean only runs whose heartbeat has been silent for >10 minutes; genuinely
    # active runs keep their lock.
    try:
        streamlit_app.mark_stale_managed_runs(store, max_age_minutes=10)
    except Exception:
        pass
    return _original_create_durable_run_record(store, run_id, universe_count, config)


streamlit_app.DEFAULT_UNIVERSE_PATH = Path(
    _resolved_universe_path(streamlit_app._secret("ZAPI_KEY"))
)
streamlit_app.prepare_database_first_prices = _prepare_prices
streamlit_app.connect_store = _locked_connect_store
streamlit_app._zapi_foreign = _database_first_zapi_foreign
streamlit_app.load_bundled_zapi_stock_summary = _database_first_slow_loader(
    streamlit_app.load_bundled_zapi_stock_summary,
    load_stock_summary,
    merge_stock_summary,
    upsert_stock_summary,
)
streamlit_app.load_bundled_zapi_ownership = _database_first_slow_loader(
    streamlit_app.load_bundled_zapi_ownership,
    load_canonical_ownership,
    merge_canonical_ownership,
    upsert_ownership,
)
streamlit_app.load_bundled_zapi_capital_actions = _database_first_slow_loader(
    streamlit_app.load_bundled_zapi_capital_actions,
    load_canonical_capital_actions,
    merge_canonical_capital_actions,
    upsert_capital_actions,
)
# Runtime compatibility patches. Official IDX direct foreign flow is the primary
# verified provider. Official IDX indices anchor market/sector context, Company
# Profile contributes a distinct controller-identity dimension to KSEI ownership,
# the total broker-family ranking budget remains bounded at 8%, Phase 3A/3B/3C
# can consume an adaptively calibrated share of that budget, and official
# UMA/suspension can only de-rate or block authorization.
zapi_pipeline._zapi_ready = verified_daily_foreign_ready
zapi_pipeline.compute_slow_evidence = _controller_enriched_slow_evidence
zapi_pipeline.ticker_market_features = _official_index_market_features
zapi_pipeline.scan_one_zapi = _broker_risk_scored_scan_one
streamlit_app.scan_universe_zapi = _database_first_scan_universe
streamlit_app.render_health_cards = _truthful_health_cards
streamlit_app.render_section = _truthful_render_section
streamlit_app.st.columns = _truthful_columns
streamlit_app.create_durable_run_record = _stale_safe_create_durable_run_record

install_current_result_persistence(SupabaseStore, batch_size=20)
install_truthful_run_metadata(SupabaseStore)

version_file = ROOT / "VERSION"
if version_file.exists():
    streamlit_app.APP_VERSION = version_file.read_text(encoding="utf-8").strip() or streamlit_app.APP_VERSION

streamlit_app.run()
