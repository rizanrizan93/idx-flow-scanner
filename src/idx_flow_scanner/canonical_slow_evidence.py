from __future__ import annotations

from datetime import date, timedelta
from typing import Any, Iterable

import numpy as np
import pandas as pd

from .data import canonical_ticker
from .slow_evidence import compute_slow_evidence as _compute_slow_evidence
from .slow_evidence_store import normalize_capital_actions, normalize_ownership

KSEI_PROVENANCE = "VERIFIED_KSEI_REGISTRATION_COMPOSITION"
CANONICAL_CAPITAL_PROVENANCE = "VERIFIED_IDX_CAPITAL_ACTION_EVIDENCE"


def _names(universe: Iterable[str]) -> list[str]:
    return list(dict.fromkeys(canonical_ticker(v) for v in universe if canonical_ticker(v)))


def _clean_ownership(frame: pd.DataFrame | None) -> pd.DataFrame:
    if frame is None or frame.empty:
        return pd.DataFrame()
    out = frame.copy()
    out.columns = [str(c).strip().lower() for c in out.columns]
    required = {"ticker", "category", "holder_identity_hash", "report_date", "provenance_state"}
    if not required.issubset(out.columns):
        return pd.DataFrame()
    out["ticker"] = out["ticker"].map(canonical_ticker)
    out["report_date"] = pd.to_datetime(out["report_date"], errors="coerce").dt.normalize()
    if "publication_date" in out.columns:
        out["publication_date"] = pd.to_datetime(out["publication_date"], errors="coerce").dt.normalize()
    else:
        out["publication_date"] = pd.NaT
    for col in ("shares_held", "ownership_percentage"):
        if col not in out.columns:
            out[col] = np.nan
        out[col] = pd.to_numeric(out[col], errors="coerce")
    for col in ("holder_name", "holder_classification", "holder_type", "local_foreign_state", "source_url"):
        if col not in out.columns:
            out[col] = None
    if "source_verified" not in out.columns:
        out["source_verified"] = False
    verified = out["source_verified"].fillna(False)
    if not pd.api.types.is_bool_dtype(verified):
        verified = verified.astype(str).str.strip().str.lower().isin({"1", "true", "yes", "y", "verified"})
    out["source_verified"] = verified
    out = out[
        out["ticker"].ne("")
        & out["report_date"].notna()
        & out["source_verified"]
        & out["ownership_percentage"].where(out["ownership_percentage"].notna(), 0).between(0, 100)
        & out["shares_held"].where(out["shares_held"].notna(), 0).ge(0)
    ].copy()
    return out.sort_values(["ticker", "report_date", "category"], kind="stable").reset_index(drop=True)


def _clean_capital(frame: pd.DataFrame | None) -> pd.DataFrame:
    if frame is None or frame.empty:
        return pd.DataFrame()
    out = frame.copy()
    out.columns = [str(c).strip().lower() for c in out.columns]
    if "provenance_state" not in out.columns:
        return pd.DataFrame()
    out = out[out["provenance_state"].astype(str).eq(CANONICAL_CAPITAL_PROVENANCE)].copy()
    if out.empty:
        return pd.DataFrame()
    # Reuse the existing validator by temporarily mapping canonical provenance
    # back to the legacy accepted factual provenance. The returned rows are facts;
    # no scoring or source identity is changed by this adapter.
    out["provenance_state"] = "VERIFIED_IDX_DATASET_VIA_ZAPI"
    return normalize_capital_actions(out)


def load_canonical_ownership(store: Any, universe: Iterable[str], *, lookback_days: int = 550) -> pd.DataFrame:
    names = _names(universe)
    if store is None or not names:
        return pd.DataFrame()
    since = (date.today() - timedelta(days=max(90, int(lookback_days)))).isoformat()
    rows: list[dict[str, object]] = []
    try:
        for start in range(0, len(names), 40):
            resp = (
                store.client.table("flow_ownership_evidence")
                .select("*")
                .in_("ticker", names[start:start + 40])
                .gte("report_date", since)
                .order("report_date")
                .execute()
            )
            rows.extend(resp.data or [])
    except Exception:
        return pd.DataFrame()
    return _clean_ownership(pd.DataFrame(rows)) if rows else pd.DataFrame()


def load_canonical_capital_actions(store: Any, universe: Iterable[str], *, lookback_days: int = 450) -> pd.DataFrame:
    names = _names(universe)
    if store is None or not names:
        return pd.DataFrame()
    since = (date.today() - timedelta(days=max(120, int(lookback_days)))).isoformat()
    rows: list[dict[str, object]] = []
    try:
        for start in range(0, len(names), 40):
            resp = (
                store.client.table("flow_capital_action_evidence")
                .select("*")
                .in_("ticker", names[start:start + 40])
                .gte("event_date", since)
                .order("event_date")
                .execute()
            )
            rows.extend(resp.data or [])
    except Exception:
        return pd.DataFrame()
    return _clean_capital(pd.DataFrame(rows)) if rows else pd.DataFrame()


def merge_canonical_ownership(database: pd.DataFrame, bundled: pd.DataFrame) -> pd.DataFrame:
    db = _clean_ownership(database)
    legacy = normalize_ownership(bundled)
    parts = [f for f in (legacy, db) if f is not None and not f.empty]
    if not parts:
        return pd.DataFrame()
    return pd.concat(parts, ignore_index=True, sort=False).drop_duplicates(
        ["ticker", "report_date", "category", "holder_identity_hash"], keep="last"
    ).sort_values(["ticker", "report_date", "category"], kind="stable").reset_index(drop=True)


def merge_canonical_capital_actions(database: pd.DataFrame, bundled: pd.DataFrame) -> pd.DataFrame:
    db = _clean_capital(database)
    legacy = normalize_capital_actions(bundled)
    parts = [f for f in (legacy, db) if f is not None and not f.empty]
    if not parts:
        return pd.DataFrame()
    return pd.concat(parts, ignore_index=True, sort=False).drop_duplicates(
        ["ticker", "event_type", "event_date", "source_feed"], keep="last"
    ).sort_values(["event_date", "ticker", "event_type"], kind="stable").reset_index(drop=True)


def _ksei_ownership_features(frame: pd.DataFrame) -> dict[str, object] | None:
    if frame is None or frame.empty or "provenance_state" not in frame.columns:
        return None
    ksei = frame[frame["provenance_state"].astype(str).eq(KSEI_PROVENANCE)].copy()
    if ksei.empty:
        return None
    ksei["report_date"] = pd.to_datetime(ksei["report_date"], errors="coerce").dt.normalize()
    ksei = ksei.dropna(subset=["report_date"])
    if ksei.empty:
        return None
    latest = ksei["report_date"].max()
    current = ksei[ksei["report_date"].eq(latest)].copy()
    cls = current.get("holder_classification", pd.Series("", index=current.index)).fillna("").astype(str).str.upper()
    foreign_rows = current[cls.eq("KSEI_FOREIGN_TOTAL")]
    foreign_pct = pd.to_numeric(foreign_rows.get("ownership_percentage"), errors="coerce").dropna()
    foreign = float(np.clip(foreign_pct.iloc[-1], 0.0, 100.0)) if not foreign_pct.empty else None

    change = None
    older = sorted(d for d in ksei["report_date"].dropna().unique() if d < latest)
    if foreign is not None and older:
        prev = ksei[ksei["report_date"].eq(older[-1])].copy()
        pcls = prev.get("holder_classification", pd.Series("", index=prev.index)).fillna("").astype(str).str.upper()
        pvals = pd.to_numeric(prev.loc[pcls.eq("KSEI_FOREIGN_TOTAL"), "ownership_percentage"], errors="coerce").dropna()
        if not pvals.empty:
            change = float(foreign - float(np.clip(pvals.iloc[-1], 0.0, 100.0)))

    score = 50.0
    if change is not None:
        score += float(np.clip(change * 2.5, -15.0, 15.0))
    return {
        "ownership_score": float(np.clip(score, 0.0, 100.0)),
        "ownership_available": True,
        "ownership_report_date": pd.Timestamp(latest).date().isoformat(),
        # KSEI registration composition is not a major-holder register. Do not
        # double-count scripless total + local + foreign as major-holder pct.
        "major_holder_pct": None,
        "reported_foreign_ownership_pct": foreign,
        "foreign_ownership_change_pct": change,
        "ownership_basis": "KSEI_REGISTRATION_COMPOSITION",
    }


def compute_slow_evidence_canonical(
    ticker: str,
    price: pd.DataFrame,
    foreign_features: dict[str, object],
    *,
    stock_summary: pd.DataFrame | None = None,
    ownership: pd.DataFrame | None = None,
    capital_actions: pd.DataFrame | None = None,
) -> dict[str, object]:
    base = _compute_slow_evidence(
        ticker,
        price,
        foreign_features,
        stock_summary=stock_summary,
        ownership=ownership,
        capital_actions=capital_actions,
    )
    symbol = canonical_ticker(ticker)
    own = ownership.copy() if ownership is not None else pd.DataFrame()
    if not own.empty and "ticker" in own.columns:
        own = own[own["ticker"].map(canonical_ticker).eq(symbol)].copy()
    ksei = _ksei_ownership_features(own)
    if ksei is not None:
        base.update(ksei)
    return base


__all__ = [
    "load_canonical_ownership",
    "load_canonical_capital_actions",
    "merge_canonical_ownership",
    "merge_canonical_capital_actions",
    "compute_slow_evidence_canonical",
]
