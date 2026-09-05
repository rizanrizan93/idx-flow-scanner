from __future__ import annotations

import sys
from pathlib import Path

import streamlit as st

ROOT = Path(__file__).resolve().parent
SRC = ROOT / "src"
if str(SRC) not in sys.path:
    sys.path.insert(0, str(SRC))

import idx_flow_scanner.streamlit_app as streamlit_app
from idx_flow_scanner.evidence_database import (
    load_capital_actions,
    load_ownership,
    load_stock_summary,
    merge_capital_actions,
    merge_ownership,
    merge_stock_summary,
    upsert_capital_actions,
    upsert_ownership,
    upsert_stock_summary,
)
from idx_flow_scanner.large_universe_prices import prepare_large_universe_prices
from idx_flow_scanner.run_metadata_guard import install_truthful_run_metadata
from idx_flow_scanner.runtime_persistence import install_current_result_persistence
from idx_flow_scanner.storage import SupabaseStore
from idx_flow_scanner.universe_700 import materialize_universe_700

BASE_UNIVERSE_PATH = ROOT / "data" / "universe" / "idx_400_syariah.csv"
BUNDLED_UNIVERSE_700_PATH = ROOT / "data" / "universe" / "idx_700_all.csv"
RUNTIME_UNIVERSE_PATH = Path("/tmp/idx_flow_runtime_universe_700.csv")
SEED_700_PATH = ROOT / "data" / "cache" / "idx_700_ohlcv_1y.csv.gz"
SEED_400_PATH = ROOT / "data" / "cache" / "idx_400_ohlcv_1y.csv.gz"
# Physical Supabase project currently hosting the isolated IDX Flow namespace.
# Project separation remains enforced at table level: IDX Flow uses only flow_* tables.
EXPECTED_SUPABASE_PROJECT_REF = "mbtsvflwszcgdtijdgas"


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
        if bundled is not None and not bundled.empty:
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
    return _original_zapi_foreign(
        universe,
        store or DEDICATED_EVIDENCE_STORE,
        load_price,
    )


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
    load_ownership,
    merge_ownership,
    upsert_ownership,
)
streamlit_app.load_bundled_zapi_capital_actions = _database_first_slow_loader(
    streamlit_app.load_bundled_zapi_capital_actions,
    load_capital_actions,
    merge_capital_actions,
    upsert_capital_actions,
)
install_current_result_persistence(SupabaseStore, batch_size=20)
install_truthful_run_metadata(SupabaseStore)

version_file = ROOT / "VERSION"
if version_file.exists():
    streamlit_app.APP_VERSION = version_file.read_text(encoding="utf-8").strip() or streamlit_app.APP_VERSION

streamlit_app.run()
