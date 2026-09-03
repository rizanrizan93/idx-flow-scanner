from __future__ import annotations

import json

import pandas as pd


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


def select_zapi_decision_top(results: pd.DataFrame, *, top_n: int = 20) -> pd.DataFrame:
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
        work[name] = work["diagnostics"].map(lambda value, key=name, d=default: _diag(value).get(key, d))
    dist = pd.to_numeric(work.get("distribution_risk"), errors="coerce").fillna(100.0)
    quality = pd.to_numeric(work.get("price_data_quality_score"), errors="coerce").fillna(0.0)
    gate = (
        work.get("evidence_tier", pd.Series("", index=work.index)).eq("ZAPI_FLOW")
        & work["foreign_window_state"].eq("FULL")
        & work["foreign_data_freshness"].eq("FRESH")
        & work["foreign_data_valid"].map(lambda value: value is True)
        & dist.lt(70.0)
        & quality.ge(70.0)
        & work.get("phase", pd.Series("", index=work.index)).ne("DISTRIBUTION")
        & work.get("action", pd.Series("", index=work.index)).ne("REDUCE_AVOID")
    )
    out = work.loc[gate].copy()
    if out.empty:
        return out
    for col in ("final_score", "accumulation_score", "foreign_institutional_score", "market_context_score", "smc_execution_score"):
        out[col] = pd.to_numeric(out.get(col), errors="coerce").fillna(0.0)
    out = out.sort_values(
        ["final_score", "accumulation_score", "foreign_institutional_score", "market_context_score", "smc_execution_score", "ticker"],
        ascending=[False, False, False, False, False, True],
        kind="stable",
    ).head(int(top_n)).reset_index(drop=True)
    out["decision_rank"] = range(1, len(out) + 1)
    return out


def select_execution_ready(results: pd.DataFrame, *, top_n: int = 10) -> pd.DataFrame:
    if results is None or results.empty or top_n <= 0:
        return pd.DataFrame()
    authorized = results.get("production_authorized", pd.Series(False, index=results.index))
    if not pd.api.types.is_bool_dtype(authorized):
        authorized = authorized.map(lambda value: value is True)
    out = results.loc[authorized.fillna(False)].copy()
    if out.empty:
        return out
    out = out.sort_values(["final_score", "ticker"], ascending=[False, True], kind="stable").head(int(top_n)).reset_index(drop=True)
    out["execution_rank"] = range(1, len(out) + 1)
    return out
