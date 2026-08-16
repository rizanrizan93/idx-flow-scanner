from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
SRC = ROOT / "src"
if str(SRC) not in sys.path:
    sys.path.insert(0, str(SRC))

import idx_flow_scanner.streamlit_app as streamlit_app
from idx_flow_scanner.large_universe_prices import prepare_large_universe_prices

# The bundled 400-ticker production run uses a bounded DB transport that fails
# directly to the local verified seed instead of cascading into hundreds of
# single-ticker PostgREST requests. Small/ad-hoc universes keep the legacy path.
streamlit_app.prepare_database_first_prices = prepare_large_universe_prices

version_file = ROOT / "VERSION"
if version_file.exists():
    streamlit_app.APP_VERSION = version_file.read_text(encoding="utf-8").strip() or streamlit_app.APP_VERSION

streamlit_app.run()
