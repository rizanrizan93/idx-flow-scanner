from __future__ import annotations

from datetime import date, timedelta
from typing import Any, Mapping

import numpy as np
import pandas as pd

from .data import canonical_ticker

OFFICIAL_CONTROLLER_SOURCE = "IDX_OFFICIAL_COMPANY_PROFILE_SHAREHOLDER"
OFFICIAL_CONTROLLER_PROVENANCE = "VERIFIED_OFFICIAL_IDX_COMPANY_PROFILE_OBSERVED_SNAPSHOT"

_CONTROLLER_CONTEXT: pd.DataFrame | None = None


def load_official_controller_profiles(
    store: Any,
    universe: list[str] | tuple[str, ...] | None = None,
    *,
    lookback_calendar_days: int = 90,
) -> pd.DataFrame | None:
    """Load observed official IDX shareholder-profile snapshots.

    Company Profile exposes holder identity, percentage, category and explicit
    controller flags, but not an authoritative shareholder report date. We
    therefore preserve `observed_on` semantics and never pretend these rows are
    KSEI ownership-history observations.
    """
    if store is None:
        return None
    since = (date.today() - timedelta(days=max(14, int(lookback_calendar_days)))).isoformat()
    names = list(dict.fromkeys(canonical_ticker(v) for v in (universe or []) if canonical_ticker(v)))
    rows: list[dict[str, object]] = []
    try:
        if names:
            for start in range(0, len(names), 40):
                response = (
                    store.client.table("flow_official_shareholder_profiles")
                    .select("*")
                    .in_("ticker", names[start:start + 40])
                    .gte("observed_on", since)
                    .eq("source", OFFICIAL_CONTROLLER_SOURCE)
                    .eq("source_verified", True)
                    .order("observed_on")
                    .execute()
                )
                rows.extend(response.data or [])
        else:
            response = (
                store.client.table("flow_official_shareholder_profiles")
                .select("*")
                .gte("observed_on", since)
                .eq("source", OFFICIAL_CONTROLLER_SOURCE)
                .eq("source_verified", True)
                .order("observed_on")
                .limit(1000)
                .execute()
            )
            rows.extend(response.data or [])
    except Exception:
        return None
    if not rows:
        return pd.DataFrame()

    out = pd.DataFrame(rows)
    out.columns = [str(c).strip().lower() for c in out.columns]
    required = {
        "ticker", "observed_on", "holder_name", "ownership_percentage",
        "holder_category", "is_controller", "source", "source_verified", "provenance_state",
    }
    if not required.issubset(out.columns):
        return None
    out["ticker"] = out["ticker"].map(canonical_ticker)
    out["observed_on"] = pd.to_datetime(out["observed_on"], errors="coerce").dt.normalize()
    out["ownership_percentage"] = pd.to_numeric(out["ownership_percentage"], errors="coerce")
    out["shares_held"] = pd.to_numeric(out.get("shares_held"), errors="coerce")
    controller = out["is_controller"]
    if not pd.api.types.is_bool_dtype(controller):
        controller = controller.fillna(False).astype(str).str.strip().str.lower().isin({"1", "true", "yes"})
    out["is_controller"] = controller.fillna(False)
    verified = out["source_verified"]
    if not pd.api.types.is_bool_dtype(verified):
        verified = verified.fillna(False).astype(str).str.strip().str.lower().isin({"1", "true", "yes"})
    out = out[
        out["ticker"].ne("")
        & out["observed_on"].notna()
        & out["holder_name"].fillna("").astype(str).str.strip().ne("")
        & (out["ownership_percentage"].isna() | out["ownership_percentage"].between(0, 100))
        & verified.fillna(False)
        & out["source"].astype(str).eq(OFFICIAL_CONTROLLER_SOURCE)
        & out["provenance_state"].astype(str).eq(OFFICIAL_CONTROLLER_PROVENANCE)
    ].copy()
    return out.sort_values(["ticker", "observed_on", "holder_name"], kind="stable").reset_index(drop=True)


def set_official_controller_context(frame: pd.DataFrame | None) -> None:
    global _CONTROLLER_CONTEXT
    _CONTROLLER_CONTEXT = None if frame is None else frame.copy()


def _safe_sum(values: pd.Series) -> float | None:
    numeric = pd.to_numeric(values, errors="coerce").dropna()
    if numeric.empty:
        return None
    return float(np.clip(numeric.sum(), 0.0, 100.0))


def compute_official_controller_features(
    ticker: str,
    price: pd.DataFrame,
    profiles: pd.DataFrame | None,
) -> dict[str, object]:
    default = {
        "official_controller_profile_available": False,
        "official_controller_source": OFFICIAL_CONTROLLER_SOURCE,
        "official_controller_observed_on": None,
        "official_controller_snapshot_age_days": None,
        "official_controller_pct": None,
        "official_controller_count": 0,
        "official_profile_major_holder_pct": None,
        "official_insider_ownership_pct": None,
        "official_treasury_pct": None,
        "official_public_share_profile_pct": None,
        "official_public_share_profile_basis": "PUBLIC_SHARE_PROFILE_NOT_REGULATORY_FREE_FLOAT",
        "official_controller_structure_score": 50.0,
        "official_controller_holder_names": [],
    }
    if profiles is None or profiles.empty:
        return default
    symbol = canonical_ticker(ticker)
    work = profiles.copy()
    if "ticker" not in work.columns or "observed_on" not in work.columns:
        return default
    work["ticker"] = work["ticker"].map(canonical_ticker)
    work = work[work["ticker"].eq(symbol)].copy()
    if work.empty:
        return default
    work["observed_on"] = pd.to_datetime(work["observed_on"], errors="coerce").dt.normalize()
    work = work.dropna(subset=["observed_on"])
    if work.empty:
        return default

    price_as_of = (
        pd.to_datetime(price["date"], errors="coerce").max()
        if price is not None and not price.empty and "date" in price.columns
        else pd.NaT
    )
    latest = work["observed_on"].max()
    if pd.notna(price_as_of):
        # A weekend/after-close observation may legitimately follow the last
        # trading session. Older historical scans must not consume future snapshots.
        allowed = pd.Timestamp(price_as_of).normalize() + timedelta(days=3)
        eligible = work[work["observed_on"].le(allowed)].copy()
        if eligible.empty:
            return default
        latest = eligible["observed_on"].max()
        work = eligible[eligible["observed_on"].eq(latest)].copy()
        snapshot_age = int((pd.Timestamp(latest) - pd.Timestamp(price_as_of).normalize()).days)
    else:
        work = work[work["observed_on"].eq(latest)].copy()
        snapshot_age = None
    if work.empty:
        return default

    pct = pd.to_numeric(work["ownership_percentage"], errors="coerce")
    categories = work["holder_category"].fillna("").astype(str).str.strip().str.lower()
    controllers = work["is_controller"].fillna(False).astype(bool)
    controller_pct = _safe_sum(pct[controllers])
    controller_names = work.loc[controllers, "holder_name"].fillna("").astype(str).tolist()
    major_mask = categories.str.contains(r"lebih\s*dari\s*5|>\s*5|5%", regex=True)
    major_pct = _safe_sum(pct[major_mask])
    insider_mask = categories.str.contains(r"direksi|direktur|komisaris", regex=True)
    insider_pct = _safe_sum(pct[insider_mask])
    treasury_mask = categories.str.contains(r"treasury", regex=True)
    treasury_pct = _safe_sum(pct[treasury_mask])
    public_mask = categories.str.contains(r"masyarakat", regex=True)
    public_pct = _safe_sum(pct[public_mask])

    score = 50.0
    if controller_pct is not None:
        if controller_pct > 95.0:
            score -= 18.0
        elif controller_pct > 90.0:
            score -= 6.0
        elif 15.0 <= controller_pct <= 85.0:
            score += 8.0
        elif 5.0 <= controller_pct < 15.0:
            score += 2.0
    if major_pct is not None:
        if major_pct > 95.0:
            score -= 10.0
        elif 20.0 <= major_pct <= 90.0:
            score += 4.0
    if treasury_pct is not None:
        if treasury_pct > 5.0:
            score -= 10.0
        elif treasury_pct > 1.0:
            score -= 3.0

    return {
        **default,
        "official_controller_profile_available": True,
        "official_controller_observed_on": pd.Timestamp(latest).date().isoformat(),
        "official_controller_snapshot_age_days": snapshot_age,
        "official_controller_pct": controller_pct,
        "official_controller_count": int(controllers.sum()),
        "official_profile_major_holder_pct": major_pct,
        "official_insider_ownership_pct": insider_pct,
        "official_treasury_pct": treasury_pct,
        "official_public_share_profile_pct": public_pct,
        "official_controller_structure_score": float(np.clip(score, 0.0, 100.0)),
        "official_controller_holder_names": controller_names[:10],
    }


def apply_official_controller_overlay(
    ticker: str,
    price: pd.DataFrame,
    base_features: Mapping[str, object],
    *,
    profiles: pd.DataFrame | None = None,
) -> dict[str, object]:
    """Blend official controller structure into the existing ownership factor.

    KSEI remains authoritative for registration-composition history. This layer
    contributes a distinct identity/controller dimension and never turns public
    share profile percentages into regulatory free float.
    """
    out = dict(base_features)
    source_frame = _CONTROLLER_CONTEXT if profiles is None else profiles
    features = compute_official_controller_features(ticker, price, source_frame)
    out.update(features)
    if not bool(features.get("official_controller_profile_available", False)):
        return out

    official = float(features.get("official_controller_structure_score", 50.0) or 50.0)
    base_available = bool(out.get("ownership_available", False))
    if base_available:
        base_score = float(out.get("ownership_score", 50.0) or 50.0)
        blended = 0.60 * base_score + 0.40 * official
        basis = "KSEI_60__IDX_CONTROLLER_PROFILE_40"
    else:
        blended = official
        basis = "IDX_CONTROLLER_PROFILE_ONLY"
    out["ownership_score"] = float(np.clip(blended, 0.0, 100.0))
    out["ownership_available"] = True
    out["ownership_score_basis"] = basis
    out["slow_evidence_available"] = True
    return out


__all__ = [
    "OFFICIAL_CONTROLLER_SOURCE",
    "OFFICIAL_CONTROLLER_PROVENANCE",
    "load_official_controller_profiles",
    "set_official_controller_context",
    "compute_official_controller_features",
    "apply_official_controller_overlay",
]
