from __future__ import annotations

import json

import numpy as np
import pandas as pd

VERIFIED_FLOW_TIERS = frozenset({"OFFICIAL_IDX_FLOW", "ZAPI_FLOW"})
EXECUTION_ACTIONS = frozenset({"BUY_ON_WEAKNESS", "BUY_RETEST"})


def _diag(value: object) -> dict[str, object]:
    if isinstance(value, dict):
        return value
    if isinstance(value, str) and value.strip():
        try:
            parsed = json.loads(value)
            return parsed if isinstance(parsed, dict) else {}
        except Exception:
            return {}
    return {}


def _true_bool(value: object) -> bool:
    return isinstance(value, (bool, np.bool_)) and bool(value)


def select_zapi_decision_top(results: pd.DataFrame, *, top_n: int = 20) -> pd.DataFrame:
    """Select verified-flow decision candidates.

    The historical function name is retained for API compatibility. Both the
    authoritative official IDX tier and the verified ZAPI fallback tier must
    still pass the same FULL/FRESH/VALID quality gates.
    """
    if results is None or results.empty or top_n <= 0:
        return pd.DataFrame()
    work = results.copy()
    if "diagnostics" not in work.columns:
        work["diagnostics"] = [{} for _ in range(len(work))]
    for name, default in (
        ("foreign_window_state", "UNKNOWN"),
        ("foreign_data_freshness", "UNKNOWN"),
        ("foreign_data_valid", False),
    ):
        work[name] = work["diagnostics"].map(
            lambda value, key=name, d=default: _diag(value).get(key, d)
        )
    dist = pd.to_numeric(work.get("distribution_risk"), errors="coerce").fillna(100.0)
    quality = pd.to_numeric(
        work.get("price_data_quality_score"), errors="coerce"
    ).fillna(0.0)
    evidence_tier = work.get("evidence_tier", pd.Series("", index=work.index))
    gate = (
        evidence_tier.isin(VERIFIED_FLOW_TIERS)
        & work["foreign_window_state"].eq("FULL")
        & work["foreign_data_freshness"].eq("FRESH")
        & work["foreign_data_valid"].map(_true_bool)
        & dist.lt(70.0)
        & quality.ge(70.0)
        & work.get("phase", pd.Series("", index=work.index)).ne("DISTRIBUTION")
        & work.get("action", pd.Series("", index=work.index)).ne("REDUCE_AVOID")
    )
    out = work.loc[gate].copy()
    if out.empty:
        return out
    for col in (
        "final_score",
        "accumulation_score",
        "foreign_institutional_score",
        "market_context_score",
        "smc_execution_score",
    ):
        out[col] = pd.to_numeric(out.get(col), errors="coerce").fillna(0.0)
    out = out.sort_values(
        [
            "final_score",
            "accumulation_score",
            "foreign_institutional_score",
            "market_context_score",
            "smc_execution_score",
            "ticker",
        ],
        ascending=[False, False, False, False, False, True],
        kind="stable",
    ).head(int(top_n)).reset_index(drop=True)
    out["decision_rank"] = range(1, len(out) + 1)
    return out


def select_execution_ready(results: pd.DataFrame, *, top_n: int = 10) -> pd.DataFrame:
    """Return only production-authorized rows with an actionable BUY signal.

    `production_authorized=True` means all hard evidence/execution guardrails pass.
    It does not by itself turn a WATCHLIST/HOLD row into an executable order. The
    execution-ready lane is therefore the strict intersection of authorization and
    the scanner's explicit BUY actions.
    """
    if results is None or results.empty or top_n <= 0:
        return pd.DataFrame()
    authorized = results.get(
        "production_authorized", pd.Series(False, index=results.index)
    )
    if not pd.api.types.is_bool_dtype(authorized):
        authorized = authorized.map(_true_bool)
    actions = results.get("action", pd.Series("", index=results.index)).astype(str)
    gate = authorized.fillna(False) & actions.isin(EXECUTION_ACTIONS)
    out = results.loc[gate].copy()
    if out.empty:
        return out
    out = out.sort_values(
        ["final_score", "ticker"],
        ascending=[False, True],
        kind="stable",
    ).head(int(top_n)).reset_index(drop=True)
    out["execution_rank"] = range(1, len(out) + 1)
    return out
