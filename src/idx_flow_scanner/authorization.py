from __future__ import annotations

import json
from typing import Mapping

import pandas as pd


def _diagnostics(value: object) -> dict[str, object]:
    if isinstance(value, dict):
        return value
    if isinstance(value, str) and value.strip():
        try:
            parsed = json.loads(value)
            return parsed if isinstance(parsed, dict) else {}
        except Exception:
            return {}
    return {}


def _is_null_scalar(value: object) -> bool:
    """Recognize nullable scalar sentinels without testing arrays for truthiness."""
    if value is None:
        return True
    if not pd.api.types.is_scalar(value):
        return False
    try:
        return bool(pd.isna(value))
    except (TypeError, ValueError):
        return False


def _normalize_scalar(value: object) -> object:
    return None if _is_null_scalar(value) else value


def _text(value: object, default: str = "") -> str:
    normalized = _normalize_scalar(value)
    return default if normalized is None else str(normalized)


def _value(row: Mapping[str, object], diagnostics: Mapping[str, object], name: str) -> object:
    value = _normalize_scalar(row.get(name))
    if value is None:
        return _normalize_scalar(diagnostics.get(name))
    return value


def derive_production_authorized(row: Mapping[str, object]) -> bool:
    """Prove authorization from all canonical guards; every unknown fails closed."""
    diagnostics = _diagnostics(row.get("diagnostics"))
    provider = _text(_value(row, diagnostics, "foreign_provider_selected"))
    selection = _text(_value(row, diagnostics, "foreign_provider_selection_state"))
    reconciliation = _text(
        _value(row, diagnostics, "foreign_provider_reconciliation_state"), "UNKNOWN"
    )
    window = _text(_value(row, diagnostics, "foreign_window_state"))
    conflict = _value(row, diagnostics, "foreign_provider_conflict")
    foreign_valid = _value(row, diagnostics, "foreign_data_valid")
    foreign_freshness = _text(_value(row, diagnostics, "foreign_data_freshness"))
    broker_valid = _value(row, diagnostics, "broker_data_valid")
    broker_freshness = _text(_value(row, diagnostics, "broker_freshness_state"))
    broker_status = _text(row.get("broker_verification_status")) or _text(
        diagnostics.get("broker_verification_status")
    )
    return bool(
        broker_status == "BROKER_VERIFIED"
        and _text(row.get("evidence_tier")) == "BROKER_DIRECT"
        and _text(row.get("real_money_state")) == "ELIGIBLE"
        and broker_valid is True
        and broker_freshness == "FRESH"
        and provider in {"IDX_DIRECT", "ZAPI"}
        and selection in {"IDX_DIRECT", "ZAPI"}
        and reconciliation in {"AGREED", "SINGLE_PROVIDER"}
        and foreign_valid is True
        and foreign_freshness == "FRESH"
        and window == "FULL"
        and conflict is False
    )


def apply_production_authorization(frame: pd.DataFrame | None) -> pd.DataFrame:
    """Overwrite authorization from the canonical contract and synchronize diagnostics."""
    if frame is None:
        return pd.DataFrame()
    out = frame.copy()
    if out.empty:
        out["production_authorized"] = pd.Series(dtype=bool)
        return out
    authorized = [derive_production_authorized(row) for row in out.to_dict("records")]
    out["production_authorized"] = pd.Series(authorized, index=out.index, dtype=bool)
    if "diagnostics" not in out.columns:
        out["diagnostics"] = [{} for _ in range(len(out))]
    synchronized: list[dict[str, object]] = []
    for value, allowed in zip(out["diagnostics"], authorized):
        diagnostics = dict(_diagnostics(value))
        diagnostics["production_authorized"] = bool(allowed)
        synchronized.append(diagnostics)
    out["diagnostics"] = synchronized
    return out


def export_scan_csv(frame: pd.DataFrame | None) -> bytes:
    """Serialize canonical in-memory authorization without creating an export path.

    Callers pass a canonically authorized result frame. A missing, nullable, or
    non-boolean authorization column is forced to False rather than inferred here.
    """
    authorized = frame.copy() if isinstance(frame, pd.DataFrame) else pd.DataFrame()
    existing = authorized.get("production_authorized")
    if existing is None or not pd.api.types.is_bool_dtype(existing):
        authorized["production_authorized"] = pd.Series(False, index=authorized.index, dtype=bool)
    else:
        authorized["production_authorized"] = existing.fillna(False).astype(bool)
    return authorized.drop(columns=["diagnostics", "components"], errors="ignore").to_csv(
        index=False
    ).encode("utf-8")
