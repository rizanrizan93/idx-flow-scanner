from __future__ import annotations

from dataclasses import dataclass

import pandas as pd


SHADOW_PREDICTIVE_TABLE = "flow_shadow_predictive_score_v1"
FINANCIAL_SHADOW_TABLE = "flow_financial_shadow_scan_comparison_v5"
STRATEGY_LIFECYCLE_TABLE = "flow_strategy_lifecycle_state_v3"
GATE15_ASSESSMENT_TABLE = "flow_gate15_promotion_assessment_v2"


@dataclass(frozen=True)
class ShadowResearchBundle:
    predictive_scores: pd.DataFrame
    financial_scores: pd.DataFrame
    lifecycle: pd.DataFrame
    errors: tuple[str, ...] = ()


def _rows(response) -> list[dict]:
    data = getattr(response, "data", None)
    if isinstance(data, list):
        return [row for row in data if isinstance(row, dict)]
    if isinstance(data, dict):
        return [data]
    return []


def _latest_value(store, table: str, column: str) -> str | None:
    response = (
        store.client.table(table)
        .select(column)
        .order(column, desc=True)
        .limit(1)
        .execute()
    )
    rows = _rows(response)
    if not rows:
        return None
    value = rows[0].get(column)
    return str(value) if value not in (None, "") else None


def _numeric(frame: pd.DataFrame, columns: tuple[str, ...]) -> pd.DataFrame:
    clean = frame.copy()
    for column in columns:
        if column in clean.columns:
            clean[column] = pd.to_numeric(clean[column], errors="coerce")
    return clean


def load_latest_shadow_predictive_scores(store, *, limit: int = 200) -> pd.DataFrame:
    """Load the latest combined predictive ranking that is still shadow-only.

    This is deliberately read-only and explicitly excludes rows whose production
    influence is enabled. The returned rank is a research rank, never an execution rank.
    """
    if store is None:
        return pd.DataFrame()
    signal_date = _latest_value(store, SHADOW_PREDICTIVE_TABLE, "signal_date")
    if signal_date is None:
        return pd.DataFrame()

    columns = (
        "model_contract,signal_date,ticker,universe_rank,current_tradeable,"
        "production_actionable,base_close,component_strength_score,"
        "reliability_adjusted_score,evidence_coverage_pct,tradeability_multiplier,"
        "shadow_predictive_score,shadow_rank,production_final_score,production_rank,"
        "rank_displacement,active_interactions,timing_quality,model_state,captured_at,"
        "production_influence_enabled"
    )
    response = (
        store.client.table(SHADOW_PREDICTIVE_TABLE)
        .select(columns)
        .eq("signal_date", signal_date)
        .eq("production_influence_enabled", False)
        .order("shadow_rank")
        .limit(max(1, min(int(limit), 900)))
        .execute()
    )
    frame = pd.DataFrame(_rows(response))
    if frame.empty:
        return frame
    frame = _numeric(
        frame,
        (
            "universe_rank",
            "base_close",
            "component_strength_score",
            "reliability_adjusted_score",
            "evidence_coverage_pct",
            "tradeability_multiplier",
            "shadow_predictive_score",
            "shadow_rank",
            "production_final_score",
            "production_rank",
            "rank_displacement",
        ),
    )
    frame["research_status"] = "RESEARCH ONLY"
    return frame.sort_values(["shadow_rank", "ticker"], na_position="last").reset_index(drop=True)


def load_latest_financial_shadow_scores(store, *, limit: int = 200) -> pd.DataFrame:
    """Load the latest financial shadow comparison without production influence."""
    if store is None:
        return pd.DataFrame()
    as_of_date = _latest_value(store, FINANCIAL_SHADOW_TABLE, "as_of_date")
    if as_of_date is None:
        return pd.DataFrame()

    columns = (
        "run_id,ticker,as_of_date,sector,financial_state,production_final_score,"
        "production_rank,production_phase,production_action,production_real_money_state,"
        "financial_shadow_score,financial_shadow_rank,evaluation_weight_pct,"
        "evaluation_blend_score,evaluation_blend_rank,production_influence_enabled,captured_at"
    )
    response = (
        store.client.table(FINANCIAL_SHADOW_TABLE)
        .select(columns)
        .eq("as_of_date", as_of_date)
        .eq("production_influence_enabled", False)
        .order("financial_shadow_rank")
        .limit(max(1, min(int(limit), 900)))
        .execute()
    )
    frame = pd.DataFrame(_rows(response))
    if frame.empty:
        return frame
    frame = _numeric(
        frame,
        (
            "production_final_score",
            "production_rank",
            "financial_shadow_score",
            "financial_shadow_rank",
            "evaluation_weight_pct",
            "evaluation_blend_score",
            "evaluation_blend_rank",
        ),
    )
    frame["research_status"] = "RESEARCH ONLY"
    return frame.sort_values(["financial_shadow_rank", "ticker"], na_position="last").reset_index(drop=True)


def load_shadow_strategy_lifecycle(store, *, limit: int = 200) -> pd.DataFrame:
    """Load every lifecycle candidate that still has zero production influence."""
    if store is None:
        return pd.DataFrame()

    lifecycle_columns = (
        "lifecycle_policy_version,candidate_id,candidate_type,promotion_state,previous_state,"
        "effective_from,weight,maximum_weight,production_influence_enabled,integrity_state,"
        "transition_reason,assessed_at,last_transition_at"
    )
    lifecycle_response = (
        store.client.table(STRATEGY_LIFECYCLE_TABLE)
        .select(lifecycle_columns)
        .eq("production_influence_enabled", False)
        .order("candidate_id")
        .limit(max(1, min(int(limit), 500)))
        .execute()
    )
    lifecycle = pd.DataFrame(_rows(lifecycle_response))
    if lifecycle.empty:
        return lifecycle

    assessment_columns = (
        "candidate_id,candidate_type,assessment_state,independent_matured_signal_dates,"
        "minimum_matured_sample_across_horizons,robustness_state,assessed_at,"
        "production_influence_enabled"
    )
    assessment_response = (
        store.client.table(GATE15_ASSESSMENT_TABLE)
        .select(assessment_columns)
        .eq("production_influence_enabled", False)
        .order("assessed_at", desc=True)
        .limit(500)
        .execute()
    )
    assessment = pd.DataFrame(_rows(assessment_response))
    if not assessment.empty and "candidate_id" in assessment.columns:
        assessment = assessment.drop_duplicates("candidate_id", keep="first").rename(
            columns={
                "candidate_type": "assessment_candidate_type",
                "assessed_at": "gate15_assessed_at",
                "production_influence_enabled": "gate15_production_influence_enabled",
            }
        )
        lifecycle = lifecycle.merge(assessment, how="left", on="candidate_id")

    lifecycle = _numeric(
        lifecycle,
        (
            "weight",
            "maximum_weight",
            "independent_matured_signal_dates",
            "minimum_matured_sample_across_horizons",
        ),
    )
    lifecycle["research_status"] = "RESEARCH ONLY"
    return lifecycle.sort_values(["candidate_type", "candidate_id"], na_position="last").reset_index(drop=True)


def load_shadow_research_bundle(store, *, limit: int = 200) -> ShadowResearchBundle:
    """Best-effort read bundle; one unavailable research source must not break the page."""
    errors: list[str] = []

    try:
        predictive = load_latest_shadow_predictive_scores(store, limit=limit)
    except Exception as exc:
        predictive = pd.DataFrame()
        errors.append(f"shadow predictive: {exc}")

    try:
        financial = load_latest_financial_shadow_scores(store, limit=limit)
    except Exception as exc:
        financial = pd.DataFrame()
        errors.append(f"financial shadow: {exc}")

    try:
        lifecycle = load_shadow_strategy_lifecycle(store, limit=limit)
    except Exception as exc:
        lifecycle = pd.DataFrame()
        errors.append(f"strategy lifecycle: {exc}")

    return ShadowResearchBundle(
        predictive_scores=predictive,
        financial_scores=financial,
        lifecycle=lifecycle,
        errors=tuple(errors),
    )
