from __future__ import annotations

import sys
from pathlib import Path

import streamlit as st

ROOT = Path(__file__).resolve().parent
SRC = ROOT / "src"
if str(SRC) not in sys.path:
    sys.path.insert(0, str(SRC))

import idx_flow_scanner.streamlit_app as streamlit_app
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
        store,
        period=period,
        min_rows=min_rows,
        status=status,
        seed_path=preferred_seed,
    )


streamlit_app.DEFAULT_UNIVERSE_PATH = Path(
    _resolved_universe_path(streamlit_app._secret("ZAPI_KEY"))
)
streamlit_app.prepare_database_first_prices = _prepare_prices
install_current_result_persistence(SupabaseStore, batch_size=20)
install_truthful_run_metadata(SupabaseStore)

version_file = ROOT / "VERSION"
if version_file.exists():
    streamlit_app.APP_VERSION = version_file.read_text(encoding="utf-8").strip() or streamlit_app.APP_VERSION

streamlit_app.run()
