from __future__ import annotations

from typing import Any, Callable, Mapping

import numpy as np
import pandas as pd

from .broker_behavior import compute_broker_market_regime, compute_ticker_broker_consensus

BROKER_BEHAVIOR_OVERLAY_WEIGHT = 0.08

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


def verified_daily_foreign_ready(ff: Mapping[str, object]) -> bool:
    provider = str(ff.get("foreign_provider_selected") or "")
    selection = str(ff.get("foreign_provider_selection_state") or "")
    return bool(
        ff.get("foreign_data_valid") is True
        and provider in {"IDX_DIRECT", "ZAPI"}
        and selection in {"IDX_DIRECT", "ZAPI"}
        and str(ff.get("foreign_provider_reconciliation_state") or "") in {"SINGLE_PROVIDER", "AGREED"}
        and str(ff.get("foreign_window_state") or "") == "FULL"
        and str(ff.get("foreign_data_freshness") or "") == "FRESH"
        and ff.get("foreign_provider_conflict") is False
    )


def apply_broker_behavior_overlay(
    original_scan_one: Callable[..., Any],
    ticker: str,
    price: pd.DataFrame,
    **kwargs: object,
):
    result = original_scan_one(ticker, price, **kwargs)
    diagnostics = result.diagnostics if isinstance(result.diagnostics, dict) else {}
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
    result.final_score = round(float(np.clip(base_score + adjustment, 0.0, 100.0)), 2)

    result.diagnostics = {
        **diagnostics,
        **broker,
        "base_score_pre_broker_behavior": round(base_score, 2),
        "broker_behavior_overlay_weight": BROKER_BEHAVIOR_OVERLAY_WEIGHT,
        "broker_behavior_score_adjustment": round(float(adjustment), 4),
        "broker_behavior_affects_ranking": True,
        "broker_behavior_can_override_hard_gates": False,
        "scoring_lineage_state": (
            str(diagnostics.get("scoring_lineage_state") or "")
            + "__IDX_BROKER_BEHAVIOR_V1"
        ).strip("_"),
    }
    return result
