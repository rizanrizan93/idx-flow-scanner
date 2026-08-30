from __future__ import annotations

from typing import Callable, Iterable

import numpy as np
import pandas as pd

from .data import canonical_ticker

DIRECT_IDX_SOURCE = "IDX_OFFICIAL_STOCK_SUMMARY"
ZAPI_IDX_SOURCE = "ZAPI_IDX_FOREIGN_FLOW"
ZAPI_STOCK_SUMMARY_SOURCE = "ZAPI_IDX_STOCK_SUMMARY"
ZAPI_SOURCES = frozenset({ZAPI_IDX_SOURCE, ZAPI_STOCK_SUMMARY_SOURCE})

FOREIGN_FULL = "FULL"
FOREIGN_PARTIAL = "PARTIAL"
FOREIGN_INSUFFICIENT = "INSUFFICIENT"
FOREIGN_MISSING = "MISSING"

PROVIDER_IDX_DIRECT = "IDX_DIRECT"
PROVIDER_ZAPI = "ZAPI"
PROVIDER_NONE = "NONE"
SELECTION_NO_VALID = "NO_VALID_PROVIDER"
SELECTION_PARTIAL = "PARTIAL_ONLY"

RECONCILIATION_AGREED = "AGREED"
RECONCILIATION_SINGLE_PROVIDER = "SINGLE_PROVIDER"
RECONCILIATION_DIRECTION_CONFLICT = "DIRECTION_CONFLICT"
RECONCILIATION_UNRESOLVED = "UNRESOLVED"
RECONCILIATION_NOT_COMPARABLE = "NOT_COMPARABLE"
RECONCILIATION_UNKNOWN = "UNKNOWN"

_WINDOW_RANK = {
    FOREIGN_MISSING: 0,
    FOREIGN_INSUFFICIENT: 1,
    FOREIGN_PARTIAL: 2,
    FOREIGN_FULL: 3,
}
_FRESHNESS_RANK = {"MISSING": 0, "UNKNOWN": 0, "STALE": 1, "FRESH": 2}
_AUTHORITY_RANK = {PROVIDER_ZAPI: 1, PROVIDER_IDX_DIRECT: 2}
_PARTIAL_MIN_COVERAGE_RATIO = 0.70

_RECONCILIATION_BLOCKING_STATES = frozenset(
    {
        RECONCILIATION_DIRECTION_CONFLICT,
        RECONCILIATION_UNRESOLVED,
        RECONCILIATION_NOT_COMPARABLE,
        RECONCILIATION_UNKNOWN,
    }
)


def _requested_days(price: pd.DataFrame, lookback: int) -> pd.DatetimeIndex:
    if price is None or price.empty or "date" not in price.columns:
        return pd.DatetimeIndex([])
    values = pd.to_datetime(price["date"], errors="coerce").dropna().dt.normalize().unique()
    return pd.DatetimeIndex(values).sort_values()[-max(1, int(lookback)) :]


def _window_state(observed: int, requested: int) -> str:
    if observed <= 0 or requested <= 0:
        return FOREIGN_MISSING
    ratio = observed / requested
    if observed >= requested:
        return FOREIGN_FULL
    if ratio >= _PARTIAL_MIN_COVERAGE_RATIO:
        return FOREIGN_PARTIAL
    return FOREIGN_INSUFFICIENT


def _provider_for_source(source: str) -> str:
    if source == DIRECT_IDX_SOURCE:
        return PROVIDER_IDX_DIRECT
    if source in ZAPI_SOURCES:
        return PROVIDER_ZAPI
    return PROVIDER_NONE


def _semantic_value(
    rows: pd.DataFrame,
    columns: tuple[str, ...],
    default: str,
    aliases: dict[str, str] | None = None,
) -> tuple[str, bool]:
    values = pd.Series(dtype=object)
    for column in columns:
        if column in rows.columns:
            values = rows[column].dropna().astype(str).str.strip().str.upper()
            values = values.loc[values.ne("")]
            if not values.empty:
                break
    if values.empty:
        return default, True
    if aliases:
        values = values.map(lambda value: aliases.get(value, value))
    unique = values.drop_duplicates().tolist()
    return (str(unique[0]), len(unique) == 1)


def _empty_evaluation(provider: str, source: str | None, requested: int) -> dict[str, object]:
    return {
        "provider": provider,
        "source": source,
        "available": False,
        "valid": False,
        "valid_rows": 0,
        "requested_observations": int(requested),
        "observed_observations": 0,
        "coverage_ratio": 0.0,
        "window_state": FOREIGN_MISSING,
        "latest_observation": None,
        "latest_age": None,
        "freshness": "MISSING",
        "duplicate_state": "NONE",
        "error_state": "NO_DATA",
        "net_total": None,
        "flow_unit": "SHARES",
        "measurement_definition": "NET_FOREIGN_SHARES",
        "aggregation_basis": "DAILY",
        "observed_start_date": None,
        "observed_end_date": None,
        "observation_dates": pd.DatetimeIndex([]),
        "rows": pd.DataFrame(),
        "daily_net": pd.Series(dtype=float),
    }


def _evaluate_source(
    ticker: str,
    source: str,
    source_rows: pd.DataFrame,
    requested_days: pd.DatetimeIndex,
) -> dict[str, object]:
    provider = _provider_for_source(source)
    result = _empty_evaluation(provider, source, len(requested_days))
    result["available"] = source_rows is not None and not source_rows.empty
    if not result["available"]:
        return result

    required = {"ticker", "trade_date", "foreign_buy", "foreign_sell", "foreign_net", "volume"}
    if not required.issubset(source_rows.columns):
        result["error_state"] = "MISSING_REQUIRED_FIELDS"
        return result
    if provider == PROVIDER_NONE:
        result["error_state"] = "UNRECOGNIZED_PROVIDER"
        return result

    rows = source_rows.copy()
    rows["ticker"] = rows["ticker"].map(canonical_ticker)
    if not rows["ticker"].eq(ticker).all():
        result["error_state"] = "SYMBOL_MISMATCH"
        return result
    rows["trade_date"] = pd.to_datetime(rows["trade_date"], errors="coerce").dt.normalize()
    flow_unit, unit_consistent = _semantic_value(
        rows,
        ("flow_unit", "unit"),
        "SHARES",
        {
            "SHARE": "SHARES",
            "LEMBAR": "SHARES",
            "LEMBAR SAHAM": "SHARES",
        },
    )
    measurement_definition, definition_consistent = _semantic_value(
        rows,
        ("foreign_measure_definition", "measurement_definition"),
        "NET_FOREIGN_SHARES",
    )
    aggregation_basis, aggregation_consistent = _semantic_value(
        rows,
        ("aggregation_basis",),
        "DAILY",
        {"DAY": "DAILY", "D1": "DAILY"},
    )
    semantic_consistent = unit_consistent and definition_consistent and aggregation_consistent
    semantic_supported = (
        flow_unit == "SHARES"
        and measurement_definition == "NET_FOREIGN_SHARES"
        and aggregation_basis == "DAILY"
    )
    numeric_columns = ["foreign_buy", "foreign_sell", "foreign_net", "volume"]
    for column in numeric_columns:
        rows[column] = pd.to_numeric(rows[column], errors="coerce")

    provider_error = pd.Series(False, index=rows.index)
    for column in ("provider_error", "error", "error_state"):
        if column in rows.columns:
            values = rows[column].fillna("").astype(str).str.strip().str.upper()
            provider_error |= values.ne("") & ~values.isin({"OK", "NONE", "SUCCESS"})

    parse_valid = rows["trade_date"].notna()
    for column in numeric_columns:
        values = rows[column]
        parse_valid &= values.notna() & np.isfinite(values)
    parse_valid &= rows["foreign_buy"].ge(0) & rows["foreign_sell"].ge(0) & rows["volume"].ge(0)
    calculated_net = rows["foreign_buy"] - rows["foreign_sell"]
    net_tolerance = np.maximum(1e-6, calculated_net.abs() * 1e-6)
    parse_valid &= (rows["foreign_net"] - calculated_net).abs().le(net_tolerance)
    parse_valid &= ~provider_error

    inconsistent_duplicates = False
    dated = rows.loc[rows["trade_date"].notna()].copy()
    for _, duplicate_rows in dated.groupby("trade_date", observed=True):
        if len(duplicate_rows[numeric_columns].drop_duplicates()) > 1:
            inconsistent_duplicates = True
            break
    result["duplicate_state"] = "INCONSISTENT" if inconsistent_duplicates else (
        "EXACT_DUPLICATES_COLLAPSED" if dated.duplicated("trade_date").any() else "NONE"
    )

    in_window = (
        rows["trade_date"].isin(requested_days)
        if len(requested_days)
        else pd.Series(False, index=rows.index)
    )
    malformed = (~parse_valid) & (in_window | rows["trade_date"].isna())
    usable = rows.loc[parse_valid & in_window].drop_duplicates("trade_date", keep="last").copy()
    observed = int(usable["trade_date"].nunique())
    requested = int(len(requested_days))
    state = _window_state(observed, requested)
    latest = usable["trade_date"].max() if not usable.empty else pd.NaT
    if pd.isna(latest):
        freshness = "MISSING"
        latest_age = None
    elif not len(requested_days):
        freshness = "UNKNOWN"
        latest_age = None
    else:
        latest_age = int((requested_days > pd.Timestamp(latest)).sum())
        freshness = "FRESH" if latest_age == 0 else "STALE"

    result.update(
        {
            "valid": bool(
                observed > 0
                and semantic_consistent
                and semantic_supported
                and not inconsistent_duplicates
                and not malformed.any()
            ),
            "valid_rows": int(len(usable)),
            "observed_observations": observed,
            "coverage_ratio": float(observed / requested) if requested else 0.0,
            "window_state": state,
            "latest_observation": pd.Timestamp(latest).date().isoformat() if pd.notna(latest) else None,
            "latest_age": latest_age,
            "freshness": freshness,
            "error_state": (
                "INCONSISTENT_EVIDENCE_SEMANTICS"
                if not semantic_consistent
                else "UNSUPPORTED_EVIDENCE_SEMANTICS"
                if not semantic_supported
                else "INCONSISTENT_DUPLICATES"
                if inconsistent_duplicates
                else "INVALID_RECORDS"
                if malformed.any()
                else "OK"
                if observed > 0
                else "WINDOW_MISMATCH"
            ),
            "net_total": float(usable["foreign_net"].sum()) if not usable.empty else None,
            "flow_unit": flow_unit,
            "measurement_definition": measurement_definition,
            "aggregation_basis": aggregation_basis,
            "observed_start_date": (
                pd.Timestamp(usable["trade_date"].min()).date().isoformat() if not usable.empty else None
            ),
            "observed_end_date": (
                pd.Timestamp(usable["trade_date"].max()).date().isoformat() if not usable.empty else None
            ),
            "observation_dates": pd.DatetimeIndex(usable["trade_date"].sort_values().unique()),
            "rows": usable,
            "daily_net": usable.set_index("trade_date")["foreign_net"].sort_index() if not usable.empty else pd.Series(dtype=float),
        }
    )
    return result


def _evidence_rank(evaluation: dict[str, object]) -> tuple[int, int, float, int, str]:
    return (
        _FRESHNESS_RANK.get(str(evaluation.get("freshness")), 0),
        _WINDOW_RANK.get(str(evaluation.get("window_state")), 0),
        float(evaluation.get("coverage_ratio") or 0.0),
        _AUTHORITY_RANK.get(str(evaluation.get("provider")), 0),
        str(evaluation.get("source") or ""),
    )


def _reconcile_evidence(left: dict[str, object], right: dict[str, object]) -> tuple[str, str]:
    """Classify provider agreement without an undocumented numeric tolerance."""
    semantic_fields = ("flow_unit", "measurement_definition", "aggregation_basis")
    mismatches = [field for field in semantic_fields if left.get(field) != right.get(field)]
    if bool(left.get("available")) and bool(right.get("available")) and mismatches:
        return (
            RECONCILIATION_NOT_COMPARABLE,
            "provider evidence uses different " + ", ".join(mismatches),
        )

    valid_count = int(bool(left.get("valid"))) + int(bool(right.get("valid")))
    if valid_count == 0:
        return RECONCILIATION_UNKNOWN, "no independently valid provider evidence to reconcile"
    if valid_count == 1:
        return RECONCILIATION_SINGLE_PROVIDER, "only one provider has independently valid evidence"

    left_dates = left.get("observation_dates")
    right_dates = right.get("observation_dates")
    if not isinstance(left_dates, pd.DatetimeIndex) or not isinstance(right_dates, pd.DatetimeIndex):
        return RECONCILIATION_NOT_COMPARABLE, "provider observation windows are unavailable"
    if not left_dates.equals(right_dates):
        return RECONCILIATION_NOT_COMPARABLE, "provider observation windows or date ranges differ"

    left_daily = left.get("daily_net")
    right_daily = right.get("daily_net")
    if not isinstance(left_daily, pd.Series) or not isinstance(right_daily, pd.Series):
        return RECONCILIATION_NOT_COMPARABLE, "provider daily observations are unavailable"
    lvalues = pd.to_numeric(left_daily.reindex(left_dates), errors="coerce")
    rvalues = pd.to_numeric(right_daily.reindex(left_dates), errors="coerce")
    valid = lvalues.notna() & rvalues.notna()
    if not valid.all() or not valid.any():
        return RECONCILIATION_NOT_COMPARABLE, "provider daily observations are incomplete"
    lvalues = lvalues.loc[valid].astype(float)
    rvalues = rvalues.loc[valid].astype(float)
    directional_conflict = ((lvalues.lt(0) & rvalues.gt(0)) | (lvalues.gt(0) & rvalues.lt(0))).any()
    if bool(directional_conflict):
        return RECONCILIATION_DIRECTION_CONFLICT, "providers report opposite net-flow directions"
    if bool(lvalues.eq(rvalues).all()):
        return RECONCILIATION_AGREED, "comparable daily net foreign share observations agree exactly"
    return (
        RECONCILIATION_UNRESOLVED,
        "comparable same-direction observations differ without an authoritative tolerance",
    )


def _public_evaluation(evaluation: dict[str, object]) -> dict[str, object]:
    return {
        key: evaluation.get(key)
        for key in (
            "provider",
            "source",
            "available",
            "valid",
            "valid_rows",
            "requested_observations",
            "observed_observations",
            "coverage_ratio",
            "window_state",
            "latest_observation",
            "latest_age",
            "freshness",
            "duplicate_state",
            "error_state",
            "net_total",
            "flow_unit",
            "measurement_definition",
            "aggregation_basis",
            "observed_start_date",
            "observed_end_date",
        )
    }


def _metadata_row(ticker: str, metadata: dict[str, object]) -> pd.DataFrame:
    return pd.DataFrame(
        [
            {
                "ticker": ticker,
                "trade_date": pd.NaT,
                "foreign_buy": pd.NA,
                "foreign_sell": pd.NA,
                "foreign_net": pd.NA,
                "volume": pd.NA,
                "source": None,
                "foreign_evidence_selected": False,
                **metadata,
            }
        ]
    )


def prepare_foreign_evidence(
    universe: Iterable[str],
    candidates: pd.DataFrame,
    price_loader: Callable[[str], pd.DataFrame],
    *,
    lookback: int = 20,
) -> tuple[pd.DataFrame, dict[str, object]]:
    """Compare IDX-direct and ZAPI evidence before selecting one provider per ticker.

    Each provider is parsed and validated independently. Selection is row-local and
    deterministic: validity, freshness, window completeness, then direct-source
    authority. An unresolved, incomparable, or directional disagreement is
    retained as explicit reconciliation metadata; one deterministic research
    signal remains visible, but downstream production authorization fails closed.
    """
    frame = candidates.copy() if candidates is not None else pd.DataFrame()
    if not frame.empty:
        frame.columns = [str(column).strip().lower() for column in frame.columns]
        if "ticker" in frame.columns:
            frame["ticker"] = frame["ticker"].map(canonical_ticker)
        if "source" in frame.columns:
            frame["source"] = frame["source"].fillna("UNKNOWN").astype(str)

    outputs: list[pd.DataFrame] = []
    decisions: dict[str, dict[str, object]] = {}
    counts = {PROVIDER_IDX_DIRECT: 0, PROVIDER_ZAPI: 0, "NONE": 0, "CONFLICT": 0, "PARTIAL": 0}
    coverage_values: list[float] = []

    for raw_ticker in universe:
        ticker = canonical_ticker(raw_ticker)
        requested = _requested_days(price_loader(ticker), lookback)
        ticker_rows = (
            frame.loc[frame["ticker"].eq(ticker)].copy()
            if not frame.empty and {"ticker", "source"}.issubset(frame.columns)
            else pd.DataFrame()
        )

        source_evaluations: list[dict[str, object]] = []
        if not ticker_rows.empty:
            for source, rows in ticker_rows.groupby("source", observed=True, sort=True):
                source_evaluations.append(_evaluate_source(ticker, str(source), rows, requested))

        direct = next(
            (item for item in source_evaluations if item.get("source") == DIRECT_IDX_SOURCE),
            _empty_evaluation(PROVIDER_IDX_DIRECT, DIRECT_IDX_SOURCE, len(requested)),
        )
        zapi_options = [item for item in source_evaluations if item.get("source") in ZAPI_SOURCES]
        zapi = max(zapi_options, key=_evidence_rank) if zapi_options else _empty_evaluation(
            PROVIDER_ZAPI, ZAPI_IDX_SOURCE, len(requested)
        )
        other_valid_zapi = [item for item in zapi_options if item is not zapi and bool(item.get("valid"))]
        zapi_internal_states = [_reconcile_evidence(zapi, other) for other in other_valid_zapi]
        zapi_internal_issue = next(
            (item for item in zapi_internal_states if item[0] != RECONCILIATION_AGREED),
            None,
        )

        evaluations = [direct, zapi]
        valid = [item for item in evaluations if bool(item.get("valid"))]
        reconciliation_state, reconciliation_reason = _reconcile_evidence(direct, zapi)
        if zapi_internal_issue and reconciliation_state in {
            RECONCILIATION_AGREED,
            RECONCILIATION_SINGLE_PROVIDER,
        }:
            reconciliation_state, internal_reason = zapi_internal_issue
            reconciliation_reason = f"ZAPI sources are not reconciled: {internal_reason}"
        conflict = reconciliation_state in _RECONCILIATION_BLOCKING_STATES
        chosen = max(valid, key=_evidence_rank) if valid else None
        alternate = next((item for item in evaluations if item is not chosen), None)

        if chosen is None:
            selection_state = SELECTION_NO_VALID
            reason = "no independently valid IDX-direct or ZAPI foreign dataset"
            counts["NONE"] += 1
        elif chosen.get("window_state") != FOREIGN_FULL:
            selection_state = SELECTION_PARTIAL
            reason = (
                f"{chosen['provider']} selected by validity/freshness/completeness; "
                f"requested window is {chosen['window_state']}"
            )
            counts["PARTIAL"] += 1
            counts[str(chosen["provider"])] += 1
        else:
            selection_state = str(chosen["provider"])
            reason = f"{chosen['provider']} selected by validity, freshness, completeness, and source authority"
            counts[str(chosen["provider"])] += 1
        if chosen is not None and conflict:
            counts["CONFLICT"] += 1

        metadata = {
            "foreign_provider_selected": str(chosen.get("provider")) if chosen else PROVIDER_NONE,
            "foreign_provider_selected_source": chosen.get("source") if chosen else None,
            "foreign_provider_alternate": alternate.get("provider") if alternate else None,
            "foreign_provider_alternate_source": alternate.get("source") if alternate else None,
            "foreign_alternate_latest_observation": alternate.get("latest_observation") if alternate else None,
            "foreign_alternate_latest_age": alternate.get("latest_age") if alternate else None,
            "foreign_alternate_window_state": alternate.get("window_state") if alternate else FOREIGN_MISSING,
            "foreign_alternate_data_freshness": alternate.get("freshness") if alternate else "MISSING",
            "foreign_provider_selection_state": selection_state,
            "foreign_provider_selection_reason": reason,
            "foreign_provider_reconciliation_state": reconciliation_state,
            "foreign_provider_reconciliation_reason": reconciliation_reason,
            "foreign_provider_conflict": bool(conflict) if chosen is not None else None,
            "foreign_requested_observations": int(chosen.get("requested_observations") or len(requested)) if chosen else int(len(requested)),
            "foreign_observed_observations": int(chosen.get("observed_observations") or 0) if chosen else 0,
            "foreign_window_coverage_ratio": float(chosen.get("coverage_ratio") or 0.0) if chosen else 0.0,
            "foreign_window_complete": bool(chosen and chosen.get("window_state") == FOREIGN_FULL),
            "foreign_window_state": str(chosen.get("window_state")) if chosen else FOREIGN_MISSING,
            "foreign_latest_observation": chosen.get("latest_observation") if chosen else None,
            "foreign_latest_age": chosen.get("latest_age") if chosen else None,
            "foreign_data_freshness": str(chosen.get("freshness")) if chosen else "MISSING",
            "foreign_data_available": bool(chosen and chosen.get("available")),
            "foreign_data_valid": bool(chosen and chosen.get("valid")),
            "foreign_provider_evidence": {
                PROVIDER_IDX_DIRECT: _public_evaluation(direct),
                PROVIDER_ZAPI: _public_evaluation(zapi),
            },
        }
        decisions[ticker] = {key: value for key, value in metadata.items() if key != "foreign_provider_evidence"}
        decisions[ticker]["provider_evidence"] = metadata["foreign_provider_evidence"]

        if chosen is None:
            outputs.append(_metadata_row(ticker, metadata))
            coverage_values.append(0.0)
            continue
        chosen_rows = chosen.get("rows")
        if not isinstance(chosen_rows, pd.DataFrame) or chosen_rows.empty:
            outputs.append(_metadata_row(ticker, metadata))
            coverage_values.append(0.0)
            continue
        selected = chosen_rows.copy()
        selected["flow_unit"] = str(chosen.get("flow_unit") or "UNKNOWN")
        selected["foreign_evidence_source"] = chosen.get("source")
        selected["foreign_evidence_selected"] = True
        for key, value in metadata.items():
            selected[key] = [value] * len(selected) if isinstance(value, dict) else value
        outputs.append(selected)
        coverage_values.append(100.0 * float(chosen.get("coverage_ratio") or 0.0))

    out = pd.concat(outputs, ignore_index=True) if outputs else pd.DataFrame()
    stats = {
        "idx_direct_selected_tickers": counts[PROVIDER_IDX_DIRECT],
        "zapi_selected_tickers": counts[PROVIDER_ZAPI],
        "other_selected_tickers": 0,
        "foreign_unavailable_tickers": counts["NONE"],
        "foreign_conflict_tickers": counts["CONFLICT"],
        "foreign_partial_only_tickers": counts["PARTIAL"],
        "median_selected_coverage_pct": float(pd.Series(coverage_values).median()) if coverage_values else 0.0,
        "provider_decisions": decisions,
        "policy": "COMPARE_VALIDITY_FRESHNESS_COMPLETENESS_AUTHORITY",
        "reconciliation_policy": "EXACT_COMPARABLE_EVIDENCE_NO_NUMERIC_TOLERANCE",
    }
    return out, stats
