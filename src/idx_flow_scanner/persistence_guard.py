from __future__ import annotations

import math
import os
from datetime import date, datetime, timezone
from typing import Any

import numpy as np
import pandas as pd


DEFAULT_RESULT_BATCH_SIZE = 25
DEFAULT_PERSIST_TIMEOUT_SECONDS = 30.0
PERSISTENCE_GUARD_REVISION = "v3.17-json-safe-persistence"


def _json_safe(value: Any) -> Any:
    """Convert nested pandas/numpy values into strict JSON-compatible objects.

    Scan diagnostics are intentionally rich dictionaries. A single numpy scalar,
    Timestamp, pd.NA, NaN or infinity nested inside one row can make the HTTP client
    fail before a PostgREST request is emitted. Keep the evidence values intact
    where representable and map non-finite/missing values to JSON null.
    """
    if value is None:
        return None
    if isinstance(value, dict):
        return {str(k): _json_safe(v) for k, v in value.items()}
    if isinstance(value, (list, tuple, set)):
        return [_json_safe(v) for v in value]
    if isinstance(value, np.generic):
        return _json_safe(value.item())
    if isinstance(value, pd.Timestamp):
        return value.isoformat()
    if isinstance(value, (datetime, date)):
        return value.isoformat()
    if isinstance(value, float):
        return value if math.isfinite(value) else None
    try:
        if pd.isna(value):
            return None
    except (TypeError, ValueError):
        pass
    if isinstance(value, (str, int, bool)):
        return value
    # Diagnostics should never contain executable objects; preserving an unknown
    # value as text is safer than allowing it to abort the whole production run.
    return str(value)


def _sanitize_batch(frame: pd.DataFrame) -> pd.DataFrame:
    if frame is None or frame.empty:
        return frame
    out = frame.copy()
    for col in out.columns:
        if out[col].dtype == "object":
            out[col] = out[col].map(_json_safe)
    return out


def install_bounded_result_persistence(store_cls: type[Any], *, batch_size: int = DEFAULT_RESULT_BATCH_SIZE) -> None:
    """Bound result persistence and isolate it from the short read/cache timeout.

    The primary Supabase client intentionally uses a short PostgREST timeout so a
    stalled OHLCV cache read fails quickly. Result persistence is a different I/O
    profile: ~400 rows with nested diagnostics. Use a dedicated, longer-lived write
    client and small idempotent batches. Each batch is normalized to strict JSON
    before the legacy storage serializer sees it, so one exotic nested numpy/pandas
    value cannot terminate persistence before the HTTP request is sent.

    If any batch still raises, fail the scan run explicitly before re-raising so
    the managed gate never leaves a zombie RUNNING row and partial rows remain safe
    to upsert on the next run. Terminal telemetry reports rows that actually
    completed persistence, not rows that merely completed scoring.

    The installer is revision-aware because Streamlit can hot-reload source files
    while retaining an already monkeypatched ``SupabaseStore`` class in the live
    Python process. A normal rerun with the same revision is idempotent; a deployed
    implementation revision wraps the currently active method again so the new
    fail-closed semantics take effect immediately.
    """
    if getattr(store_cls, "_flow_bounded_result_persistence_revision", None) == PERSISTENCE_GUARD_REVISION:
        return

    original_save_results = store_cls.save_results
    bounded_size = max(1, min(int(batch_size), 100))

    def _get_write_client(store: Any) -> Any | None:
        existing = getattr(store, "_flow_persistence_client", None)
        if existing is not None:
            return existing
        url = str(getattr(store, "url", "") or "").strip()
        key = str(getattr(store, "secret_key", "") or "").strip()
        if not url or not key:
            return getattr(store, "client", None)
        timeout = float(os.getenv("FLOW_SUPABASE_PERSIST_TIMEOUT_SECONDS", str(DEFAULT_PERSIST_TIMEOUT_SECONDS)))
        timeout = min(max(timeout, 15.0), 60.0)
        from supabase import create_client
        from supabase.client import ClientOptions

        client = create_client(
            url,
            key,
            options=ClientOptions(
                postgrest_client_timeout=timeout,
                storage_client_timeout=timeout,
                schema="public",
            ),
        )
        store._flow_persistence_client = client
        store._flow_persistence_timeout_seconds = timeout
        return client

    def _heartbeat(client: Any | None, run_id: str, completed: int, total: int) -> None:
        if client is None:
            return
        try:
            client.table("flow_scan_runs").update(
                {
                    "current_ticker": f"PERSIST_RESULTS_{completed}_{total}",
                    "heartbeat_at": datetime.now(timezone.utc).isoformat(),
                }
            ).eq("id", run_id).execute()
        except Exception:
            pass

    def bounded_save_results(store: Any, run_id: str, frame: pd.DataFrame) -> None:
        if frame is None or frame.empty:
            return original_save_results(store, run_id, frame)

        total = int(len(frame))
        persisted_count = 0
        original_client = getattr(store, "client", None)
        write_client = _get_write_client(store)
        try:
            for start in range(0, total, bounded_size):
                end = min(start + bounded_size, total)
                batch = _sanitize_batch(frame.iloc[start:end])
                try:
                    if write_client is not None:
                        store.client = write_client
                    original_save_results(store, run_id, batch)
                finally:
                    if original_client is not None:
                        store.client = original_client
                persisted_count = end
                _heartbeat(write_client or original_client, run_id, persisted_count, total)
        except Exception:
            if original_client is not None:
                store.client = original_client
            try:
                store.finish_run(
                    run_id,
                    processed_count=persisted_count,
                    error_count=1,
                    status="FAILED",
                )
            except Exception:
                pass
            raise

    store_cls.save_results = bounded_save_results
    store_cls._flow_bounded_result_persistence_installed = True
    store_cls._flow_bounded_result_persistence_revision = PERSISTENCE_GUARD_REVISION
    store_cls._flow_result_persistence_batch_size = bounded_size
