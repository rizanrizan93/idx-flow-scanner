from __future__ import annotations

import os
from datetime import datetime, timezone
from typing import Any

import pandas as pd


DEFAULT_RESULT_BATCH_SIZE = 25
DEFAULT_PERSIST_TIMEOUT_SECONDS = 30.0


def install_bounded_result_persistence(store_cls: type[Any], *, batch_size: int = DEFAULT_RESULT_BATCH_SIZE) -> None:
    """Bound result persistence and isolate it from the short read/cache timeout.

    The primary Supabase client intentionally uses a short PostgREST timeout so a
    stalled OHLCV cache read fails quickly. Result persistence is a different I/O
    profile: ~400 rows with nested diagnostics. Use a dedicated, longer-lived write
    client and small idempotent batches. If any batch raises, fail the scan run
    explicitly before re-raising so the managed gate never leaves a zombie RUNNING
    row and partial rows remain safe to upsert on the next run.

    Terminal telemetry must report rows that actually completed persistence, not
    rows that merely completed scoring. This distinction matters for managed-run
    validity and evidence-coverage audits after a partial PostgREST failure.
    """
    if getattr(store_cls, "_flow_bounded_result_persistence_installed", False):
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
                try:
                    if write_client is not None:
                        store.client = write_client
                    original_save_results(store, run_id, frame.iloc[start:end].copy())
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
    store_cls._flow_result_persistence_batch_size = bounded_size
