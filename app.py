from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
SRC = ROOT / "src"
if str(SRC) not in sys.path:
    sys.path.insert(0, str(SRC))

import idx_flow_scanner.streamlit_app as streamlit_app
from idx_flow_scanner.indexalpha_budget_guard import install_cache_only_indexalpha_finalist_loader
from idx_flow_scanner.large_universe_prices import prepare_large_universe_prices
from idx_flow_scanner.run_metadata_guard import install_truthful_run_metadata
from idx_flow_scanner.runtime_persistence import install_current_result_persistence
from idx_flow_scanner.storage import SupabaseStore
from idx_flow_scanner.ui_contract_guard import install_truthful_output_lanes

# The bundled 400-ticker production run uses a bounded DB transport that fails
# directly to the local verified seed instead of cascading into hundreds of
# single-ticker PostgREST requests. Small/ad-hoc universes keep the legacy path.
streamlit_app.prepare_database_first_prices = prepare_large_universe_prices

# Index Alpha's five-request/day free allowance is owned by the audited daily warm
# job. Streamlit reruns consume only verified DB/bundled broker evidence so manual
# scans cannot silently spend a second provider budget on the same day.
install_cache_only_indexalpha_finalist_loader(streamlit_app)

# Community Cloud can rerun a new entrypoint while retaining imported package
# modules from an older deployment. Force-reload the persistence module from the
# deployed source before installing the direct 20-row PostgREST writer.
install_current_result_persistence(SupabaseStore, batch_size=20)

# Persist the architecture that actually ran, including the active direct-writer
# revision and warm-job ownership of the Index Alpha daily request budget.
install_truthful_run_metadata(SupabaseStore)

# Keep presentation semantics aligned with the actual production architecture:
# Streamlit is cache-only for Index Alpha, the guarded selector has no hard score
# floor, and Broker-Verified Production contains only strict direct/eligible rows.
install_truthful_output_lanes(streamlit_app)

version_file = ROOT / "VERSION"
if version_file.exists():
    streamlit_app.APP_VERSION = version_file.read_text(encoding="utf-8").strip() or streamlit_app.APP_VERSION

streamlit_app.run()
