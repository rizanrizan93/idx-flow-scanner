from __future__ import annotations

import math
import os
from datetime import date, datetime, timezone
from typing import Any

import numpy as np
import pandas as pd


DEFAULT_RESULT_BATCH_SIZE = 20
DEFAULT_PERSIST_TIMEOUT_SECONDS = 30.0
PERSISTENCE_GUARD_REVISION = "v3.18-direct-postgrest-persistence"

_COMPONENT_FIELDS = (
    "accumulation_score",
    "operator_dominance_score",
    "cost_basis_score",
    "retail_exhaustion_score",
    "foreign_institutional_score",
    "supply_concentration_score",
    "price_flow_divergence_score",
    "market_context_score",
    "smc_execution_score",
    "risk_liquidity_score",
    "price_data_quality_score",
)


def _json_safe(value: Any) -> Any:
    """Convert nested pandas/numpy values into strict JSON-compatible objects."""
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
    return str(value)


def _result_records(run_id: str, frame: pd.DataFrame) -> list[dict[str, Any]]:
    """Build the canonical flow_scan_results payload without calling legacy wrappers."""
    records: list[dict[str, Any]] = []
    for row in frame.to_dict("records"):
        record = {
            "run_id": run_id,
            "ticker": row["ticker"],
            "as_of_date": row["as_of_date"],
            "final_score": row["final_score"],
            "phase": row["phase"],
            "action": row["action"],
            "evidence_tier": row["evidence_tier"],
            "evidence_coverage_pct": row["evidence_coverage_pct"],
            "real_money_state": row["real_money_state"],
            "distribution_risk": row["distribution_risk"],
            "estimated_smart_money_cost": row.get("estimated_smart_money_cost"),
            "premium_to_cost_pct": row.get("premium_to_cost_pct"),
            "entry_low": row.get("entry_low"),
            "entry_high": row.get("entry_high"),
            "invalidation": row.get("invalidation"),
            "tp1": row.get("tp1"),
            "tp2": row.get("tp2"),
            "components": {k: row.get(k) for k in _COMPONENT_FIELDS},
            "diagnostics": row.get("diagnostics", {}),
            "guardrail_reason": row.get("guardrail_reason"),
        }
        records.append(_json_safe(record))
    return records


def install_bounded_result_persistence(store_cls: type[Any], *, batch_size: int = DEFAULT_RESULT_BATCH_SIZE) -> None:
    """Install direct bounded PostgREST persistence for scan results.

    Streamlit hot reload can retain an already monkeypatched class across source
    deployments. Re-wrapping ``store_cls.save_results`` therefore preserves every
    older wrapper underneath the new one. The production symptom was deterministic:
    scoring reached 398/400, but only ten 20-row writes (200 rows) reached Supabase.

    This revision deliberately does *not* delegate to whatever ``save_results``
    method is currently attached to the live class. It reconstructs the canonical
    payload and writes directly with a dedicated Supabase client. That severs the
    retained wrapper chain while preserving the database contract, bounded batches,
    idempotent upserts, JSON safety and truthful fail-closed telemetry.
    """
    if getattr(store_cls, "_flow_bounded_result_persistence_revision", None) == PERSISTENCE_GUARD_REVISION:
        return

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

    def direct_save_results(store: Any, run_id: str, frame: pd.DataFrame) -> None:
        if frame is None or frame.empty:
            return
        records = _result_records(run_id, frame)
        total = len(records)
        persisted_count = 0
        write_client = _get_write_client(store)
        if write_client is None:
            raise RuntimeError("Supabase persistence client unavailable")
        try:
            for start in range(0, total, bounded_size):
                batch = records[start : start + bounded_size]
                write_client.table("flow_scan_results").upsert(
                    batch,
                    on_conflict="run_id,ticker",
                ).execute()
                persisted_count = min(start + len(batch), total)
                _heartbeat(write_client, run_id, persisted_count, total)
        except Exception:
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

    store_cls.save_results = direct_save_results
    store_cls._flow_bounded_result_persistence_installed = True
    store_cls._flow_bounded_result_persistence_revision = PERSISTENCE_GUARD_REVISION
    store_cls._flow_result_persistence_batch_size = bounded_size
