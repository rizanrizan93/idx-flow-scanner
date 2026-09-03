from __future__ import annotations

import numpy as np
import pandas as pd


DEFAULT_SCORE_BINS = (0, 60, 65, 70, 75, 80, 85, 101)


def calibration_readiness(outcomes: pd.DataFrame | None) -> dict[str, object]:
    if outcomes is None or outcomes.empty:
        return {
            "rows": 0,
            "complete_5d": 0,
            "complete_20d": 0,
            "complete_60d": 0,
            "ready_for_threshold_review": False,
            "ready_for_weight_review": False,
        }
    frame = outcomes.copy()
    r5 = pd.to_numeric(frame.get("return_5d"), errors="coerce")
    r20 = pd.to_numeric(frame.get("return_20d"), errors="coerce")
    r60 = pd.to_numeric(frame.get("return_60d"), errors="coerce")
    c5, c20, c60 = int(r5.notna().sum()), int(r20.notna().sum()), int(r60.notna().sum())
    return {
        "rows": int(len(frame)),
        "complete_5d": c5,
        "complete_20d": c20,
        "complete_60d": c60,
        "ready_for_threshold_review": c20 >= 200,
        "ready_for_weight_review": c20 >= 400 and c60 >= 150,
    }


def build_calibration_report(
    outcomes: pd.DataFrame | None,
    *,
    score_bins: tuple[int, ...] = DEFAULT_SCORE_BINS,
) -> pd.DataFrame:
    if outcomes is None or outcomes.empty:
        return pd.DataFrame()
    frame = outcomes.copy()
    frame["final_score"] = pd.to_numeric(frame.get("final_score"), errors="coerce")
    frame = frame[frame["final_score"].notna()].copy()
    if frame.empty:
        return pd.DataFrame()
    labels = [f"{score_bins[i]}-{score_bins[i + 1] - 1}" for i in range(len(score_bins) - 1)]
    frame["score_bucket"] = pd.cut(
        frame["final_score"],
        bins=list(score_bins),
        labels=labels,
        right=False,
        include_lowest=True,
    )
    for col in ("return_5d", "return_20d", "return_60d", "mfe_20d", "mae_20d"):
        frame[col] = pd.to_numeric(frame.get(col), errors="coerce")

    rows: list[dict[str, object]] = []
    group_cols = ["score_bucket"]
    if "phase" in frame.columns:
        group_cols.append("phase")
    if "evidence_tier" in frame.columns:
        group_cols.append("evidence_tier")

    for keys, group in frame.groupby(group_cols, observed=True, dropna=False):
        keys = keys if isinstance(keys, tuple) else (keys,)
        payload = dict(zip(group_cols, keys))
        r20 = group["return_20d"].dropna()
        payload.update(
            {
                "n": int(len(group)),
                "n_20d": int(r20.notna().sum()),
                "mean_return_5d": float(group["return_5d"].mean()) if group["return_5d"].notna().any() else None,
                "mean_return_20d": float(r20.mean()) if r20.notna().any() else None,
                "median_return_20d": float(r20.median()) if r20.notna().any() else None,
                "hit_rate_20d": float((r20 > 0).mean()) if r20.notna().any() else None,
                "mean_return_60d": float(group["return_60d"].mean()) if group["return_60d"].notna().any() else None,
                "mean_mfe_20d": float(group["mfe_20d"].mean()) if group["mfe_20d"].notna().any() else None,
                "mean_mae_20d": float(group["mae_20d"].mean()) if group["mae_20d"].notna().any() else None,
            }
        )
        rows.append(payload)
    return pd.DataFrame(rows).sort_values(group_cols, kind="stable").reset_index(drop=True)


def calibration_health(report: pd.DataFrame | None) -> dict[str, object]:
    if report is None or report.empty:
        return {"monotonic_20d": None, "usable_buckets": 0}
    work = report.copy()
    if "phase" in work.columns:
        work = work.groupby("score_bucket", observed=True).agg(
            mean_return_20d=("mean_return_20d", "mean"),
            n_20d=("n_20d", "sum"),
        ).reset_index()
    work = work[pd.to_numeric(work.get("n_20d"), errors="coerce").fillna(0).ge(20)].copy()
    returns = pd.to_numeric(work.get("mean_return_20d"), errors="coerce").dropna()
    if len(returns) < 3:
        return {"monotonic_20d": None, "usable_buckets": int(len(returns))}
    diffs = np.diff(returns.to_numpy(dtype=float))
    return {
        "monotonic_20d": bool((diffs >= -1e-9).all()),
        "usable_buckets": int(len(returns)),
    }
