from __future__ import annotations

from typing import Any, Callable, Mapping

import numpy as np
import pandas as pd

from .broker_behavior import compute_broker_market_regime, compute_ticker_broker_consensus

BROKER_BEHAVIOR_OVERLAY_WEIGHT = 0.08
OFFICIAL_IDX_FLOW_TIER = "OFFICIAL_IDX_FLOW"
ZAPI_FLOW_TIER = "ZAPI_FLOW"

_broker_regime: dict[str, object] = compute_broker_market_regime(pd.DataFrame())


def set_broker_activity_context(
    activity: pd.DataFrame | None,
    *,
    reference_date: str | pd.Timestamp | None = None,
) -> dict[str, object]:
    global _broker_regime
    _broker_regime = compute_broker_market_regime(
        activity,
        reference_date=reference_date,
    )
    return dict(_broker_regime)


def get_broker_activity_context() -> dict[str, object]:
    return dict(_broker_regime)


def _strict_bool(value: object, expected: bool) -> bool:
    """Accept Python/numpy booleans without treating strings as truth values."""
    if not isinstance(value, (bool, np.bool_)):
        return False
    return bool(value) is expected


def verified_daily_foreign_ready(ff: Mapping[str, object]) -> bool:
    """Authorize either official IDX direct flow or the verified ZAPI fallback.

    The selected provider must match its selection state and still satisfy the
    same FULL/FRESH/VALID/no-conflict contract. Official IDX is not allowed to
    bypass any execution guardrail merely because it has higher source authority.
    """
    provider = str(ff.get("foreign_provider_selected") or "")
    selection = str(ff.get("foreign_provider_selection_state") or "")
    return bool(
        _strict_bool(ff.get("foreign_data_valid"), True)
        and provider in {"IDX_DIRECT", "ZAPI"}
        and selection == provider
        and str(ff.get("foreign_provider_reconciliation_state") or "")
        in {"SINGLE_PROVIDER", "AGREED"}
        and str(ff.get("foreign_window_state") or "") == "FULL"
        and str(ff.get("foreign_data_freshness") or "") == "FRESH"
        and _strict_bool(ff.get("foreign_provider_conflict"), False)
    )


def _foreign_evidence_tier(diagnostics: Mapping[str, object]) -> str | None:
    if not verified_daily_foreign_ready(diagnostics):
        return None
    provider = str(diagnostics.get("foreign_provider_selected") or "")
    if provider == "IDX_DIRECT":
        return OFFICIAL_IDX_FLOW_TIER
    if provider == "ZAPI":
        return ZAPI_FLOW_TIER
    return None


def apply_broker_behavior_overlay(
    original_scan_one: Callable[..., Any],
    ticker: str,
    price: pd.DataFrame,
    **kwargs: object,
):
    result = original_scan_one(ticker, price, **kwargs)
    diagnostics = result.diagnostics if isinstance(result.diagnostics, dict) else {}

    # The core scan function historically named the verified-flow lane ZAPI_FLOW.
    # Normalize the persisted tier to its actual selected provider so provenance
    # remains explicit after IDX direct became authoritative.
    evidence_tier = _foreign_evidence_tier(diagnostics)
    if evidence_tier is not None:
        result.evidence_tier = evidence_tier

    if isinstance(result.guardrail_reason, str):
        result.guardrail_reason = (
            result.guardrail_reason
            .replace(
                "ZAPI foreign-flow evidence not FULL/FRESH/VALID",
                "verified foreign-flow evidence not FULL/FRESH/VALID",
            )
            .replace("ZAPI coverage", "foreign-flow coverage")
            .replace(
                "ZAPI + price/SMC + slow-evidence gates passed",
                "verified foreign flow + price/SMC + slow-evidence gates passed",
            )
        )

    foreign_features = {
        "foreign_institutional_score": result.foreign_institutional_score,
    }
    price_features = {
        "proxy_accumulation_score": diagnostics.get(
            "proxy_accumulation_score", result.accumulation_score
        ),
        "proxy_absorption_score": diagnostics.get(
            "proxy_absorption_score", result.operator_dominance_score
        ),
    }
    broker = compute_ticker_broker_consensus(
        ticker,
        price,
        foreign_features,
        price_features,
        _broker_regime,
    )
    consensus = float(broker.get("broker_behavior_consensus_score", 50.0) or 50.0)
    base_score = float(result.final_score)
    adjustment = BROKER_BEHAVIOR_OVERLAY_WEIGHT * (consensus - 50.0)
    result.final_score = round(
        float(np.clip(base_score + adjustment, 0.0, 100.0)), 2
    )

    provider = str(diagnostics.get("foreign_provider_selected") or "")
    result.diagnostics = {
        **diagnostics,
        **broker,
        "zapi_primary_mode": provider == "ZAPI",
        "official_idx_primary_mode": provider == "IDX_DIRECT",
        "foreign_provider_policy": "IDX_OFFICIAL_FIRST__ZAPI_FALLBACK",
        "foreign_evidence_tier": result.evidence_tier,
        "base_score_pre_broker_behavior": round(base_score, 2),
        "broker_behavior_overlay_weight": BROKER_BEHAVIOR_OVERLAY_WEIGHT,
        "broker_behavior_score_adjustment": round(float(adjustment), 4),
        "broker_behavior_affects_ranking": True,
        "broker_behavior_can_override_hard_gates": False,
        "scoring_lineage_state": (
            "VERIFIED_FOREIGN_FLOW__OHLCV_LATENT__SECTOR__SLOW_EVIDENCE_V2"
            "__IDX_BROKER_BEHAVIOR_V1"
        ),
    }
    return result
