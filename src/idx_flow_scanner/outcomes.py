from __future__ import annotations

from dataclasses import dataclass
import numpy as np
import pandas as pd


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
