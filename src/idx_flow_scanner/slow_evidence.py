from __future__ import annotations

from pathlib import Path
from typing import Iterable

import numpy as np
import pandas as pd

from .data import canonical_ticker

ROOT = Path(__file__).resolve().parents[2]
DEFAULT_STOCK_SNAPSHOT = ROOT / "data" / "cache" / "zapi_stock_summary_latest.csv.gz"
DEFAULT_OWNERSHIP_CACHE = ROOT / "data" / "cache" / "zapi_ownership_latest.csv.gz"
DEFAULT_CAPITAL_ACTION_CACHE = ROOT / "data" / "cache" / "zapi_capital_actions.csv.gz"


def _load_csv(path: Path, universe: Iterable[str] | None = None) -> pd.DataFrame:
    if not path.exists():
        return pd.DataFrame()
    try:
        frame = pd.read_csv(path)
    except Exception:
        return pd.DataFrame()
    frame.columns = [str(c).strip().lower() for c in frame.columns]
    if "ticker" in frame.columns:
        frame["ticker"] = frame["ticker"].map(canonical_ticker)
        if universe is not None:
            allowed = {canonical_ticker(t) for t in universe if canonical_ticker(t)}
            frame = frame[frame["ticker"].isin(allowed)].copy()
    return frame.reset_index(drop=True)


def load_bundled_zapi_stock_snapshot(
    universe: Iterable[str] | None = None,
    path: Path | None = None,
) -> pd.DataFrame:
    return _load_csv(path or DEFAULT_STOCK_SNAPSHOT, universe)


def load_bundled_zapi_ownership(
    universe: Iterable[str] | None = None,
    path: Path | None = None,
) -> pd.DataFrame:
    return _load_csv(path or DEFAULT_OWNERSHIP_CACHE, universe)


def load_bundled_zapi_capital_actions(
    universe: Iterable[str] | None = None,
    path: Path | None = None,
) -> pd.DataFrame:
    return _load_csv(path or DEFAULT_CAPITAL_ACTION_CACHE, universe)


def _free_float_score(free_float_pct: float | None) -> float:
    if free_float_pct is None or not np.isfinite(free_float_pct):
        return 50.0
    ff = float(free_float_pct)
    if ff < 7.5:
        return 15.0
    if ff < 15.0:
        return 58.0
    if ff <= 35.0:
        return 82.0
    if ff <= 60.0:
        return 68.0
    return 55.0


def _ownership_features(frame: pd.DataFrame | None) -> dict[str, object]:
    default = {
        "ownership_score": 50.0,
        "ownership_available": False,
        "ownership_report_date": None,
        "major_holder_pct": None,
        "reported_foreign_ownership_pct": None,
        "foreign_ownership_change_pct": None,
    }
    if frame is None or frame.empty:
        return default
    work = frame.copy()
    for col in ("report_date", "publication_date"):
        if col in work.columns:
            work[col] = pd.to_datetime(work[col], errors="coerce").dt.normalize()
    if "report_date" not in work.columns or work["report_date"].dropna().empty:
        return default
    latest = work["report_date"].max()
    current = work[work["report_date"].eq(latest)].copy()
    if current.empty:
        return default

    if "category" in current.columns:
        categories = current["category"].fillna("").astype(str).str.lower()
        if categories.eq("lima-persen").any():
            current = current[categories.eq("lima-persen")].copy()
        elif categories.eq("satu-persen").any():
            current = current[categories.eq("satu-persen")].copy()

    pct = pd.to_numeric(current.get("ownership_percentage"), errors="coerce")
    major = float(np.clip(pct.dropna().sum(), 0.0, 100.0)) if pct.notna().any() else None

    foreign_pct = None
    if "local_foreign_state" in current.columns and pct.notna().any():
        state = current["local_foreign_state"].fillna("").astype(str).str.upper()
        mask = state.str.contains("FOREIGN|ASING", regex=True)
        values = pd.to_numeric(current.loc[mask, "ownership_percentage"], errors="coerce")
        if values.notna().any():
            foreign_pct = float(np.clip(values.sum(), 0.0, 100.0))

    change = None
    older_dates = sorted(d for d in work["report_date"].dropna().unique() if d < latest)
    if foreign_pct is not None and older_dates and "local_foreign_state" in work.columns:
        previous = work[work["report_date"].eq(older_dates[-1])].copy()
        if "category" in previous.columns and "category" in current.columns:
            chosen = str(current.get("category", pd.Series([""])).iloc[0]).lower()
            previous = previous[previous["category"].fillna("").astype(str).str.lower().eq(chosen)]
        pstate = previous["local_foreign_state"].fillna("").astype(str).str.upper()
        pmask = pstate.str.contains("FOREIGN|ASING", regex=True)
        pvalues = pd.to_numeric(previous.loc[pmask, "ownership_percentage"], errors="coerce")
        if pvalues.notna().any():
            previous_foreign = float(np.clip(pvalues.sum(), 0.0, 100.0))
            change = float(foreign_pct - previous_foreign)

    score = 50.0
    if major is not None:
        if major > 92:
            score -= 12.0
        elif 20 <= major <= 80:
            score += 4.0
    if change is not None:
        score += float(np.clip(change * 2.5, -15.0, 15.0))

    return {
        "ownership_score": float(np.clip(score, 0.0, 100.0)),
        "ownership_available": True,
        "ownership_report_date": pd.Timestamp(latest).date().isoformat(),
        "major_holder_pct": major,
        "reported_foreign_ownership_pct": foreign_pct,
        "foreign_ownership_change_pct": change,
    }


def _corporate_action_features(
    frame: pd.DataFrame | None,
    *,
    as_of: pd.Timestamp,
) -> dict[str, object]:
    default = {
        "corporate_action_score": 50.0,
        "corporate_action_available": False,
        "recent_corporate_actions": [],
        "recent_dilution_pct": 0.0,
        "corporate_action_normalization_required": False,
        "slow_evidence_hard_block": False,
    }
    if frame is None or frame.empty:
        return default
    work = frame.copy()
    if "event_date" not in work.columns:
        return default
    work["event_date"] = pd.to_datetime(work["event_date"], errors="coerce").dt.normalize()
    work = work.dropna(subset=["event_date"])
    if work.empty:
        return default
    work["days_from_asof"] = (work["event_date"] - as_of.normalize()).dt.days
    recent = work[work["days_from_asof"].between(-45, 45)].copy()
    if recent.empty:
        return {**default, "corporate_action_available": True}

    event_type = recent.get("event_type", pd.Series("", index=recent.index)).fillna("").astype(str).str.upper()
    delta = pd.to_numeric(recent.get("delta_percent"), errors="coerce").fillna(0.0)
    dilution_mask = event_type.isin(
        {
            "RIGHTS_OFFERING",
            "RIGHTS_ISSUE",
            "ADDITIONAL_LISTING",
            "PRIVATE_PLACEMENT",
            "ISSUED_SHARES_OTHER",
            "WARRANT_EXERCISE",
            "CONVERSION",
        }
    ) & delta.gt(0)
    recent_dilution = float(delta[dilution_mask].max()) if dilution_mask.any() else 0.0
    near = recent["days_from_asof"].between(-30, 30)
    hard_block = bool((dilution_mask & near & delta.ge(15.0)).any())
    split_mask = event_type.isin({"STOCK_SPLIT", "REVERSE_STOCK_SPLIT"}) & recent["days_from_asof"].between(-15, 15)
    normalization_required = bool(split_mask.any())

    score = float(np.clip(55.0 - min(recent_dilution, 30.0) * 1.5, 10.0, 60.0))
    events = []
    for row in recent.sort_values("event_date").tail(8).to_dict("records"):
        events.append(
            {
                "event_type": str(row.get("event_type") or "UNKNOWN"),
                "event_date": pd.Timestamp(row["event_date"]).date().isoformat(),
                "delta_percent": float(row.get("delta_percent") or 0.0)
                if pd.notna(row.get("delta_percent"))
                else None,
            }
        )
    return {
        "corporate_action_score": score,
        "corporate_action_available": True,
        "recent_corporate_actions": events,
        "recent_dilution_pct": recent_dilution,
        "corporate_action_normalization_required": normalization_required,
        "slow_evidence_hard_block": hard_block,
    }


def compute_slow_evidence(
    ticker: str,
    price: pd.DataFrame,
    foreign_features: dict[str, object],
    *,
    stock_summary: pd.DataFrame | None = None,
    ownership: pd.DataFrame | None = None,
    capital_actions: pd.DataFrame | None = None,
) -> dict[str, object]:
    symbol = canonical_ticker(ticker)
    as_of = (
        pd.to_datetime(price["date"], errors="coerce").max()
        if price is not None and not price.empty and "date" in price.columns
        else pd.Timestamp.today().normalize()
    )

    stock = stock_summary.copy() if stock_summary is not None else pd.DataFrame()
    if not stock.empty and "ticker" in stock.columns:
        stock = stock[stock["ticker"].map(canonical_ticker).eq(symbol)].copy()
    listed = tradable = None
    snapshot_date = None
    if not stock.empty:
        date_col = "trade_date" if "trade_date" in stock.columns else "date" if "date" in stock.columns else None
        if date_col:
            stock[date_col] = pd.to_datetime(stock[date_col], errors="coerce").dt.normalize()
            stock = stock.sort_values(date_col)
            if stock[date_col].notna().any():
                snapshot_date = pd.Timestamp(stock[date_col].dropna().iloc[-1]).date().isoformat()
        row = stock.iloc[-1]
        raw_listed = pd.to_numeric(row.get("listed_shares"), errors="coerce")
        raw_tradable = pd.to_numeric(row.get("tradable_shares"), errors="coerce")
        listed = float(raw_listed) if pd.notna(raw_listed) and raw_listed > 0 else None
        tradable = float(raw_tradable) if pd.notna(raw_tradable) and raw_tradable > 0 else None

    free_float_pct = 100.0 * tradable / listed if listed and tradable and tradable <= listed * 1.05 else None
    float_turnover_20d_pct = None
    if tradable and price is not None and not price.empty and "volume" in price.columns:
        volume20 = pd.to_numeric(price["volume"], errors="coerce").tail(20).fillna(0.0).clip(lower=0.0).sum()
        float_turnover_20d_pct = float(100.0 * volume20 / tradable)
    foreign_net_to_float_20d_pct = None
    foreign_net20 = pd.to_numeric(foreign_features.get("foreign_net_20d"), errors="coerce")
    if tradable and pd.notna(foreign_net20):
        foreign_net_to_float_20d_pct = float(100.0 * float(foreign_net20) / tradable)

    own = ownership.copy() if ownership is not None else pd.DataFrame()
    if not own.empty and "ticker" in own.columns:
        own = own[own["ticker"].map(canonical_ticker).eq(symbol)].copy()
    ownership_features = _ownership_features(own)

    corp = capital_actions.copy() if capital_actions is not None else pd.DataFrame()
    if not corp.empty and "ticker" in corp.columns:
        corp = corp[corp["ticker"].map(canonical_ticker).eq(symbol)].copy()
    corporate_features = _corporate_action_features(corp, as_of=pd.Timestamp(as_of))

    return {
        "free_float_structure_score": _free_float_score(free_float_pct),
        "free_float_pct": free_float_pct,
        "listed_shares": listed,
        "tradable_shares": tradable,
        "float_snapshot_date": snapshot_date,
        "float_turnover_20d_pct": float_turnover_20d_pct,
        "foreign_net_to_float_20d_pct": foreign_net_to_float_20d_pct,
        **ownership_features,
        **corporate_features,
        "slow_evidence_available": bool(
            free_float_pct is not None
            or ownership_features["ownership_available"]
            or corporate_features["corporate_action_available"]
        ),
    }
