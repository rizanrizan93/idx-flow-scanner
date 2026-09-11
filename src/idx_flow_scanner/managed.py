from __future__ import annotations

import hashlib
import math
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

import pandas as pd

from .authorization import apply_production_authorization
from .data import parse_universe


MANAGED_ACTIVE_TIMEOUT_MINUTES = 45


@dataclass(frozen=True)
class ManagedDecision:
    should_run: bool
    reason: str
    blocking_run_id: str | None = None


def universe_signature(universe: list[str]) -> str:
    payload = "\n".join(str(t).strip().upper() for t in universe)
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()[:16]


def load_bundled_universe(path: Path) -> list[str]:
    frame = pd.read_csv(path)
    universe = parse_universe(frame)
    if not universe:
        raise ValueError(f"Bundled universe is empty: {path}")
    return universe


def _parse_time(value: Any) -> datetime | None:
    if value in (None, ""):
        return None
    try:
        ts = pd.Timestamp(value)
        if ts.tzinfo is None:
            ts = ts.tz_localize("UTC")
        return ts.tz_convert("UTC").to_pydatetime()
    except Exception:
        return None


def decide_managed_run(
    runs: list[dict[str, Any]],
    *,
    version: str,
    universe_count: int,
    signature: str,
    now: datetime | None = None,
    active_timeout_minutes: int = MANAGED_ACTIVE_TIMEOUT_MINUTES,
    failure_cooldown_minutes: int = 20,
    success_fresh_hours: int = 12,
    min_success_ratio: float = 0.90,
) -> ManagedDecision:
    """Pure run gate used by Streamlit managed mode and unit tests."""
    now = now or datetime.now(timezone.utc)
    if now.tzinfo is None:
        now = now.replace(tzinfo=timezone.utc)

    managed: list[dict[str, Any]] = []
    for run in runs or []:
        cfg = run.get("config") or {}
        if not isinstance(cfg, dict):
            continue
        if cfg.get("mode") != "managed":
            continue
        if str(cfg.get("version")) != str(version):
            continue
        if int(run.get("universe_count") or 0) != int(universe_count):
            continue
        if str(cfg.get("universe_signature") or "") != str(signature):
            continue
        managed.append(run)

    for run in managed:
        if str(run.get("status") or "").upper() != "RUNNING":
            continue
        heartbeat = _parse_time(run.get("heartbeat_at")) or _parse_time(run.get("started_at"))
        if heartbeat and now - heartbeat <= timedelta(minutes=active_timeout_minutes):
            return ManagedDecision(False, "managed scan already running", str(run.get("id") or ""))

    terminal = [r for r in managed if str(r.get("status") or "").upper() in {"COMPLETED", "COMPLETED_PARTIAL", "FAILED", "CANCELLED"}]
    terminal.sort(key=lambda r: _parse_time(r.get("completed_at")) or _parse_time(r.get("started_at")) or datetime.min.replace(tzinfo=timezone.utc), reverse=True)
    if terminal:
        latest = terminal[0]
        when = _parse_time(latest.get("completed_at")) or _parse_time(latest.get("started_at"))
        status = str(latest.get("status") or "").upper()
        processed = int(latest.get("processed_count") or 0)
        success_ratio = processed / max(int(universe_count), 1)
        if status in {"COMPLETED", "COMPLETED_PARTIAL"} and success_ratio >= float(min_success_ratio):
            if when and now - when <= timedelta(hours=success_fresh_hours):
                return ManagedDecision(False, f"fresh managed scan already valid ({processed}/{universe_count})", str(latest.get("id") or ""))
        if when and now - when <= timedelta(minutes=failure_cooldown_minutes):
            return ManagedDecision(False, f"cooldown after recent {status.lower()} run", str(latest.get("id") or ""))

    return ManagedDecision(True, "managed scan required")


def recent_runs(store: Any, limit: int = 20) -> list[dict[str, Any]]:
    response = (
        store.client.table("flow_scan_runs")
        .select("id,status,universe_count,attempted_count,processed_count,error_count,config,started_at,completed_at,heartbeat_at,current_ticker")
        .order("started_at", desc=True)
        .limit(int(limit))
        .execute()
    )
    return list(response.data or [])


def load_persisted_results(store: Any, run_id: str) -> pd.DataFrame:
    if not run_id:
        return pd.DataFrame()
    response = (
        store.client.table("flow_scan_results")
        .select("*")
        .eq("run_id", run_id)
        .order("final_score", desc=True)
        .limit(500)
        .execute()
    )
    frame = pd.DataFrame(response.data or [])
    if frame.empty:
        return frame
    component_names = (
        "accumulation_score", "operator_dominance_score", "cost_basis_score",
        "retail_exhaustion_score", "foreign_institutional_score",
        "supply_concentration_score", "price_flow_divergence_score",
        "market_context_score", "smc_execution_score", "risk_liquidity_score",
        "price_data_quality_score",
    )
    for name in component_names:
        frame[name] = frame["components"].map(lambda value: (value or {}).get(name) if isinstance(value, dict) else None)
    return apply_production_authorization(frame)


def _rpc_integer(value: Any) -> int:
    if isinstance(value, list) and len(value) == 1:
        value = value[0]
    if isinstance(value, dict):
        if len(value) == 1:
            value = next(iter(value.values()))
        else:
            raise ValueError("ambiguous RPC response")
    return int(value or 0)


def _persisted_result_count(store: Any, run_id: str) -> int:
    response = (
        store.client.table("flow_scan_results")
        .select("ticker", count="exact")
        .eq("run_id", run_id)
        .execute()
    )
    count = getattr(response, "count", None)
    if count is None:
        raise RuntimeError("exact persisted-result count unavailable")
    return int(count)


def mark_stale_managed_runs(store: Any, *, max_age_minutes: int = MANAGED_ACTIVE_TIMEOUT_MINUTES) -> int:
    """Finalize clearly stale RUNNING rows without discarding persisted truth.

    Canonical recovery is server-side and result-aware: a fully attempted run with
    >=90% persisted result rows is terminally reconciled as COMPLETED or
    COMPLETED_PARTIAL. Only stale runs without sufficient persisted evidence fail.
    The client fallback mirrors the same rule for deployments where the RPC has not
    reached the runtime yet.
    """
    effective_age_minutes = min(max(1, int(max_age_minutes)), MANAGED_ACTIVE_TIMEOUT_MINUTES)

    try:
        response = store.client.rpc(
            "flow_reap_stale_scan_runs",
            {"p_max_age_minutes": effective_age_minutes},
        ).execute()
        return _rpc_integer(response.data)
    except Exception:
        pass

    rows = recent_runs(store, limit=100)
    cutoff = datetime.now(timezone.utc) - timedelta(minutes=effective_age_minutes)
    changed = 0
    for run in rows:
        if str(run.get("status") or "").upper() != "RUNNING":
            continue
        heartbeat = _parse_time(run.get("heartbeat_at")) or _parse_time(run.get("started_at"))
        if heartbeat is None or heartbeat >= cutoff:
            continue

        run_id = str(run.get("id") or "")
        universe_count = int(run.get("universe_count") or 0)
        attempted_count = int(run.get("attempted_count") or 0)
        try:
            result_count = _persisted_result_count(store, run_id)
        except Exception:
            result_count = 0

        required = int(math.ceil(0.90 * max(universe_count, 0)))
        recovered = bool(
            universe_count > 0
            and attempted_count >= universe_count
            and result_count >= required
        )
        now_iso = datetime.now(timezone.utc).isoformat()
        config = run.get("config") if isinstance(run.get("config"), dict) else {}
        if recovered:
            terminal_status = "COMPLETED" if result_count >= universe_count else "COMPLETED_PARTIAL"
            payload = {
                "status": terminal_status,
                "processed_count": result_count,
                "error_count": max(int(run.get("error_count") or 0), max(universe_count - result_count, 0)),
                "completed_at": now_iso,
                "current_ticker": None,
                "config": {
                    **config,
                    "stale_recovery_reason": "PERSISTED_RESULTS_PROVE_SCAN_COMPLETION",
                    "stale_recovered_at": now_iso,
                    "stale_max_age_minutes": effective_age_minutes,
                    "stale_recovered_result_rows": result_count,
                    "stale_recovered_status": terminal_status,
                },
            }
        else:
            payload = {
                "status": "FAILED",
                "completed_at": now_iso,
                "current_ticker": None,
                "error_count": max(int(run.get("error_count") or 0), 1),
                "config": {
                    **config,
                    "stale_failure_reason": "CLIENT_STALE_HEARTBEAT",
                    "stale_reaped_at": now_iso,
                    "stale_max_age_minutes": effective_age_minutes,
                    "stale_observed_result_rows": result_count,
                },
            }
        try:
            store.client.table("flow_scan_runs").update(payload).eq("id", run_id).execute()
            changed += 1
        except Exception:
            pass
    return changed
