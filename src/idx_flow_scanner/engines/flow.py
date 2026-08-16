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
    px_days = pd.DatetimeIndex(pd.to_datetime(price["date"], errors="coerce").dropna().unique())[-lookback:]
    if not len(px_days):
        return 0.0
    br_days = pd.DatetimeIndex(pd.to_datetime(broker["trade_date"], errors="coerce").dropna().unique())
    overlap = len(px_days.intersection(br_days))
    return float(100.0 * overlap / len(px_days))


def _window_broker_stats(frame: pd.DataFrame) -> pd.DataFrame:
    if frame is None or frame.empty:
        return pd.DataFrame(columns=["net_value", "buy_value", "sell_value", "buy_volume", "sell_volume", "gross_value"])
    return frame.groupby("broker_code", observed=True).agg(
        net_value=("net_value", "sum"), buy_value=("buy_value", "sum"), sell_value=("sell_value", "sum"),
        buy_volume=("buy_volume", "sum"), sell_volume=("sell_volume", "sum"), gross_value=("gross_value", "sum"),
    )


def _weighted_persistence(frame: pd.DataFrame, cohort: pd.Index, weights: pd.Series) -> float:
    if frame.empty or len(cohort) == 0:
        return 0.0
    values, wts = [], []
    for code in cohort:
        rows = frame[frame["broker_code"] == code]
        if rows.empty:
            continue
        daily = rows.groupby("trade_date", observed=True)["net_value"].sum()
        persistence = float((daily > 0).mean()) if len(daily) else 0.0
        weight = max(float(weights.get(code, 0.0)), 0.0)
        if weight > 0:
            values.append(persistence); wts.append(weight)
    if not wts or sum(wts) <= 0:
        return 0.0
    return float(np.average(values, weights=wts))


def compute_broker_features(broker: pd.DataFrame, price: pd.DataFrame, config: ScannerConfig) -> dict[str, float | int | list[str] | str | None]:
    """Direct broker features based on persistent net-buy cohorts, not aggregate net flow.

    Broker summary is a closed system: aggregate net across all brokers should be near zero.
    Accumulation is therefore inferred from concentration, persistence, stability and inventory
    cost of the dominant net-buy cohort, while reversals of that cohort drive distribution risk.
    """
    empty = {
        "broker_days":0,"coverage_pct":0.0,"accumulation_score":0.0,"accumulation_quality_score":0.0,
        "operator_dominance_score":0.0,"supply_concentration_score":0.0,"estimated_smart_money_cost":None,
        "premium_to_cost_pct":None,"cost_basis_score":0.0,"cost_position":"UNKNOWN","distribution_risk":50.0,
        "top_accumulating_brokers":[],"top_distributing_brokers":[],"net_value_5d":0.0,"net_value_20d":0.0,
        "net_value_60d":0.0,"persistence_5d":0.0,"persistence_20d":0.0,"persistence_60d":0.0,
        "broker_cohort_stability":0.0,"broker_hhi":0.0,"net_conversion_ratio":0.0,"reversal_ratio_5d":0.0,
        "broker_balance_error_pct":100.0,
    }
    if broker is None or broker.empty:
        return empty
    b = broker.sort_values("trade_date").copy()
    unique_days = pd.DatetimeIndex(pd.to_datetime(b["trade_date"], errors="coerce").dropna().unique())
    if len(unique_days) == 0:
        return empty
    day_map, stats_map = {}, {}
    for w in config.windows:
        days = unique_days[-w:]
        win = b[b["trade_date"].isin(days)].copy()
        day_map[w] = win; stats_map[w] = _window_broker_stats(win)

    stats20 = stats_map.get(20, pd.DataFrame())
    positives20 = stats20[stats20["net_value"] > 0].sort_values("net_value", ascending=False)
    negatives20 = stats20[stats20["net_value"] < 0].sort_values("net_value")
    top_pos20 = positives20.head(config.top_brokers); top_neg20 = negatives20.head(config.top_brokers)
    positive_total20 = float(positives20["net_value"].sum()) if not positives20.empty else 0.0
    top_positive20 = float(top_pos20["net_value"].sum()) if not top_pos20.empty else 0.0
    concentration20 = top_positive20 / positive_total20 if positive_total20 > 0 else 0.0
    market_turnover20 = float(day_map.get(20, b)["gross_value"].sum()) / 2.0
    net_conversion20 = positive_total20 / max(market_turnover20, 1.0)
    top_intensity20 = top_positive20 / max(market_turnover20, 1.0)
    intensity_score = _sigmoid_score(top_intensity20 - 0.08, 0.05)

    if positive_total20 > 0:
        shares = (positives20["net_value"] / positive_total20).clip(lower=0)
        hhi = float((shares ** 2).sum())
    else:
        hhi = 0.0
    hhi_score = _clip_score(100.0 * np.sqrt(max(hhi, 0.0)))

    persistence, top_sets, cohort_values = {}, {}, {}
    for w in config.windows:
        stats = stats_map.get(w, pd.DataFrame())
        pos = stats[stats["net_value"] > 0].sort_values("net_value", ascending=False) if not stats.empty else stats
        top = pos.head(config.top_brokers) if not pos.empty else pos
        top_sets[w] = set(top.index.astype(str)) if not top.empty else set()
        cohort_values[w] = float(top["net_value"].sum()) if not top.empty else 0.0
        persistence[w] = _weighted_persistence(day_map.get(w, b.iloc[0:0]), top.index, top["net_value"]) if not top.empty else 0.0

    set5, set20, set60 = top_sets.get(5,set()), top_sets.get(20,set()), top_sets.get(60,set())
    overlap_5_20 = len(set5 & set20) / max(len(set20), 1)
    overlap_20_60 = len(set20 & set60) / max(len(set20), 1) if set60 else overlap_5_20
    cohort_stability = float(np.clip(0.6 * overlap_5_20 + 0.4 * overlap_20_60, 0.0, 1.0))
    persistence20 = persistence.get(20, 0.0)
    persistence_score = 100.0 * persistence20
    stability_score = 100.0 * cohort_stability
    concentration_score = _clip_score(100.0 * concentration20)
    conversion_score = _clip_score(100.0 * min(net_conversion20 / 0.35, 1.0))
    accumulation_quality = _clip_score(0.34*persistence_score + 0.24*intensity_score + 0.18*stability_score + 0.14*concentration_score + 0.10*conversion_score)
    accumulation_score = _clip_score(0.58*accumulation_quality + 0.22*persistence_score + 0.20*intensity_score)
    operator_dominance_score = _clip_score(0.45*concentration_score + 0.30*hhi_score + 0.25*stability_score)
    supply_concentration_score = _clip_score(0.60*concentration_score + 0.40*hhi_score)

    cost_num = 0.0; cost_den = 0.0; rows60 = day_map.get(60, b)
    for broker_code in top_pos20.index:
        rows = rows60[rows60["broker_code"] == broker_code]
        net_vol = rows["net_volume"].clip(lower=0).fillna(0)
        avg = rows["buy_avg"].replace([np.inf,-np.inf], np.nan)
        valid = (net_vol > 0) & avg.notna() & (avg > 0)
        cost_num += float((net_vol[valid] * avg[valid]).sum()); cost_den += float(net_vol[valid].sum())
    est_cost = cost_num / cost_den if cost_den > 0 else None
    last_close = float(price["close"].dropna().iloc[-1]) if price is not None and not price.empty else np.nan
    premium = 100.0 * (last_close / est_cost - 1.0) if est_cost and np.isfinite(last_close) else None
    if premium is None: cost_basis_score, cost_position = 35.0, "UNKNOWN"
    elif premium <= -5: cost_basis_score, cost_position = 95.0, "UNDER_COST"
    elif premium <= 5: cost_basis_score, cost_position = 92.0, "NEAR_COST"
    elif premium <= 15: cost_basis_score, cost_position = 82.0, "HEALTHY_MARKUP"
    elif premium <= 30: cost_basis_score, cost_position = 62.0, "MARKUP"
    elif premium <= config.max_price_extension_from_cost_pct: cost_basis_score, cost_position = 45.0, "EXTENDED"
    else: cost_basis_score, cost_position = 20.0, "OVEREXTENDED"

    stats5 = stats_map.get(5, pd.DataFrame()); reversal_value = 0.0; accumulated_value = 0.0
    for code,row in top_pos20.iterrows():
        acc = max(float(row["net_value"]), 0.0); accumulated_value += acc
        recent = float(stats5.loc[code,"net_value"]) if not stats5.empty and code in stats5.index else 0.0
        if recent < 0: reversal_value += min(abs(recent), acc)
    reversal_ratio = reversal_value / max(accumulated_value, 1.0)
    extension_penalty = 0.0 if premium is None else float(np.clip((premium - 20.0) / 30.0, 0.0, 1.0))
    distribution_risk = _clip_score(62.0*reversal_ratio + 23.0*extension_penalty + 15.0*(1.0-cohort_stability))

    win20 = day_map.get(20, b); total_buy = float(win20["buy_value"].sum()); total_sell = float(win20["sell_value"].sum())
    balance_error_pct = 100.0 * abs(total_buy-total_sell) / max((total_buy+total_sell)/2.0, 1.0)
    return {
        "broker_days":int(len(unique_days)),"coverage_pct":broker_coverage_pct(b,price,20),"accumulation_score":accumulation_score,
        "accumulation_quality_score":accumulation_quality,"operator_dominance_score":operator_dominance_score,
        "supply_concentration_score":supply_concentration_score,"estimated_smart_money_cost":float(est_cost) if est_cost else None,
        "premium_to_cost_pct":float(premium) if premium is not None else None,"cost_basis_score":float(cost_basis_score),
        "cost_position":cost_position,"distribution_risk":distribution_risk,"top_accumulating_brokers":top_pos20.index.astype(str).tolist(),
        "top_distributing_brokers":top_neg20.index.astype(str).tolist(),"net_value_5d":cohort_values.get(5,0.0),
        "net_value_20d":cohort_values.get(20,0.0),"net_value_60d":cohort_values.get(60,0.0),"persistence_5d":persistence.get(5,0.0),
        "persistence_20d":persistence20,"persistence_60d":persistence.get(60,0.0),"broker_cohort_stability":cohort_stability,
        "broker_hhi":hhi,"net_conversion_ratio":net_conversion20,"reversal_ratio_5d":reversal_ratio,"broker_balance_error_pct":balance_error_pct,
    }


def compute_official_foreign_features(flow: pd.DataFrame, price: pd.DataFrame, lookback: int = 20) -> dict[str, float | int]:
    """Score official per-stock foreign flow with dimensionally consistent units.

    IDX ``ForeignBuy``/``ForeignSell`` are shares. Therefore foreign intensity is
    net foreign shares divided by total traded shares, never divided by traded IDR.
    """
    default = {"foreign_institutional_score":50.0,"foreign_evidence_coverage_pct":0.0,"official_foreign_coverage_pct":0.0,"foreign_evidence_source":"UNAVAILABLE","foreign_net_5d":0.0,"foreign_net_20d":0.0,"foreign_persistence_20d":0.0,"foreign_intensity_20d":0.0}
    if flow is None or flow.empty or price is None or price.empty: return default
    f=flow.copy(); f["trade_date"]=pd.to_datetime(f["trade_date"],errors="coerce").dt.normalize(); f=f.dropna(subset=["trade_date"]).sort_values("trade_date")
    if f.empty: return default
    source_col = "foreign_evidence_source" if "foreign_evidence_source" in f.columns else "source" if "source" in f.columns else None
    foreign_source = str(f[source_col].dropna().iloc[-1]) if source_col and not f[source_col].dropna().empty else "UNKNOWN"
    px_days=pd.DatetimeIndex(pd.to_datetime(price["date"],errors="coerce").dropna().unique())[-lookback:]
    coverage=100.0*len(px_days.intersection(pd.DatetimeIndex(f["trade_date"].unique())))/max(len(px_days),1)
    if "volume" not in f.columns:
        f["volume"] = 0.0
    daily=f.groupby("trade_date",observed=True).agg(foreign_buy=("foreign_buy","sum"),foreign_sell=("foreign_sell","sum"),volume=("volume","sum")).sort_index()
    daily["foreign_net"]=daily["foreign_buy"]-daily["foreign_sell"]; d20=daily.tail(20); d5=daily.tail(5)
    net20=float(d20["foreign_net"].sum()) if not d20.empty else 0.0; net5=float(d5["foreign_net"].sum()) if not d5.empty else 0.0
    volume20=float(d20["volume"].sum()) if not d20.empty else 0.0; intensity20=net20/max(volume20,1.0)
    persistence20=float((d20["foreign_net"]>0).mean()) if len(d20) else 0.0
    score=_clip_score(0.58*_sigmoid_score(intensity20,0.035)+42.0*persistence20); confidence=float(np.clip(coverage/80.0,0.0,1.0)); score=50.0+confidence*(score-50.0)
    return {"foreign_institutional_score":score,"foreign_evidence_coverage_pct":coverage,"official_foreign_coverage_pct":coverage if foreign_source=="IDX_OFFICIAL_STOCK_SUMMARY" else 0.0,"foreign_evidence_source":foreign_source,"foreign_net_5d":net5,"foreign_net_20d":net20,"foreign_persistence_20d":persistence20,"foreign_intensity_20d":intensity20}


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
