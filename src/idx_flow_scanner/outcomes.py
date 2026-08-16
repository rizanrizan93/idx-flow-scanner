from __future__ import annotations

from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from typing import Callable, Iterable, Any

import numpy as np
import pandas as pd

from .data import canonical_ticker


@dataclass(frozen=True)
class SignalOutcome:
    entry_close: float | None
    return_5d: float | None
    return_20d: float | None
    return_60d: float | None
    mfe_20d: float | None
    mae_20d: float | None
    evaluated_through: str | None
    evaluation_status: str


def _pct(value: float, base: float) -> float:
    return 100.0 * (value / base - 1.0)


def compute_signal_outcome(price: pd.DataFrame, as_of_date: str | pd.Timestamp) -> SignalOutcome:
    """Strictly forward walk-forward evaluation; never used by signal generation itself."""
    if price is None or price.empty:
        return SignalOutcome(None,None,None,None,None,None,None,"PENDING")
    px=price.copy(); px["date"]=pd.to_datetime(px["date"],errors="coerce").dt.normalize()
    px=px.dropna(subset=["date","close"]).drop_duplicates("date",keep="last").sort_values("date").reset_index(drop=True)
    target=pd.Timestamp(as_of_date).normalize(); matches=px.index[px["date"]>=target]
    if len(matches)==0:
        return SignalOutcome(None,None,None,None,None,None,None,"PENDING")
    i=int(matches[0]); entry=float(px.loc[i,"close"])
    if not np.isfinite(entry) or entry<=0:
        return SignalOutcome(None,None,None,None,None,None,None,"PENDING")
    def ret_at(step:int)->float|None:
        j=i+step
        if j>=len(px): return None
        value=float(px.loc[j,"close"])
        return _pct(value,entry) if np.isfinite(value) else None
    r5,r20,r60=ret_at(5),ret_at(20),ret_at(60)
    end20=min(i+20,len(px)-1); future20=px.iloc[i+1:end20+1]; mfe=mae=None
    if not future20.empty:
        highs=pd.to_numeric(future20.get("high"),errors="coerce"); lows=pd.to_numeric(future20.get("low"),errors="coerce")
        if highs.notna().any(): mfe=_pct(float(highs.max()),entry)
        if lows.notna().any(): mae=_pct(float(lows.min()),entry)
    status="COMPLETE" if r60 is not None else ("PARTIAL" if r5 is not None or r20 is not None else "PENDING")
    through=px["date"].iloc[-1].date().isoformat() if len(px) else None
    return SignalOutcome(entry,r5,r20,r60,mfe,mae,through,status)


def _finite_or_none(value: object) -> float | None:
    try:
        out=float(value)
        return out if np.isfinite(out) else None
    except (TypeError,ValueError):
        return None


def seed_signal_outcomes(
    store: Any,
    run_id: str,
    results: pd.DataFrame,
    price_loader: Callable[[str], pd.DataFrame],
) -> int:
    """Register today's signals for future OOS scoring without feeding outcomes back into the signal."""
    if store is None or results is None or results.empty:
        return 0
    rows=[]
    for row in results.to_dict("records"):
        ticker=canonical_ticker(row.get("ticker")); as_of=row.get("as_of_date")
        if not ticker or not as_of:
            continue
        outcome=compute_signal_outcome(price_loader(ticker),as_of)
        rows.append({
            "run_id":run_id,"ticker":ticker,"as_of_date":str(as_of),"phase":str(row.get("phase") or "UNKNOWN"),
            "evidence_tier":str(row.get("evidence_tier") or "PRICE_PROXY"),"final_score":_finite_or_none(row.get("final_score")) or 0.0,
            "entry_close":_finite_or_none(outcome.entry_close),"return_5d":_finite_or_none(outcome.return_5d),
            "return_20d":_finite_or_none(outcome.return_20d),"return_60d":_finite_or_none(outcome.return_60d),
            "mfe_20d":_finite_or_none(outcome.mfe_20d),"mae_20d":_finite_or_none(outcome.mae_20d),
            "evaluated_through":outcome.evaluated_through,"evaluation_status":outcome.evaluation_status,
            "evaluated_at":datetime.now(timezone.utc).isoformat() if outcome.evaluation_status!="PENDING" else None,
        })
    for i in range(0,len(rows),500):
        store.client.table("flow_signal_outcomes").upsert(rows[i:i+500],on_conflict="run_id,ticker").execute()
    return len(rows)


def refresh_pending_outcomes(
    store: Any,
    universe: Iterable[str],
    price_loader: Callable[[str], pd.DataFrame],
    *,
    limit: int = 2000,
) -> dict[str,int]:
    """Advance historical PENDING/PARTIAL outcomes using only bars now available after the signal date."""
    if store is None:
        return {"checked":0,"updated":0,"complete":0}
    names=set(canonical_ticker(t) for t in universe if canonical_ticker(t))
    response=(store.client.table("flow_signal_outcomes")
              .select("run_id,ticker,as_of_date,evaluation_status,evaluated_through")
              .in_("evaluation_status",["PENDING","PARTIAL"])
              .order("as_of_date").limit(int(limit)).execute())
    pending=[r for r in (response.data or []) if canonical_ticker(r.get("ticker")) in names]
    updates=[]; complete=0
    for row in pending:
        ticker=canonical_ticker(row.get("ticker")); as_of=row.get("as_of_date")
        outcome=compute_signal_outcome(price_loader(ticker),as_of)
        current_status=str(row.get("evaluation_status") or "PENDING")
        current_through=str(row.get("evaluated_through") or "")
        if outcome.evaluation_status==current_status and str(outcome.evaluated_through or "")==current_through:
            continue
        payload={
            "run_id":row["run_id"],"ticker":ticker,
            "entry_close":_finite_or_none(outcome.entry_close),"return_5d":_finite_or_none(outcome.return_5d),
            "return_20d":_finite_or_none(outcome.return_20d),"return_60d":_finite_or_none(outcome.return_60d),
            "mfe_20d":_finite_or_none(outcome.mfe_20d),"mae_20d":_finite_or_none(outcome.mae_20d),
            "evaluated_through":outcome.evaluated_through,"evaluation_status":outcome.evaluation_status,
            "evaluated_at":datetime.now(timezone.utc).isoformat() if outcome.evaluation_status!="PENDING" else None,
        }
        updates.append(payload); complete+=int(outcome.evaluation_status=="COMPLETE")
    for i in range(0,len(updates),500):
        store.client.table("flow_signal_outcomes").upsert(updates[i:i+500],on_conflict="run_id,ticker").execute()
    return {"checked":len(pending),"updated":len(updates),"complete":complete}
