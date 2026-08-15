from __future__ import annotations

import math
import numpy as np
import pandas as pd

from ..config import ScannerConfig


def _clip_score(x: float) -> float:
    if not np.isfinite(x):
        return 50.0
    return float(np.clip(x, 0.0, 100.0))


def _sigmoid_score(x: float, scale: float = 1.0) -> float:
    if not np.isfinite(x):
        return 50.0
    z = float(np.clip(x / max(scale, 1e-9), -12, 12))
    return 100.0 / (1.0 + math.exp(-z))


def broker_coverage_pct(broker: pd.DataFrame, price: pd.DataFrame, lookback: int = 20) -> float:
    if broker is None or broker.empty or price is None or price.empty:
        return 0.0
    px_days = pd.DatetimeIndex(price["date"].dropna().unique())[-lookback:]
    if not len(px_days):
        return 0.0
    br_days = pd.DatetimeIndex(broker["trade_date"].dropna().unique())
    overlap = len(px_days.intersection(br_days))
    return float(100.0 * overlap / len(px_days))


def compute_broker_features(broker: pd.DataFrame, price: pd.DataFrame, config: ScannerConfig) -> dict[str, float | int | list[str] | None]:
    if broker is None or broker.empty:
        return {"broker_days":0,"coverage_pct":0.0,"accumulation_score":0.0,"operator_dominance_score":0.0,"supply_concentration_score":0.0,"estimated_smart_money_cost":None,"premium_to_cost_pct":None,"cost_basis_score":0.0,"distribution_risk":50.0,"top_accumulating_brokers":[],"top_distributing_brokers":[],"net_value_5d":0.0,"net_value_20d":0.0,"net_value_60d":0.0,"persistence_20d":0.0}
    b=broker.sort_values("trade_date").copy(); unique_days=pd.DatetimeIndex(b["trade_date"].unique()); day_map={}
    for w in config.windows:
        days=unique_days[-w:]; day_map[w]=b[b["trade_date"].isin(days)]
    totals={w:float(day_map.get(w,b.iloc[0:0])["net_value"].sum()) for w in config.windows}
    gross20=float(day_map.get(20,b)["gross_value"].sum()); net_intensity20=totals.get(20,0.0)/max(gross20,1.0)
    daily_net=day_map.get(20,b).groupby("trade_date",observed=True)["net_value"].sum(); persistence20=float((daily_net>0).mean()) if len(daily_net) else 0.0
    by_broker20=day_map.get(20,b).groupby("broker_code",observed=True).agg(net_value=("net_value","sum"),buy_value=("buy_value","sum"),sell_value=("sell_value","sum"),buy_volume=("buy_volume","sum"))
    positives=by_broker20[by_broker20["net_value"]>0].sort_values("net_value",ascending=False); negatives=by_broker20[by_broker20["net_value"]<0].sort_values("net_value")
    positive_total=float(positives["net_value"].sum()); top_pos=positives.head(config.top_brokers); concentration=float(top_pos["net_value"].sum()/positive_total) if positive_total>0 else 0.0
    accumulation_score=_clip_score(0.55*_sigmoid_score(net_intensity20,0.04)+45.0*persistence20)
    operator_dominance_score=_clip_score(60.0*concentration+40.0*min(1.0,abs(net_intensity20)/0.08)); supply_concentration_score=_clip_score(100.0*concentration)
    cost_num=0.0; cost_den=0.0
    for broker_code in top_pos.index:
        rows=day_map.get(60,b); rows=rows[rows["broker_code"]==broker_code]; net_vol=rows["net_volume"].clip(lower=0).fillna(0); avg=rows["buy_avg"].replace([np.inf,-np.inf],np.nan); valid=(net_vol>0)&avg.notna()&(avg>0); cost_num+=float((net_vol[valid]*avg[valid]).sum()); cost_den+=float(net_vol[valid].sum())
    est_cost=cost_num/cost_den if cost_den>0 else None; last_close=float(price["close"].dropna().iloc[-1]) if price is not None and not price.empty else np.nan; premium=(100.0*(last_close/est_cost-1.0)) if est_cost and np.isfinite(last_close) else None
    if premium is None: cost_basis_score=35.0
    elif premium<=0: cost_basis_score=95.0
    elif premium<=5: cost_basis_score=90.0
    elif premium<=15: cost_basis_score=80.0
    elif premium<=30: cost_basis_score=60.0
    elif premium<=config.max_price_extension_from_cost_pct: cost_basis_score=45.0
    else: cost_basis_score=20.0
    by5=day_map.get(5,b).groupby("broker_code",observed=True)["net_value"].sum(); reversal_value=0.0; accumulated_value=0.0
    for code,row in top_pos.iterrows():
        acc=float(row["net_value"]); accumulated_value+=max(acc,0.0); recent=float(by5.get(code,0.0)); reversal_value += min(abs(recent),acc) if recent<0 else 0.0
    reversal_ratio=reversal_value/max(accumulated_value,1.0); extension_penalty=0.0 if premium is None else float(np.clip((premium-20.0)/30.0,0.0,1.0)); distribution_risk=_clip_score(70.0*reversal_ratio+30.0*extension_penalty)
    return {"broker_days":int(len(unique_days)),"coverage_pct":broker_coverage_pct(b,price,20),"accumulation_score":accumulation_score,"operator_dominance_score":operator_dominance_score,"supply_concentration_score":supply_concentration_score,"estimated_smart_money_cost":float(est_cost) if est_cost else None,"premium_to_cost_pct":float(premium) if premium is not None else None,"cost_basis_score":float(cost_basis_score),"distribution_risk":distribution_risk,"top_accumulating_brokers":top_pos.index.astype(str).tolist(),"top_distributing_brokers":negatives.head(config.top_brokers).index.astype(str).tolist(),"net_value_5d":totals.get(5,0.0),"net_value_20d":totals.get(20,0.0),"net_value_60d":totals.get(60,0.0),"persistence_20d":persistence20}


def compute_price_flow_features(price: pd.DataFrame, broker_features: dict[str, object]) -> dict[str, float]:
    if price is None or len(price)<20:
        return {"retail_exhaustion_score":30.0,"price_flow_divergence_score":30.0,"risk_liquidity_score":30.0,"proxy_accumulation_score":30.0,"proxy_absorption_score":30.0,"proxy_supply_tightness_score":30.0,"proxy_distribution_risk":50.0}
    px=price.sort_values("date").copy(); close=px["close"].astype(float); high=px["high"].astype(float); low=px["low"].astype(float); volume=px["volume"].fillna(0).astype(float).clip(lower=0); ret=close.pct_change(); price_20=float(close.iloc[-1]/close.iloc[-20]-1.0)
    vol20=float(ret.tail(20).std(ddof=0)) if ret.tail(20).notna().sum()>=10 else np.nan; vol60=float(ret.tail(60).std(ddof=0)) if ret.tail(60).notna().sum()>=20 else vol20; compression=0.5 if not (np.isfinite(vol20) and np.isfinite(vol60) and vol60>0) else float(np.clip(1-vol20/vol60,-1,1))
    rng=(high-low).replace(0,np.nan); close_pos=((close-low)/rng).replace([np.inf,-np.inf],np.nan).fillna(0.5).clip(0,1); mfm=(((close-low)-(high-close))/rng).replace([np.inf,-np.inf],np.nan).fillna(0.0); mfv=mfm*volume; v20=float(volume.tail(20).sum()); cmf20=float(mfv.tail(20).sum()/v20) if v20>0 else 0.0
    signed=np.sign(ret.fillna(0.0))*volume; obv=signed.cumsum(); obv20=obv.tail(20)
    if len(obv20)>=5 and float(volume.tail(20).mean())>0:
        x=np.arange(len(obv20),dtype=float); slope=float(np.polyfit(x,obv20.to_numpy(dtype=float),1)[0]); obv_slope_norm=slope/float(volume.tail(20).mean())
    else: obv_slope_norm=0.0
    value20=(close*volume).tail(20); ret20=ret.tail(20); total_value20=float(value20.sum()); up_value_ratio=float(value20[ret20>0].sum()/total_value20) if total_value20>0 else 0.5; avg_vol20=float(volume.tail(20).mean()); absorption=((ret.abs()<=0.02)&(volume>=1.25*max(avg_vol20,1.0))&(close_pos>=0.55)).tail(20); absorption_ratio=float(absorption.mean()) if len(absorption) else 0.0; acceptance20=float(close_pos.tail(20).mean())
    cmf_score=_sigmoid_score(cmf20,0.08); obv_score=_sigmoid_score(obv_slope_norm,0.25); up_value_score=_clip_score(up_value_ratio*100.0); acceptance_score=_clip_score(acceptance20*100.0); absorption_score=_clip_score(35.0+180.0*absorption_ratio+20.0*max(compression,0.0)); proxy_accumulation=_clip_score(0.30*cmf_score+0.24*obv_score+0.20*up_value_score+0.14*acceptance_score+0.12*absorption_score); proxy_supply_tightness=_clip_score(40.0*max(compression,0.0)+35.0*acceptance20+25.0*absorption_ratio*4.0); proxy_distribution=_clip_score(50.0+40.0*max(-cmf20,0.0)+22.0*max(-obv_slope_norm,0.0)+100.0*max(-price_20-0.08,0.0)-25.0*absorption_ratio)
    direct_acc=float(broker_features.get("accumulation_score",0.0) or 0.0); persistence=float(broker_features.get("persistence_20d",0.0) or 0.0); effective_acc=direct_acc if int(broker_features.get("broker_days",0) or 0)>0 else proxy_accumulation; flatness=float(np.clip(1-abs(price_20)/0.12,0,1)); retail_exhaustion=_clip_score(45*flatness+25*max(compression,0)+20*persistence+10*absorption_score/100.0); divergence=_clip_score(50+0.45*(effective_acc-50)-150*price_20); adv=float(value20.mean()) if len(value20) else 0.0; liq=_sigmoid_score(np.log10(max(adv,1.0))-8.3,0.7); risk=50.0 if not np.isfinite(vol20) else _clip_score(100-1200*max(vol20-0.02,0)); risk_liquidity=_clip_score(0.6*liq+0.4*risk)
    return {"retail_exhaustion_score":retail_exhaustion,"price_flow_divergence_score":divergence,"risk_liquidity_score":risk_liquidity,"price_return_20d":price_20*100.0,"realized_vol_20d":float(vol20) if np.isfinite(vol20) else np.nan,"avg_traded_value_20d":adv,"proxy_accumulation_score":proxy_accumulation,"proxy_absorption_score":absorption_score,"proxy_supply_tightness_score":proxy_supply_tightness,"proxy_distribution_risk":proxy_distribution,"proxy_cmf20":cmf20,"proxy_obv_slope_norm20":obv_slope_norm,"proxy_up_value_ratio20":up_value_ratio,"proxy_close_acceptance20":acceptance20,"proxy_absorption_ratio20":absorption_ratio}
