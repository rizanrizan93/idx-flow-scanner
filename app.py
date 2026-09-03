from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
SRC = ROOT / "src"
if str(SRC) not in sys.path:
    sys.path.insert(0, str(SRC))

import idx_flow_scanner.streamlit_app as streamlit_app
from idx_flow_scanner.large_universe_prices import prepare_large_universe_prices
from idx_flow_scanner.run_metadata_guard import install_truthful_run_metadata
from idx_flow_scanner.runtime_persistence import install_current_result_persistence
from idx_flow_scanner.storage import SupabaseStore

streamlit_app.prepare_database_first_prices = prepare_large_universe_prices
install_current_result_persistence(SupabaseStore, batch_size=20)
install_truthful_run_metadata(SupabaseStore)

version_file = ROOT / "VERSION"
if version_file.exists():
    streamlit_app.APP_VERSION = version_file.read_text(encoding="utf-8").strip() or streamlit_app.APP_VERSION

streamlit_app.run()
