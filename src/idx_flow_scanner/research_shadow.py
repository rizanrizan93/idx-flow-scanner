from __future__ import annotations

from dataclasses import dataclass, field

import pandas as pd


SHADOW_PREDICTIVE_TABLE = "flow_shadow_predictive_score_v1"
FINANCIAL_SHADOW_TABLE = "flow_financial_shadow_scan_comparison_v5"
FINANCIAL_SHADOW_CURRENT_TABLE = "flow_financial_shadow_current_v6"
STRATEGY_LIFECYCLE_TABLE = "flow_strategy_lifecycle_state_v3"
GATE15_ASSESSMENT_TABLE = "flow_gate15_promotion_assessment_v2"
RESEARCH_HORIZON_POLICY_TABLE = "flow_research_horizon_policy_v1"
RESEARCH_HORIZON_SNAPSHOT_TABLE = "flow_research_horizon_snapshot_v1"
RESEARCH_HORIZON_OUTCOME_TABLE = "flow_research_horizon_outcome_v1"
RESEARCH_HORIZON_UI_CACHE_TABLE = "flow_research_horizon_ui_cache_v1"
RESEARCH_HORIZON_RANKING_RPC = "flow_research_horizon_rankings_v1"


@dataclass(frozen=True)
class ShadowResearchBundle:
    predictive_scores: pd.DataFrame
    financial_scores: pd.DataFrame
    lifecycle: pd.DataFrame
    horizon_rankings: pd.DataFrame = field(default_factory=pd.DataFrame)
    horizon_snapshots: pd.DataFrame = field(default_factory=pd.DataFrame)
    horizon_outcomes: pd.DataFrame = field(default_factory=pd.DataFrame)
    horizon_policies: pd.DataFrame = field(default_factory=pd.DataFrame)
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
    """Load the latest PIT financial shadow ranking, falling back to legacy comparison rows."""
    if store is None:
        return pd.DataFrame()

    try:
        current_date = _latest_value(store, FINANCIAL_SHADOW_CURRENT_TABLE, "as_of_date")
    except Exception:
        current_date = None

    if current_date is not None:
        current_columns = (
            "ticker,as_of_date,sector,financial_state,report_year,report_period,report_period_end,"
            "published_at,quality_score,growth_score,balance_score,cashflow_score,"
            "financial_shadow_score,financial_shadow_rank,production_influence_enabled,refreshed_at"
        )
        response = (
            store.client.table(FINANCIAL_SHADOW_CURRENT_TABLE)
            .select(current_columns)
            .eq("as_of_date", current_date)
            .eq("production_influence_enabled", False)
            .order("financial_shadow_rank")
            .limit(max(1, min(int(limit), 250)))
            .execute()
        )
        frame = pd.DataFrame(_rows(response))
        if not frame.empty:
            frame = _numeric(
                frame,
                (
                    "report_year",
                    "quality_score",
                    "growth_score",
                    "balance_score",
                    "cashflow_score",
                    "financial_shadow_score",
                    "financial_shadow_rank",
                ),
            )
            frame["research_status"] = "RESEARCH ONLY"
            frame["financial_source"] = "LATEST_PIT_CACHE"
            return frame.sort_values(
                ["financial_shadow_rank", "ticker"], na_position="last"
            ).reset_index(drop=True)

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
    frame["financial_source"] = "LEGACY_COMPARISON"
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


def load_research_horizon_rankings(store) -> pd.DataFrame:
    """Load the latest precomputed 5D/20D/60D research rankings for the dashboard.

    Heavy PIT computation runs once after close in the research scheduler. The Streamlit
    page reads this bounded cache instead of recomputing Top-900 plus financial PIT on
    every page load, preventing PostgREST statement timeouts.
    """
    if store is None:
        return pd.DataFrame()

    columns = (
        "strategy_contract,strategy_id,display_name,horizon_days,as_of_date,universe_snapshot_date,"
        "research_rank,ticker,stock_name,sector,universe_rank,current_tradeable,production_actionable,"
        "close,traded_value,foreign_net_volume_pct,stock_residual_activity_z,fin_balance_score,"
        "risk_event_20d_count,capital_action_90d_count,ihsg_return_5d_pct,ihsg_return_20d_pct,"
        "top10_value_share_pct,market_activity_intensity_z,market_gate_state,signal_state,"
        "research_priority_score,production_influence_enabled,refreshed_at"
    )
    response = (
        store.client.table(RESEARCH_HORIZON_UI_CACHE_TABLE)
        .select(columns)
        .eq("production_influence_enabled", False)
        .order("horizon_days")
        .limit(1000)
        .execute()
    )
    frame = pd.DataFrame(_rows(response))
    if frame.empty:
        return frame
    frame = _numeric(
        frame,
        (
            "horizon_days",
            "research_rank",
            "universe_rank",
            "close",
            "traded_value",
            "foreign_net_volume_pct",
            "stock_residual_activity_z",
            "fin_balance_score",
            "risk_event_20d_count",
            "capital_action_90d_count",
            "ihsg_return_5d_pct",
            "ihsg_return_20d_pct",
            "top10_value_share_pct",
            "market_activity_intensity_z",
            "research_priority_score",
        ),
    )
    frame["research_status"] = "RESEARCH ONLY"
    return frame.sort_values(["horizon_days", "research_rank", "ticker"], na_position="last").reset_index(drop=True)


def load_research_horizon_snapshots(store, *, limit: int = 180) -> pd.DataFrame:
    """Load compact prospective strategy-state history without large component payloads."""
    if store is None:
        return pd.DataFrame()
    columns = (
        "strategy_contract,strategy_id,horizon_days,signal_date,universe_snapshot_date,"
        "market_gate_state,signal_state,ranked_count,eligible_count,market_context,thresholds,"
        "captured_at,production_influence_enabled"
    )
    response = (
        store.client.table(RESEARCH_HORIZON_SNAPSHOT_TABLE)
        .select(columns)
        .eq("production_influence_enabled", False)
        .order("signal_date", desc=True)
        .limit(max(3, min(int(limit), 1000)))
        .execute()
    )
    frame = pd.DataFrame(_rows(response))
    if frame.empty:
        return frame
    frame = _numeric(frame, ("horizon_days", "ranked_count", "eligible_count"))
    frame["research_status"] = "RESEARCH ONLY"
    return frame.reset_index(drop=True)


def load_research_horizon_outcomes(store, *, limit: int = 300) -> pd.DataFrame:
    """Load clean prospective OOS basket outcomes accumulated by the research scheduler."""
    if store is None:
        return pd.DataFrame()
    columns = (
        "strategy_contract,strategy_id,horizon_days,signal_date,target_date,maturity_state,"
        "component_count,valid_component_count,excluded_component_count,coverage_pct,"
        "mean_return_pct,median_return_pct,win_rate_pct,mean_alpha_vs_ihsg_pct,"
        "mean_alpha_vs_sector_pct,mean_mfe_pct,mean_mae_pct,evaluated_at,production_influence_enabled"
    )
    response = (
        store.client.table(RESEARCH_HORIZON_OUTCOME_TABLE)
        .select(columns)
        .eq("production_influence_enabled", False)
        .order("signal_date", desc=True)
        .limit(max(3, min(int(limit), 2000)))
        .execute()
    )
    frame = pd.DataFrame(_rows(response))
    if frame.empty:
        return frame
    frame = _numeric(
        frame,
        (
            "horizon_days",
            "component_count",
            "valid_component_count",
            "excluded_component_count",
            "coverage_pct",
            "mean_return_pct",
            "median_return_pct",
            "win_rate_pct",
            "mean_alpha_vs_ihsg_pct",
            "mean_alpha_vs_sector_pct",
            "mean_mfe_pct",
            "mean_mae_pct",
        ),
    )
    frame["research_status"] = "RESEARCH ONLY"
    return frame.reset_index(drop=True)


def load_research_horizon_policies(store) -> pd.DataFrame:
    """Load frozen threshold contracts for the horizon strategies."""
    if store is None:
        return pd.DataFrame()
    response = (
        store.client.table(RESEARCH_HORIZON_POLICY_TABLE)
        .select(
            "strategy_contract,strategy_id,display_name,horizon_days,description,thresholds,"
            "policy_state,frozen_at,production_influence_enabled"
        )
        .eq("production_influence_enabled", False)
        .order("horizon_days")
        .execute()
    )
    frame = pd.DataFrame(_rows(response))
    if frame.empty:
        return frame
    frame = _numeric(frame, ("horizon_days",))
    frame["research_status"] = "RESEARCH ONLY"
    return frame.reset_index(drop=True)


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

    try:
        horizon_rankings = load_research_horizon_rankings(store)
    except Exception as exc:
        horizon_rankings = pd.DataFrame()
        errors.append(f"horizon rankings: {exc}")

    try:
        horizon_snapshots = load_research_horizon_snapshots(store)
    except Exception as exc:
        horizon_snapshots = pd.DataFrame()
        errors.append(f"horizon snapshots: {exc}")

    try:
        horizon_outcomes = load_research_horizon_outcomes(store)
    except Exception as exc:
        horizon_outcomes = pd.DataFrame()
        errors.append(f"horizon outcomes: {exc}")

    try:
        horizon_policies = load_research_horizon_policies(store)
    except Exception as exc:
        horizon_policies = pd.DataFrame()
        errors.append(f"horizon policies: {exc}")

    return ShadowResearchBundle(
        predictive_scores=predictive,
        financial_scores=financial,
        lifecycle=lifecycle,
        horizon_rankings=horizon_rankings,
        horizon_snapshots=horizon_snapshots,
        horizon_outcomes=horizon_outcomes,
        horizon_policies=horizon_policies,
        errors=tuple(errors),
    )
