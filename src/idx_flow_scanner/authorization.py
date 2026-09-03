from __future__ import annotations

import json
from typing import Mapping

import numpy as np
import pandas as pd

from .config import ZapiFlowConfig


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


def _value(
    row: Mapping[str, object],
    diagnostics: Mapping[str, object],
    name: str,
) -> object:
    value = _normalize_scalar(row.get(name))
    if value is None:
        return _normalize_scalar(diagnostics.get(name))
    return value


def _text(
    row: Mapping[str, object],
    diagnostics: Mapping[str, object],
    name: str,
    default: str = "",
) -> str:
    value = _value(row, diagnostics, name)
    return default if value is None else str(value)


def _number(
    row: Mapping[str, object],
    diagnostics: Mapping[str, object],
    name: str,
) -> float | None:
    value = pd.to_numeric(_value(row, diagnostics, name), errors="coerce")
    if pd.isna(value) or not np.isfinite(float(value)):
        return None
    return float(value)


def derive_production_authorized(
    row: Mapping[str, object],
    config: ZapiFlowConfig | None = None,
) -> bool:
    """Re-prove v0.4 authorization from ZAPI + execution evidence.

    Unknown or malformed evidence fails closed. Legacy BROKER_DIRECT rows can
    remain in historical storage but can never be re-authorized by this contract.
    """
    config = config or ZapiFlowConfig()
    diagnostics = _diagnostics(row.get("diagnostics"))

    evidence_tier = _text(row, diagnostics, "evidence_tier")
    state = _text(row, diagnostics, "real_money_state")
    provider = _text(row, diagnostics, "foreign_provider_selected")
    selection = _text(row, diagnostics, "foreign_provider_selection_state")
    reconciliation = _text(
        row,
        diagnostics,
        "foreign_provider_reconciliation_state",
        "UNKNOWN",
    )
    window = _text(row, diagnostics, "foreign_window_state")
    freshness = _text(row, diagnostics, "foreign_data_freshness")
    conflict = _value(row, diagnostics, "foreign_provider_conflict")
    foreign_valid = _value(row, diagnostics, "foreign_data_valid")

    coverage = _number(row, diagnostics, "foreign_evidence_coverage_pct")
    if coverage is None:
        ratio = _number(row, diagnostics, "foreign_window_coverage_ratio")
        coverage = ratio * 100.0 if ratio is not None else None

    score = _number(row, diagnostics, "final_score")
    distribution = _number(row, diagnostics, "distribution_risk")
    price_quality = _number(row, diagnostics, "price_data_quality_score")
    staleness = _number(row, diagnostics, "price_staleness_days")

    execution_geometry = _value(row, diagnostics, "execution_geometry_valid")
    execution_tradeable = _value(row, diagnostics, "execution_levels_tradeable")
    entry_in_band = _value(
        row,
        diagnostics,
        "entry_within_next_session_price_band",
    )

    free_float = _number(row, diagnostics, "free_float_pct")
    slow_block = _value(row, diagnostics, "slow_evidence_hard_block")
    phase = _text(row, diagnostics, "phase")
    action = _text(row, diagnostics, "action")

    return bool(
        evidence_tier == "ZAPI_FLOW"
        and state == "ELIGIBLE"
        and provider == "ZAPI"
        and selection == "ZAPI"
        and reconciliation in {"AGREED", "SINGLE_PROVIDER"}
        and window == "FULL"
        and freshness == "FRESH"
        and foreign_valid is True
        and conflict is False
        and coverage is not None
        and coverage >= config.minimum_foreign_coverage_pct
        and score is not None
        and score >= config.decision_score_floor
        and distribution is not None
        and distribution < config.max_distribution_risk
        and price_quality is not None
        and price_quality >= config.minimum_price_quality_score
        and staleness is not None
        and staleness <= config.max_price_staleness_days
        and execution_geometry is True
        and execution_tradeable is True
        and entry_in_band is True
        and (
            free_float is None
            or free_float >= config.extreme_low_free_float_pct
        )
        and slow_block is not True
        and phase != "DISTRIBUTION"
        and action != "REDUCE_AVOID"
    )


def apply_production_authorization(
    frame: pd.DataFrame | None,
    config: ZapiFlowConfig | None = None,
) -> pd.DataFrame:
    if frame is None:
        return pd.DataFrame()
    out = frame.copy()
    if out.empty:
        out["production_authorized"] = pd.Series(dtype=bool)
        return out

    config = config or ZapiFlowConfig()
    authorized = [
        derive_production_authorized(row, config)
        for row in out.to_dict("records")
    ]
    out["production_authorized"] = pd.Series(
        authorized,
        index=out.index,
        dtype=bool,
    )

    if "diagnostics" not in out.columns:
        out["diagnostics"] = [{} for _ in range(len(out))]
    synchronized: list[dict[str, object]] = []
    for value, allowed in zip(out["diagnostics"], authorized):
        diagnostics = dict(_diagnostics(value))
        diagnostics["production_authorized"] = bool(allowed)
        diagnostics["authorization_contract"] = "ZAPI_FLOW_V0_4"
        synchronized.append(diagnostics)
    out["diagnostics"] = synchronized
    return out


def export_scan_csv(frame: pd.DataFrame | None) -> bytes:
    """Export results with authorization re-proved at the serialization boundary."""
    authorized = apply_production_authorization(frame)
    return authorized.drop(
        columns=["diagnostics", "components"],
        errors="ignore",
    ).to_csv(index=False).encode("utf-8")
