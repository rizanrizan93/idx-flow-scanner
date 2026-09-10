from __future__ import annotations

from pathlib import Path

import pandas as pd

from .data import canonical_ticker


OPERATIONAL_CONTRACT = "IDX_OPERATIONAL_TOP900_V1"
SOURCE_UNIVERSE_CONTRACT = "TOP_900_UNIVERSE_V1"
TARGET_COUNT = 900
REQUIRED_COLUMNS = {
    "snapshot_date",
    "ticker",
    "universe_rank",
    "current_tradeable",
    "production_actionable",
    "data_quality_state",
    "liquidity_state",
    "runtime_ranking_eligible",
}


class OperationalUniverseUnavailable(RuntimeError):
    """Raised when the canonical Top-900 runtime contract cannot be proven."""


def _strict_boolean(series: pd.Series, column: str) -> pd.Series:
    mapping = {
        True: True,
        False: False,
        "true": True,
        "false": False,
        "TRUE": True,
        "FALSE": False,
        1: True,
        0: False,
    }
    parsed = series.map(mapping)
    if parsed.isna().any():
        raise OperationalUniverseUnavailable(f"Top-900 contains an invalid {column} state")
    return parsed.astype(bool)


def validate_operational_top900(frame: pd.DataFrame) -> pd.DataFrame:
    """Validate one exact, ordered canonical Top-900 snapshot.

    Validation is intentionally strict: a partial response must not silently become
    a smaller operational universe.
    """
    if frame is None or frame.empty:
        raise OperationalUniverseUnavailable("canonical Top-900 snapshot is empty")
    missing = REQUIRED_COLUMNS.difference(frame.columns)
    if missing:
        raise OperationalUniverseUnavailable(
            f"canonical Top-900 response is missing columns: {sorted(missing)}"
        )

    clean = frame.copy()
    clean["ticker"] = clean["ticker"].map(canonical_ticker)
    clean["universe_rank"] = pd.to_numeric(
        clean["universe_rank"], errors="coerce"
    ).astype("Int64")
    for column in (
        "current_tradeable",
        "production_actionable",
        "runtime_ranking_eligible",
    ):
        clean[column] = _strict_boolean(clean[column], column)
    snapshots = pd.to_datetime(clean["snapshot_date"], errors="coerce").dt.date.dropna().unique()
    if len(snapshots) != 1:
        raise OperationalUniverseUnavailable("Top-900 response must contain one snapshot date")
    if len(clean) != TARGET_COUNT or clean["ticker"].nunique() != TARGET_COUNT:
        raise OperationalUniverseUnavailable(
            f"Top-900 response must contain exactly {TARGET_COUNT} unique tickers"
        )
    ranks = clean["universe_rank"].dropna().astype(int).sort_values().tolist()
    if ranks != list(range(1, TARGET_COUNT + 1)):
        raise OperationalUniverseUnavailable("Top-900 ranks must be exactly 1..900")
    if clean["ticker"].eq("").any() or not clean["ticker"].str.fullmatch(r"[A-Z0-9]{4}").all():
        raise OperationalUniverseUnavailable("Top-900 contains an invalid ticker identity")
    if not clean["runtime_ranking_eligible"].all():
        raise OperationalUniverseUnavailable("all selected Top-900 rows must be ranking eligible")

    return clean.sort_values("universe_rank").reset_index(drop=True)


def load_canonical_operational_top900(store) -> pd.DataFrame:
    """Load the latest fully captured canonical snapshot through the service-only RPC."""
    if store is None:
        raise OperationalUniverseUnavailable("canonical Supabase store is unavailable")
    try:
        response = store.client.rpc("flow_load_operational_universe_v1", {}).execute()
    except Exception as exc:
        raise OperationalUniverseUnavailable("canonical Top-900 RPC failed") from exc
    rows = response.data or []
    if isinstance(rows, dict):
        rows = [rows]
    return validate_operational_top900(pd.DataFrame(rows))


def load_bundled_operational_top900(path: Path) -> pd.DataFrame:
    """Load a repository snapshot only when it proves the same exact contract."""
    if not path.exists():
        raise OperationalUniverseUnavailable(f"bundled Top-900 snapshot is missing: {path}")
    return validate_operational_top900(pd.read_csv(path))


def materialize_runtime_top900(
    store,
    *,
    bundled_path: Path,
    runtime_path: Path,
) -> Path:
    """Prefer canonical Supabase, with an exact validated bundled snapshot fallback."""
    try:
        frame = load_canonical_operational_top900(store)
    except OperationalUniverseUnavailable:
        frame = load_bundled_operational_top900(bundled_path)

    runtime_path.parent.mkdir(parents=True, exist_ok=True)
    frame.to_csv(runtime_path, index=False)
    return runtime_path


def apply_operational_membership_guards(
    results: pd.DataFrame,
    membership: pd.DataFrame,
) -> pd.DataFrame:
    """Keep all valid rows rankable while preventing non-actionable execution.

    The guard is intentionally idempotent because Streamlit can rerun the entrypoint
    in a long-lived interpreter. Reapplying it must refresh guard metadata/rank rather
    than failing when a previously guarded frame already contains ``scanner_rank``.
    """
    if results is None or results.empty:
        return results
    canonical = validate_operational_top900(membership)
    states = canonical.set_index("ticker").to_dict("index")

    guarded = results.copy()
    guarded["operational_universe_contract"] = OPERATIONAL_CONTRACT
    guarded["operational_universe_rank"] = guarded["ticker"].map(
        lambda ticker: states.get(canonical_ticker(ticker), {}).get("universe_rank")
    )
    guarded["universe_current_tradeable"] = guarded["ticker"].map(
        lambda ticker: bool(states.get(canonical_ticker(ticker), {}).get("current_tradeable", False))
    )
    guarded["universe_production_actionable"] = guarded["ticker"].map(
        lambda ticker: bool(
            states.get(canonical_ticker(ticker), {}).get("production_actionable", False)
        )
    )

    blocked = ~guarded["universe_production_actionable"]
    guarded.loc[blocked, "production_authorized"] = False
    guarded.loc[blocked, "real_money_state"] = "GUARDED"
    guarded.loc[blocked, "action"] = "RESEARCH_ONLY"

    def attach_guard(row: pd.Series) -> dict:
        diagnostics = dict(row.get("diagnostics") or {})
        diagnostics.update(
            {
                "operational_universe_contract": OPERATIONAL_CONTRACT,
                "operational_universe_rank": row.get("operational_universe_rank"),
                "universe_current_tradeable": bool(row.get("universe_current_tradeable")),
                "universe_production_actionable": bool(
                    row.get("universe_production_actionable")
                ),
                "predictive_attribution_production_influence_enabled": False,
            }
        )
        return diagnostics

    guarded["diagnostics"] = guarded.apply(attach_guard, axis=1)
    guarded.loc[blocked, "guardrail_reason"] = guarded.loc[blocked].apply(
        lambda row: "; ".join(
            filter(
                None,
                [
                    str(row.get("guardrail_reason") or "").strip(),
                    "Top-900 member is not currently production-actionable",
                ],
            )
        ),
        axis=1,
    )
    raw_rank = guarded.sort_values(
        ["final_score", "ticker"],
        ascending=[False, True],
        kind="stable",
    ).index
    rank_by_index = {index: rank for rank, index in enumerate(raw_rank, 1)}
    guarded["scanner_rank"] = guarded.index.map(rank_by_index)
    guarded = guarded.loc[
        :, ["scanner_rank"] + [column for column in guarded.columns if column != "scanner_rank"]
    ]
    guarded = guarded.sort_values(
        ["production_authorized", "final_score", "ticker"],
        ascending=[False, False, True],
        kind="stable",
    ).reset_index(drop=True)
    return guarded
