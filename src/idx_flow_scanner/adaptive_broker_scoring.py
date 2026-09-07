from __future__ import annotations

from dataclasses import dataclass
from datetime import date
from typing import Any, Callable, Mapping

import numpy as np


MODEL_KEY = "ADVANCED_BROKER_ABC_V1"
DEFAULT_FAMILY_BUDGET = 0.08
DEFAULT_ADVANCED_WEIGHT = 0.02
DEFAULT_MAX_ADVANCED_WEIGHT = 0.06


@dataclass(frozen=True)
class AdaptiveBrokerState:
    family_budget: float = DEFAULT_FAMILY_BUDGET
    advanced_weight: float = DEFAULT_ADVANCED_WEIGHT
    max_advanced_weight: float = DEFAULT_MAX_ADVANCED_WEIGHT
    calibration_status: str = "BOOTSTRAP"
    last_calibrated_date: str | None = None


_context: dict[str, Any] = {
    "ready": False,
    "reason": "NOT_LOADED",
    "as_of_date": None,
    "state": AdaptiveBrokerState(),
    "tickers": {},
}


def _float(value: object, default: float = 0.0) -> float:
    try:
        number = float(value)
    except (TypeError, ValueError):
        return float(default)
    return number if np.isfinite(number) else float(default)


def _int(value: object, default: int = 0) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        return int(default)


def _bool(value: object) -> bool:
    return isinstance(value, (bool, np.bool_)) and bool(value)


def _clamp(value: float, low: float, high: float) -> float:
    return float(np.clip(float(value), float(low), float(high)))


def compute_advanced_evidence_score(
    phase3b: Mapping[str, object] | None,
    phase3c: Mapping[str, object] | None,
) -> dict[str, object]:
    """Build a positive-only 3A/3B/3C support score.

    Absence of statistical affinity is neutral, not bearish. The existing risk,
    distribution, suspension, dilution, geometry and authorization layers retain
    their negative/hard-gate semantics.

    Phase 3A is represented by the active-broker affinity quality aggregated in
    the Phase 3B row. Phase 3C is already member-reliability adjusted and is
    additionally activation-weighted before it can affect production ranking.
    """

    b = dict(phase3b or {})
    c = dict(phase3c or {})

    affinity_count = _int(b.get("affinity_active_broker_count"))
    affinity_quality = _clamp(_float(b.get("weighted_affinity_score")), 0.0, 100.0)
    consensus_reliability = _clamp(
        _float(b.get("consensus_reliability_factor"), 0.0), 0.0, 1.0
    )
    phase3b_score = _clamp(
        _float(b.get("broker_consensus_proxy_score")), 0.0, 100.0
    )
    breadth_state = str(b.get("breadth_state") or "NONE").upper()

    phase3a_eligible = bool(
        _bool(b.get("source_verified"))
        and affinity_count >= 3
        and affinity_quality >= 65.0
        and consensus_reliability >= 0.60
    )
    phase3b_eligible = bool(
        _bool(b.get("source_verified"))
        and breadth_state in {"STRONG", "BROAD"}
        and phase3b_score >= 45.0
    )

    phase3c_score = _clamp(_float(c.get("effective_profile_score")), 0.0, 100.0)
    phase3c_eligible = bool(
        _bool(c.get("source_verified")) and phase3c_score >= 50.0
    )

    phase3a_support = (
        (affinity_quality / 100.0) * consensus_reliability
        if phase3a_eligible
        else 0.0
    )
    phase3b_support = phase3b_score / 100.0 if phase3b_eligible else 0.0
    phase3c_support = phase3c_score / 100.0 if phase3c_eligible else 0.0

    support = _clamp(
        0.25 * phase3a_support
        + 0.50 * phase3b_support
        + 0.25 * phase3c_support,
        0.0,
        1.0,
    )
    score = 50.0 + 50.0 * support
    eligible_layers = int(phase3a_eligible) + int(phase3b_eligible) + int(phase3c_eligible)

    return {
        "phase3a_score": round(affinity_quality, 4),
        "phase3a_eligible": phase3a_eligible,
        "phase3b_score": round(phase3b_score, 4),
        "phase3b_eligible": phase3b_eligible,
        "phase3c_score": round(phase3c_score, 4),
        "phase3c_eligible": phase3c_eligible,
        "advanced_broker_evidence_layer_count": eligible_layers,
        "advanced_broker_support": round(support, 6),
        "advanced_broker_score": round(score, 4),
        "advanced_broker_evidence_eligible": eligible_layers > 0,
    }


def _paged_rows(
    client: Any,
    table: str,
    fields: str,
    *,
    as_of_date: str,
    page_size: int = 500,
) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    start = 0
    while True:
        response = (
            client.table(table)
            .select(fields)
            .eq("as_of_date", as_of_date)
            .range(start, start + page_size - 1)
            .execute()
        )
        batch = list(getattr(response, "data", None) or [])
        rows.extend(batch)
        if len(batch) < page_size:
            break
        start += page_size
    return rows


def _load_state(client: Any) -> AdaptiveBrokerState:
    try:
        response = (
            client.table("flow_broker_adaptive_calibration_state")
            .select(
                "model_key,family_budget,advanced_weight,max_advanced_weight,"
                "calibration_status,last_calibrated_date"
            )
            .eq("model_key", MODEL_KEY)
            .limit(1)
            .execute()
        )
        rows = list(getattr(response, "data", None) or [])
        if not rows:
            return AdaptiveBrokerState()
        row = rows[0]
        family = _clamp(_float(row.get("family_budget"), DEFAULT_FAMILY_BUDGET), 0.0, 0.20)
        max_advanced = _clamp(
            _float(row.get("max_advanced_weight"), DEFAULT_MAX_ADVANCED_WEIGHT),
            0.0,
            family,
        )
        advanced = _clamp(
            _float(row.get("advanced_weight"), DEFAULT_ADVANCED_WEIGHT),
            0.0,
            max_advanced,
        )
        return AdaptiveBrokerState(
            family_budget=family,
            advanced_weight=advanced,
            max_advanced_weight=max_advanced,
            calibration_status=str(row.get("calibration_status") or "BOOTSTRAP"),
            last_calibrated_date=(
                str(row.get("last_calibrated_date"))
                if row.get("last_calibrated_date")
                else None
            ),
        )
    except Exception:
        return AdaptiveBrokerState()


def load_adaptive_broker_context(store: Any, tickers: list[str] | None = None) -> dict[str, Any]:
    """Load one bounded production-scoring snapshot before a universe scan.

    The layer fails closed to the existing V1 8% broker behavior if Phase 3B/3C
    are missing, stale relative to each other, or their quality gates are not READY.
    """

    if store is None or getattr(store, "client", None) is None:
        return {
            "ready": False,
            "reason": "STORE_UNAVAILABLE",
            "as_of_date": None,
            "state": AdaptiveBrokerState(),
            "tickers": {},
        }

    client = store.client
    state = _load_state(client)
    try:
        b_gate_resp = (
            client.table("flow_phase3b_quality_summary")
            .select("phase3b_gate_state,as_of_date")
            .limit(1)
            .execute()
        )
        c_gate_resp = (
            client.table("flow_phase3c_quality_summary")
            .select("phase3c_gate_state,as_of_date")
            .limit(1)
            .execute()
        )
        b_rows = list(getattr(b_gate_resp, "data", None) or [])
        c_rows = list(getattr(c_gate_resp, "data", None) or [])
        if not b_rows or not c_rows:
            raise RuntimeError("quality gate unavailable")
        b_gate, c_gate = b_rows[0], c_rows[0]
        b_date = str(b_gate.get("as_of_date") or "")
        c_date = str(c_gate.get("as_of_date") or "")
        if str(b_gate.get("phase3b_gate_state") or "") != "PHASE3B_READY":
            raise RuntimeError("PHASE3B_NOT_READY")
        if str(c_gate.get("phase3c_gate_state") or "") != "PHASE3C_READY":
            raise RuntimeError("PHASE3C_NOT_READY")
        if not b_date or b_date != c_date:
            raise RuntimeError("PHASE3B_PHASE3C_DATE_MISMATCH")
        as_of = b_date

        b_data = _paged_rows(
            client,
            "flow_ticker_affinity_consensus_v3",
            "ticker,affinity_active_broker_count,weighted_affinity_score,"
            "broker_consensus_proxy_score,breadth_state,consensus_reliability_factor,"
            "source_verified",
            as_of_date=as_of,
        )
        coalition_data = _paged_rows(
            client,
            "flow_broker_coalitions_v3",
            "coalition_id,activation_state,structure_class,source_verified",
            as_of_date=as_of,
        )
        profile_data = _paged_rows(
            client,
            "flow_broker_coalition_ticker_affinity_v3",
            "coalition_id,ticker,coalition_ticker_profile_score,affinity_member_count,"
            "member_reliability_factor,source_verified",
            as_of_date=as_of,
        )
    except Exception as exc:
        return {
            "ready": False,
            "reason": str(exc)[:120] or type(exc).__name__,
            "as_of_date": None,
            "state": state,
            "tickers": {},
        }

    allowed = {str(t).strip().upper() for t in (tickers or []) if str(t).strip()}
    b_by_ticker = {
        str(row.get("ticker") or "").upper(): row
        for row in b_data
        if row.get("ticker") and (not allowed or str(row.get("ticker")).upper() in allowed)
    }
    coalitions = {
        str(row.get("coalition_id")): row
        for row in coalition_data
        if row.get("coalition_id")
    }

    c_by_ticker: dict[str, dict[str, Any]] = {}
    activation_factor = {"BROAD_ACTIVE": 1.0, "PARTIAL": 0.50, "DORMANT": 0.0}
    for row in profile_data:
        ticker = str(row.get("ticker") or "").upper()
        if not ticker or (allowed and ticker not in allowed):
            continue
        coalition = coalitions.get(str(row.get("coalition_id"))) or {}
        if not (_bool(row.get("source_verified")) and _bool(coalition.get("source_verified"))):
            continue
        activation = str(coalition.get("activation_state") or "DORMANT").upper()
        factor = activation_factor.get(activation, 0.0)
        effective = _clamp(
            _float(row.get("coalition_ticker_profile_score")) * factor,
            0.0,
            100.0,
        )
        current = c_by_ticker.get(ticker)
        if current is None or effective > _float(current.get("effective_profile_score")):
            c_by_ticker[ticker] = {
                "effective_profile_score": effective,
                "raw_profile_score": _clamp(
                    _float(row.get("coalition_ticker_profile_score")), 0.0, 100.0
                ),
                "coalition_id": row.get("coalition_id"),
                "activation_state": activation,
                "structure_class": coalition.get("structure_class"),
                "affinity_member_count": _int(row.get("affinity_member_count")),
                "member_reliability_factor": _clamp(
                    _float(row.get("member_reliability_factor")), 0.0, 1.0
                ),
                "source_verified": True,
            }

    names = allowed or (set(b_by_ticker) | set(c_by_ticker))
    ticker_context: dict[str, dict[str, Any]] = {}
    for ticker in names:
        b = b_by_ticker.get(ticker, {})
        c = c_by_ticker.get(ticker, {})
        ticker_context[ticker] = {
            "phase3b": b,
            "phase3c": c,
            **compute_advanced_evidence_score(b, c),
        }

    return {
        "ready": True,
        "reason": "PHASE3B_PHASE3C_READY",
        "as_of_date": as_of,
        "state": state,
        "tickers": ticker_context,
    }


def set_adaptive_broker_context(context: Mapping[str, object] | None) -> dict[str, Any]:
    global _context
    raw = dict(context or {})
    state = raw.get("state")
    if not isinstance(state, AdaptiveBrokerState):
        state = AdaptiveBrokerState()
    _context = {
        "ready": bool(raw.get("ready")),
        "reason": str(raw.get("reason") or "UNKNOWN"),
        "as_of_date": raw.get("as_of_date"),
        "state": state,
        "tickers": dict(raw.get("tickers") or {}),
    }
    return get_adaptive_broker_context()


def get_adaptive_broker_context() -> dict[str, Any]:
    return {
        "ready": bool(_context.get("ready")),
        "reason": str(_context.get("reason") or "UNKNOWN"),
        "as_of_date": _context.get("as_of_date"),
        "state": _context.get("state"),
        "tickers": dict(_context.get("tickers") or {}),
    }


def apply_adaptive_broker_overlay(
    original_scan_one: Callable[..., Any],
    ticker: str,
    price: Any,
    **kwargs: object,
):
    """Re-budget the existing 8% broker family and apply adaptive 3A/3B/3C boost.

    The advanced layer is ranking-only. It cannot change execution geometry,
    suspension/dilution/risk gates, evidence validity, or production authorization.
    """

    result = original_scan_one(ticker, price, **kwargs)
    diagnostics = result.diagnostics if isinstance(result.diagnostics, dict) else {}
    context_ready = bool(_context.get("ready"))
    state = _context.get("state")
    if not isinstance(state, AdaptiveBrokerState):
        state = AdaptiveBrokerState()

    ticker_key = str(ticker or "").strip().upper()
    evidence = dict((_context.get("tickers") or {}).get(ticker_key) or {})
    eligible = bool(evidence.get("advanced_broker_evidence_eligible")) and context_ready

    family_budget = _clamp(state.family_budget, 0.0, 0.20)
    configured_advanced_weight = _clamp(
        state.advanced_weight, 0.0, min(state.max_advanced_weight, family_budget)
    )
    applied_advanced_weight = configured_advanced_weight if eligible else 0.0
    applied_v1_weight = max(family_budget - applied_advanced_weight, 0.0)

    consensus = _clamp(
        _float(diagnostics.get("broker_behavior_consensus_score"), 50.0), 0.0, 100.0
    )
    old_adjustment = _float(diagnostics.get("broker_behavior_score_adjustment"), 0.0)
    base_pre_family = _float(
        diagnostics.get("base_score_pre_broker_behavior"),
        _float(result.final_score) - old_adjustment,
    )
    v1_adjustment = applied_v1_weight * (consensus - 50.0)
    advanced_score = _clamp(
        _float(evidence.get("advanced_broker_score"), 50.0), 50.0, 100.0
    )
    advanced_adjustment = applied_advanced_weight * (advanced_score - 50.0)
    family_adjustment = v1_adjustment + advanced_adjustment

    result.final_score = round(
        _clamp(base_pre_family + family_adjustment, 0.0, 100.0), 2
    )
    result.diagnostics = {
        **diagnostics,
        **evidence,
        "adaptive_broker_layer_loaded": context_ready,
        "adaptive_broker_context_reason": str(_context.get("reason") or "UNKNOWN"),
        "adaptive_broker_evidence_as_of_date": _context.get("as_of_date"),
        "advanced_broker_scoring_applied": eligible,
        "broker_family_budget": round(family_budget, 6),
        "broker_v1_weight_effective": round(applied_v1_weight, 6),
        "advanced_broker_weight_configured": round(configured_advanced_weight, 6),
        "advanced_broker_weight_effective": round(applied_advanced_weight, 6),
        "base_score_pre_broker_family": round(base_pre_family, 4),
        "broker_v1_score_adjustment_effective": round(v1_adjustment, 6),
        "advanced_broker_score_adjustment": round(advanced_adjustment, 6),
        "broker_family_score_adjustment": round(family_adjustment, 6),
        "adaptive_broker_calibration_status": state.calibration_status,
        "adaptive_broker_last_calibrated_date": state.last_calibrated_date,
        "adaptive_broker_can_override_hard_gates": False,
        "advanced_broker_semantics": "STATISTICAL_CO_ACTIVITY_EVIDENCE_NOT_BUY_SELL",
        "advanced_broker_score_formula": "25_P3A__50_P3B__25_ACTIVATED_P3C__BOOST_ONLY",
        "scoring_lineage_state": (
            "VERIFIED_FOREIGN_FLOW__OHLCV_LATENT__SECTOR__SLOW_EVIDENCE_V2"
            "__IDX_BROKER_FAMILY_ADAPTIVE_ABC_V1"
        ),
    }
    return result
