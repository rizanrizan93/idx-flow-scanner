from __future__ import annotations

from datetime import datetime, timezone
from typing import Any

import pandas as pd


DEFAULT_RESULT_BATCH_SIZE = 25


def install_bounded_result_persistence(store_cls: type[Any], *, batch_size: int = DEFAULT_RESULT_BATCH_SIZE) -> None:
    """Bound result persistence so a short PostgREST timeout cannot strand a run.

    The production client intentionally uses a short Data API timeout to keep OHLCV
    cache failures from freezing managed scans. A full ~400-row result upsert can be
    much heavier than cache reads, so persist it in small idempotent batches while
    keeping the scan run heartbeat alive. If a batch raises, fail the run explicitly
    before re-raising so the managed gate never leaves a zombie RUNNING row.
    """
    if getattr(store_cls, "_flow_bounded_result_persistence_installed", False):
        return

    original_save_results = store_cls.save_results
    bounded_size = max(1, min(int(batch_size), 100))

    def _heartbeat(store: Any, run_id: str, completed: int, total: int) -> None:
        try:
            store.client.table("flow_scan_runs").update(
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
        try:
            for start in range(0, total, bounded_size):
                end = min(start + bounded_size, total)
                original_save_results(store, run_id, frame.iloc[start:end].copy())
                _heartbeat(store, run_id, end, total)
        except Exception:
            try:
                store.finish_run(
                    run_id,
                    processed_count=total,
                    error_count=1,
                    status="FAILED",
                )
            except Exception:
                pass
            raise

    store_cls.save_results = bounded_save_results
    store_cls._flow_bounded_result_persistence_installed = True
    store_cls._flow_result_persistence_batch_size = bounded_size
