from __future__ import annotations

from dataclasses import dataclass

import pandas as pd


ADAPTIVE_POLICY_TABLE = "flow_research_adaptive_policy_v2"
ADAPTIVE_SNAPSHOT_TABLE = "flow_research_adaptive_snapshot_v2"
ADAPTIVE_OUTCOME_TABLE = "flow_research_adaptive_outcome_v2"


@dataclass(frozen=True)
class AdaptiveResearchBundle:
    policies: pd.DataFrame
    snapshots: pd.DataFrame
    outcomes: pd.DataFrame
    errors: tuple[str, ...] = ()


def _rows(response) -> list[dict]:
    data = getattr(response, "data", None)
    if isinstance(data, list):
        return [row for row in data if isinstance(row, dict)]
    if isinstance(data, dict):
        return [data]
    return []


def _numeric(frame: pd.DataFrame, columns: tuple[str, ...]) -> pd.DataFrame:
    clean = frame.copy()
    for column in columns:
        if column in clean.columns:
            clean[column] = pd.to_numeric(clean[column], errors="coerce")
    return clean


def load_adaptive_policies(store) -> pd.DataFrame:
    if store is None:
        return pd.DataFrame()
    response = (
        store.client.table(ADAPTIVE_POLICY_TABLE)
        .select(
            "router_contract,router_id,display_name,description,sleeve_weights,routing_rules,"
            "historical_evidence,policy_state,production_influence_enabled,frozen_at"
        )
        .eq("production_influence_enabled", False)
        .order("frozen_at", desc=True)
        .execute()
    )
    frame = pd.DataFrame(_rows(response))
    if not frame.empty:
        frame["research_status"] = "RESEARCH ONLY"
    return frame


def load_adaptive_snapshots(store, *, limit: int = 180) -> pd.DataFrame:
    if store is None:
        return pd.DataFrame()
    response = (
        store.client.table(ADAPTIVE_SNAPSHOT_TABLE)
        .select(
            "router_contract,router_id,signal_date,router_state,active_sleeve_count,"
            "active_weight_pct,cash_weight_pct,allocation,captured_at,production_influence_enabled"
        )
        .eq("production_influence_enabled", False)
        .order("signal_date", desc=True)
        .limit(max(1, min(int(limit), 1000)))
        .execute()
    )
    frame = pd.DataFrame(_rows(response))
    if frame.empty:
        return frame
    frame = _numeric(
        frame,
        ("active_sleeve_count", "active_weight_pct", "cash_weight_pct"),
    )
    frame["research_status"] = "RESEARCH ONLY"
    return frame


def load_adaptive_outcomes(store, *, limit: int = 300) -> pd.DataFrame:
    if store is None:
        return pd.DataFrame()
    response = (
        store.client.table(ADAPTIVE_OUTCOME_TABLE)
        .select(
            "router_contract,router_id,signal_date,completion_target_date,maturity_state,"
            "active_sleeve_count,mature_sleeve_count,active_weight_pct,mature_weight_pct,"
            "cash_weight_pct,pending_weight_pct,portfolio_return_pct,portfolio_alpha_vs_ihsg_pct,"
            "weighted_mfe_pct,weighted_mae_pct,sleeve_outcomes,evaluated_at,production_influence_enabled"
        )
        .eq("production_influence_enabled", False)
        .order("signal_date", desc=True)
        .limit(max(1, min(int(limit), 2000)))
        .execute()
    )
    frame = pd.DataFrame(_rows(response))
    if frame.empty:
        return frame
    frame = _numeric(
        frame,
        (
            "active_sleeve_count",
            "mature_sleeve_count",
            "active_weight_pct",
            "mature_weight_pct",
            "cash_weight_pct",
            "pending_weight_pct",
            "portfolio_return_pct",
            "portfolio_alpha_vs_ihsg_pct",
            "weighted_mfe_pct",
            "weighted_mae_pct",
        ),
    )
    frame["research_status"] = "RESEARCH ONLY"
    return frame


def load_adaptive_research_bundle(store) -> AdaptiveResearchBundle:
    errors: list[str] = []
    try:
        policies = load_adaptive_policies(store)
    except Exception as exc:
        policies = pd.DataFrame()
        errors.append(f"adaptive policy: {exc}")

    try:
        snapshots = load_adaptive_snapshots(store)
    except Exception as exc:
        snapshots = pd.DataFrame()
        errors.append(f"adaptive snapshots: {exc}")

    try:
        outcomes = load_adaptive_outcomes(store)
    except Exception as exc:
        outcomes = pd.DataFrame()
        errors.append(f"adaptive outcomes: {exc}")

    return AdaptiveResearchBundle(
        policies=policies,
        snapshots=snapshots,
        outcomes=outcomes,
        errors=tuple(errors),
    )
