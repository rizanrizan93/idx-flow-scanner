from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
SRC = ROOT / "src"
if str(SRC) not in sys.path:
    sys.path.insert(0, str(SRC))

import idx_flow_scanner.streamlit_app as streamlit_app
from idx_flow_scanner.large_universe_prices import prepare_large_universe_prices
from idx_flow_scanner.persistence_guard import install_bounded_result_persistence
from idx_flow_scanner.storage import SupabaseStore

# The bundled 400-ticker production run uses a bounded DB transport that fails
# directly to the local verified seed instead of cascading into hundreds of
# single-ticker PostgREST requests. Small/ad-hoc universes keep the legacy path.
streamlit_app.prepare_database_first_prices = prepare_large_universe_prices

# Result writes use their own longer-lived Supabase client (the read/cache client
# intentionally stays fast-fail). Keep each idempotent write payload small enough
# for free-tier PostgREST while heartbeating persistence progress.
install_bounded_result_persistence(SupabaseStore, batch_size=20)

version_file = ROOT / "VERSION"
if version_file.exists():
    streamlit_app.APP_VERSION = version_file.read_text(encoding="utf-8").strip() or streamlit_app.APP_VERSION

streamlit_app.run()
