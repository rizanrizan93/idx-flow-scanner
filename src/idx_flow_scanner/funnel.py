from __future__ import annotations

import json
from typing import Callable

import pandas as pd

from .config import ScannerConfig
from .data import canonical_ticker
from .pipeline import scan_one


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


def _numeric(series: pd.Series, default: float = 0.0) -> pd.Series:
    return pd.to_numeric(series, errors="coerce").fillna(default)


def _int_or_default(value: object, default: int) -> int:
    try:
        if value is None or pd.isna(value):
            return int(default)
        return int(value)
    except (TypeError, ValueError):
        return int(default)


def select_guarded_top5(
    results: pd.DataFrame,
    config: ScannerConfig | None = None,
    *,
    top_n: int = 5,
    minimum_foreign_coverage_pct: float = 70.0,
) -> pd.DataFrame:
    """Select the broker-enrichment cohort from the proxy + foreign pass.

    This is deliberately fail-closed. Broker data must not influence this ranking;
    the input is expected to come from ``scan_universe(..., broker_frame=empty)``.
    Candidates must pass price-quality, distribution, decision-floor and foreign-
    evidence gates before any scarce broker request is spent on them.
    """
    config = config or ScannerConfig()
    if results is None or results.empty or top_n <= 0:
        return pd.DataFrame()

    work = results.copy()
    if "diagnostics" not in work.columns:
        work["diagnostics"] = [{} for _ in range(len(work))]

    work["foreign_evidence_coverage_pct"] = work["diagnostics"].map(
        lambda d: float(
            _diagnostics(d).get(
                "foreign_evidence_coverage_pct",
                _diagnostics(d).get("official_foreign_coverage_pct", 0.0),
            )
            or 0.0
        )
    )
    work["price_staleness_days"] = work["diagnostics"].map(
        lambda d: _int_or_default(_diagnostics(d).get("price_staleness_days", 999), 999)
    )

    score = _numeric(work.get("final_score", pd.Series(index=work.index, dtype=float)))
    dist = _numeric(work.get("distribution_risk", pd.Series(index=work.index, dtype=float)), 100.0)
    quality = _numeric(work.get("price_data_quality_score", pd.Series(index=work.index, dtype=float)))
    foreign_cov = _numeric(work["foreign_evidence_coverage_pct"])
    phase = work.get("phase", pd.Series("UNKNOWN", index=work.index)).fillna("UNKNOWN").astype(str)
    action = work.get("action", pd.Series("RESEARCH_ONLY", index=work.index)).fillna("RESEARCH_ONLY").astype(str)

    gate = (
        score.ge(65.0)
        & dist.lt(70.0)
        & quality.ge(float(config.real_money_min_price_quality_score))
        & work["price_staleness_days"].le(int(config.max_price_staleness_days))
        & foreign_cov.ge(float(minimum_foreign_coverage_pct))
        & phase.ne("DISTRIBUTION")
        & action.ne("REDUCE_AVOID")
    )
    finalists = work.loc[gate].copy()
    if finalists.empty:
        return finalists

    for col in ("accumulation_score", "foreign_institutional_score", "smc_execution_score"):
        if col not in finalists.columns:
            finalists[col] = 0.0
    finalists = finalists.sort_values(
        ["final_score", "accumulation_score", "foreign_institutional_score", "smc_execution_score", "ticker"],
        ascending=[False, False, False, False, True],
        kind="stable",
    ).head(int(top_n)).reset_index(drop=True)
    finalists["guarded_rank"] = range(1, len(finalists) + 1)
    finalists["guarded_status"] = "GUARDED_FINALIST"
    finalists["guarded_score"] = pd.to_numeric(finalists["final_score"], errors="coerce")
    return finalists


def verify_guarded_top5(
    guarded_top5: pd.DataFrame,
    price_loader: Callable[[str], pd.DataFrame],
    broker_frame: pd.DataFrame | None,
    *,
    config: ScannerConfig | None = None,
    official_flow_frame: pd.DataFrame | None = None,
) -> tuple[pd.DataFrame, list[dict[str, str]]]:
    """Re-score only the guarded finalists with direct broker evidence.

    The 400-ticker market context is preserved from the first pass so the second
    pass cannot change relative-strength context merely because it scans five rows.
    """
    config = config or ScannerConfig()
    if guarded_top5 is None or guarded_top5.empty:
        return pd.DataFrame(), []
    broker_frame = broker_frame if broker_frame is not None else pd.DataFrame()
    official_flow_frame = official_flow_frame if official_flow_frame is not None else pd.DataFrame()

    rows: list[dict[str, object]] = []
    errors: list[dict[str, str]] = []
    for _, source_row in guarded_top5.sort_values("guarded_rank", kind="stable").iterrows():
        ticker = canonical_ticker(source_row.get("ticker"))
        try:
            price = price_loader(ticker)
            broker = (
                broker_frame[broker_frame["ticker"] == ticker].copy()
                if not broker_frame.empty and "ticker" in broker_frame.columns
                else pd.DataFrame()
            )
            flow = (
                official_flow_frame[official_flow_frame["ticker"] == ticker].copy()
                if not official_flow_frame.empty and "ticker" in official_flow_frame.columns
                else pd.DataFrame()
            )
            diag = _diagnostics(source_row.get("diagnostics"))
            market_features = {
                "market_sector_score": float(source_row.get("market_context_score", 50.0) or 50.0),
                "market_regime_score": float(diag.get("market_regime_score", 50.0) or 50.0),
                "market_regime_label": str(diag.get("market_regime_label") or "UNKNOWN"),
                "market_breadth_20d": diag.get("market_breadth_20d"),
                "market_breadth_60d": diag.get("market_breadth_60d"),
                "relative_strength_20d_pct": diag.get("relative_strength_20d_pct"),
                "relative_strength_60d_pct": diag.get("relative_strength_60d_pct"),
                "market_context_basis": diag.get("market_context_basis"),
                "market_context_coverage": diag.get("market_context_coverage"),
            }
            verified = scan_one(
                ticker,
                price,
                broker,
                config,
                official_flow=flow,
                market_features=market_features,
                reference_date=str(source_row.get("as_of_date") or "") or None,
            ).to_dict()
            if verified.get("evidence_tier") != "BROKER_DIRECT":
                status = "BROKER_PENDING"
            elif verified.get("phase") == "DISTRIBUTION" or verified.get("action") == "REDUCE_AVOID" or float(verified.get("distribution_risk", 100.0) or 100.0) >= 70.0:
                status = "BROKER_REJECT"
            elif verified.get("real_money_state") == "ELIGIBLE":
                status = "BROKER_VERIFIED"
            else:
                status = "BROKER_GUARDED"

            verified["guarded_rank"] = int(source_row.get("guarded_rank", 0) or 0)
            verified["guarded_score"] = float(source_row.get("guarded_score", source_row.get("final_score", 0.0)) or 0.0)
            verified["broker_verification_status"] = status
            diagnostics = _diagnostics(verified.get("diagnostics"))
            diagnostics.update(
                {
                    "guarded_rank": verified["guarded_rank"],
                    "guarded_score": verified["guarded_score"],
                    "broker_verification_status": status,
                }
            )
            verified["diagnostics"] = diagnostics
            rows.append(verified)
        except Exception as exc:
            errors.append({"ticker": ticker, "stage": "BROKER_VERIFY", "error": str(exc)})

    out = pd.DataFrame(rows)
    if out.empty:
        return out, errors
    status_order = {
        "BROKER_VERIFIED": 0,
        "BROKER_GUARDED": 1,
        "BROKER_PENDING": 2,
        "BROKER_REJECT": 3,
    }
    out["_status_order"] = out["broker_verification_status"].map(status_order).fillna(9)
    out = out.sort_values(
        ["_status_order", "final_score", "accumulation_score", "guarded_rank", "ticker"],
        ascending=[True, False, False, True, True],
        kind="stable",
    ).drop(columns="_status_order").reset_index(drop=True)
    out["broker_rank"] = range(1, len(out) + 1)
    return out, errors


def merge_verified_finalists(base_results: pd.DataFrame, broker_results: pd.DataFrame) -> pd.DataFrame:
    """Replace only finalist rows in the 400-row research result set."""
    if base_results is None or base_results.empty or broker_results is None or broker_results.empty:
        return base_results.copy() if isinstance(base_results, pd.DataFrame) else pd.DataFrame()
    out = base_results.copy()
    replacements = broker_results.set_index("ticker", drop=False)
    for idx, ticker in out["ticker"].items():
        if ticker not in replacements.index:
            continue
        row = replacements.loc[ticker]
        if isinstance(row, pd.DataFrame):
            row = row.iloc[0]
        for col in out.columns:
            if col in row.index:
                out.at[idx, col] = row[col]
    return out.sort_values(
        ["real_money_state", "final_score", "ticker"],
        ascending=[True, False, True],
        kind="stable",
    ).reset_index(drop=True)
