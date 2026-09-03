from __future__ import annotations

import uuid
from typing import Callable, Mapping

import numpy as np
import pandas as pd

from .config import ZapiFlowConfig
from .data import canonical_ticker, completed_idx_session_frame
from .data_quality import compute_price_quality_features
from .engines.flow import compute_official_foreign_features, compute_price_flow_features
from .engines.smc import compute_smc_features
from .market_context import compute_market_context, ticker_market_features
from .models import ScanResult
from .slow_evidence import compute_slow_evidence


def _zapi_ready(ff: Mapping[str, object]) -> bool:
    return bool(
        ff.get("foreign_data_valid") is True
        and str(ff.get("foreign_provider_selected") or "") == "ZAPI"
        and str(ff.get("foreign_provider_selection_state") or "") == "ZAPI"
        and str(ff.get("foreign_provider_reconciliation_state") or "") in {"SINGLE_PROVIDER", "AGREED"}
        and str(ff.get("foreign_window_state") or "") == "FULL"
        and str(ff.get("foreign_data_freshness") or "") == "FRESH"
        and ff.get("foreign_provider_conflict") is False
    )


def _phase(features: Mapping[str, object]) -> str:
    acc = float(features.get("proxy_accumulation_score", 30.0) or 30.0)
    dist = float(features.get("proxy_distribution_risk", 50.0) or 50.0)
    foreign = float(features.get("foreign_institutional_score", 50.0) or 50.0)
    price20 = float(features.get("price_return_20d", 0.0) or 0.0)
    if dist >= 65:
        return "DISTRIBUTION"
    if acc >= 70 and foreign >= 55 and price20 <= 12:
        return "ACCUMULATION"
    if acc >= 60 and foreign >= 52 and 0 < price20 <= 22:
        return "EARLY_MARKUP"
    if acc >= 45 and price20 > 8:
        return "MARKUP"
    if acc < 35 and price20 < -8:
        return "MARKDOWN"
    return "NEUTRAL"


def _score(features: Mapping[str, object], config: ZapiFlowConfig) -> float:
    parts = {
        "accumulation": float(features.get("proxy_accumulation_score", 30.0) or 30.0),
        "foreign": float(features.get("foreign_institutional_score", 50.0) or 50.0),
        "market": float(features.get("market_sector_score", 50.0) or 50.0),
        "free_float": float(features.get("free_float_structure_score", 50.0) or 50.0),
        "ownership": float(features.get("ownership_score", 50.0) or 50.0),
        "corporate": float(features.get("corporate_action_score", 50.0) or 50.0),
        "retail": float(features.get("retail_exhaustion_score", 50.0) or 50.0),
        "divergence": float(features.get("price_flow_divergence_score", 50.0) or 50.0),
        "smc": float(features.get("smc_execution_score", 50.0) or 50.0),
        "risk": float(features.get("risk_liquidity_score", 50.0) or 50.0),
    }
    w = config.weights
    weights = {
        "accumulation": w.accumulation,
        "foreign": w.foreign_flow,
        "market": w.market_sector,
        "free_float": w.free_float,
        "ownership": w.ownership,
        "corporate": w.corporate_action,
        "retail": w.retail_exhaustion,
        "divergence": w.price_flow_divergence,
        "smc": w.smc_execution,
        "risk": w.risk_liquidity,
    }
    score = sum(parts[key] * weights[key] for key in weights)
    distribution = float(features.get("proxy_distribution_risk", 50.0) or 50.0)
    price_quality = float(features.get("price_data_quality_score", 100.0) or 0.0)
    score -= max(0.0, distribution - 55.0) * 0.22
    score -= max(0.0, 80.0 - price_quality) * 0.18
    return float(np.clip(score, 0.0, 100.0))


def _decision_state(
    *,
    score: float,
    phase: str,
    ff: Mapping[str, object],
    qf: Mapping[str, object],
    sf: Mapping[str, object],
    slow: Mapping[str, object],
    config: ZapiFlowConfig,
) -> tuple[str, str, bool]:
    reasons: list[str] = []
    coverage = float(ff.get("foreign_evidence_coverage_pct", 0.0) or 0.0)
    if not _zapi_ready(ff):
        reasons.append("ZAPI foreign-flow evidence not FULL/FRESH/VALID")
    if coverage < config.minimum_foreign_coverage_pct:
        reasons.append(
            f"ZAPI coverage {coverage:.1f}% < {config.minimum_foreign_coverage_pct:.0f}%"
        )
    if score < config.decision_score_floor:
        reasons.append(f"score {score:.1f} below {config.decision_score_floor:.0f}")
    distribution = float(qf.get("proxy_distribution_risk", 0.0) or 0.0)
    # qf does not own distribution; caller appends a normalized key when needed.
    distribution = float(slow.get("_distribution_risk", distribution) or distribution)
    if distribution >= config.max_distribution_risk:
        reasons.append(f"distribution risk high ({distribution:.1f})")
    price_quality = float(qf.get("price_data_quality_score", 0.0) or 0.0)
    if price_quality < config.minimum_price_quality_score:
        reasons.append(
            f"price data quality {price_quality:.1f} < {config.minimum_price_quality_score:.0f}"
        )
    staleness = int(qf.get("price_staleness_days", 999) or 0)
    if staleness > config.max_price_staleness_days:
        reasons.append(
            f"price stale {staleness}d > {config.max_price_staleness_days}d"
        )
    if not bool(sf.get("execution_geometry_valid", False)):
        reasons.append("execution geometry invalid")
    if not bool(sf.get("execution_levels_tradeable", False)):
        reasons.append("execution levels not tradeable")
    if not bool(sf.get("entry_within_next_session_price_band", False)):
        reasons.append("entry outside next-session price band")
    free_float = slow.get("free_float_pct")
    if free_float is not None and float(free_float) < config.extreme_low_free_float_pct:
        reasons.append(f"extreme low free float ({float(free_float):.2f}%)")
    if bool(slow.get("slow_evidence_hard_block", False)):
        reasons.append("recent material dilution/capital action")
    if phase == "DISTRIBUTION":
        reasons.append("distribution phase")
    authorized = not reasons
    return (
        "ELIGIBLE" if authorized else "GUARDED",
        "ZAPI + price/SMC + slow-evidence gates passed" if authorized else "; ".join(reasons),
        authorized,
    )


def scan_one_zapi(
    ticker: str,
    price: pd.DataFrame,
    *,
    foreign_flow: pd.DataFrame | None = None,
    market_features: dict[str, object] | None = None,
    reference_date: str | None = None,
    stock_summary: pd.DataFrame | None = None,
    ownership: pd.DataFrame | None = None,
    capital_actions: pd.DataFrame | None = None,
    config: ZapiFlowConfig | None = None,
) -> ScanResult:
    config = config or ZapiFlowConfig()
    ticker = canonical_ticker(ticker)
    price = completed_idx_session_frame(price)
    if len(price) < config.minimum_price_bars:
        raise ValueError(
            f"{ticker}: insufficient price history ({len(price)} bars)"
        )

    foreign_flow = foreign_flow if foreign_flow is not None else pd.DataFrame()
    ff = compute_official_foreign_features(foreign_flow, price)
    pf = compute_price_flow_features(price, {})
    sf = compute_smc_features(price)
    qf = compute_price_quality_features(price, reference_date=reference_date)
    market_features = market_features or {
        "market_sector_score": 50.0,
        "market_regime_score": 50.0,
        "market_regime_label": "UNKNOWN",
    }
    slow = compute_slow_evidence(
        ticker,
        price,
        ff,
        stock_summary=stock_summary,
        ownership=ownership,
        capital_actions=capital_actions,
    )
    features = {**ff, **pf, **sf, **qf, **market_features, **slow}
    score = _score(features, config)
    phase = _phase(features)
    zapi_ready = _zapi_ready(ff)
    distribution = float(pf.get("proxy_distribution_risk", 50.0) or 50.0)
    slow["_distribution_risk"] = distribution
    state, reason, authorized = _decision_state(
        score=score,
        phase=phase,
        ff=ff,
        qf=qf,
        sf=sf,
        slow=slow,
        config=config,
    )
    if not zapi_ready:
        action = "RESEARCH_ONLY"
    elif phase == "DISTRIBUTION" or distribution >= 75:
        action = "REDUCE_AVOID"
    elif phase == "ACCUMULATION" and score >= 75:
        action = "BUY_ON_WEAKNESS"
    elif phase == "EARLY_MARKUP" and score >= 72:
        action = "BUY_RETEST"
    elif phase == "MARKUP" and score >= 70:
        action = "HOLD_DO_NOT_CHASE"
    else:
        action = "WATCHLIST"

    evidence_tier = "ZAPI_FLOW" if zapi_ready else "PRICE_PROXY"
    as_of = pd.to_datetime(price["date"].iloc[-1]).date().isoformat()
    diagnostics = {
        "zapi_primary_mode": True,
        "broker_direct_disabled": True,
        "foreign_evidence_coverage_pct": ff.get("foreign_evidence_coverage_pct"),
        "foreign_evidence_source": ff.get("foreign_evidence_source"),
        "foreign_provider_selected": ff.get("foreign_provider_selected"),
        "foreign_provider_selection_state": ff.get("foreign_provider_selection_state"),
        "foreign_provider_reconciliation_state": ff.get("foreign_provider_reconciliation_state"),
        "foreign_provider_conflict": ff.get("foreign_provider_conflict"),
        "foreign_window_state": ff.get("foreign_window_state"),
        "foreign_window_coverage_ratio": ff.get("foreign_window_coverage_ratio"),
        "foreign_data_freshness": ff.get("foreign_data_freshness"),
        "foreign_data_valid": ff.get("foreign_data_valid"),
        "foreign_net_5d": ff.get("foreign_net_5d"),
        "foreign_net_20d": ff.get("foreign_net_20d"),
        "foreign_persistence_20d": ff.get("foreign_persistence_20d"),
        "foreign_intensity_20d": ff.get("foreign_intensity_20d"),
        "market_regime_score": market_features.get("market_regime_score"),
        "market_regime_label": market_features.get("market_regime_label"),
        "sector": market_features.get("sector"),
        "sector_regime_score": market_features.get("sector_regime_score"),
        "sector_regime_label": market_features.get("sector_regime_label"),
        "sector_breadth_20d": market_features.get("sector_breadth_20d"),
        "sector_breadth_60d": market_features.get("sector_breadth_60d"),
        "relative_strength_20d_pct": market_features.get("relative_strength_20d_pct"),
        "relative_strength_60d_pct": market_features.get("relative_strength_60d_pct"),
        "sector_relative_strength_20d_pct": market_features.get("sector_relative_strength_20d_pct"),
        "sector_relative_strength_60d_pct": market_features.get("sector_relative_strength_60d_pct"),
        "market_context_basis": market_features.get("market_context_basis"),
        "price_data_quality_score": qf.get("price_data_quality_score"),
        "price_staleness_days": qf.get("price_staleness_days"),
        "zero_volume_ratio_20d": qf.get("zero_volume_ratio_20d"),
        "zero_volume_ratio_60d": qf.get("zero_volume_ratio_60d"),
        "split_like_event_detected": qf.get("split_like_event_detected"),
        "split_like_event_recent": qf.get("split_like_event_recent"),
        "proxy_accumulation_score": pf.get("proxy_accumulation_score"),
        "proxy_absorption_score": pf.get("proxy_absorption_score"),
        "proxy_supply_tightness_score": pf.get("proxy_supply_tightness_score"),
        "proxy_distribution_risk": distribution,
        "proxy_cmf20": pf.get("proxy_cmf20"),
        "proxy_obv_slope_norm20": pf.get("proxy_obv_slope_norm20"),
        "bos": sf.get("bos"),
        "choch": sf.get("choch"),
        "liquidity_sweep": sf.get("liquidity_sweep"),
        "fvg_low": sf.get("fvg_low"),
        "fvg_high": sf.get("fvg_high"),
        "execution_geometry_valid": sf.get("execution_geometry_valid"),
        "execution_levels_tradeable": sf.get("execution_levels_tradeable"),
        "entry_within_next_session_price_band": sf.get("entry_within_next_session_price_band"),
        "execution_rr1": sf.get("execution_rr1"),
        "execution_rr2": sf.get("execution_rr2"),
        **{k: v for k, v in slow.items() if not k.startswith("_")},
        "production_authorized": bool(authorized),
        "scoring_lineage_state": "ZAPI_FLOW__OHLCV_LATENT__SECTOR__SLOW_EVIDENCE_V1",
    }
    return ScanResult(
        ticker=ticker,
        as_of_date=as_of,
        final_score=round(score, 2),
        phase=phase,
        action=action,
        evidence_tier=evidence_tier,
        evidence_coverage_pct=round(float(ff.get("foreign_evidence_coverage_pct", 0.0) or 0.0), 2),
        accumulation_score=round(float(pf.get("proxy_accumulation_score", 30.0) or 30.0), 2),
        operator_dominance_score=round(float(pf.get("proxy_absorption_score", 30.0) or 30.0), 2),
        cost_basis_score=50.0,
        retail_exhaustion_score=round(float(pf.get("retail_exhaustion_score", 50.0) or 50.0), 2),
        foreign_institutional_score=round(float(ff.get("foreign_institutional_score", 50.0) or 50.0), 2),
        supply_concentration_score=round(float(pf.get("proxy_supply_tightness_score", 30.0) or 30.0), 2),
        price_flow_divergence_score=round(float(pf.get("price_flow_divergence_score", 50.0) or 50.0), 2),
        market_context_score=round(float(market_features.get("market_sector_score", 50.0) or 50.0), 2),
        smc_execution_score=round(float(sf.get("smc_execution_score", 50.0) or 50.0), 2),
        risk_liquidity_score=round(float(pf.get("risk_liquidity_score", 50.0) or 50.0), 2),
        price_data_quality_score=round(float(qf.get("price_data_quality_score", 0.0) or 0.0), 2),
        distribution_risk=round(distribution, 2),
        estimated_smart_money_cost=None,
        premium_to_cost_pct=None,
        entry_low=round(float(sf["entry_low"]), 2) if sf.get("entry_low") is not None else None,
        entry_high=round(float(sf["entry_high"]), 2) if sf.get("entry_high") is not None else None,
        invalidation=round(float(sf["invalidation"]), 2) if sf.get("invalidation") is not None else None,
        tp1=round(float(sf["tp1"]), 2) if sf.get("tp1") is not None else None,
        tp2=round(float(sf["tp2"]), 2) if sf.get("tp2") is not None else None,
        real_money_state=state,
        guardrail_reason=reason,
        production_authorized=bool(authorized),
        diagnostics=diagnostics,
    )


def scan_universe_zapi(
    universe: list[str],
    price_loader: Callable[[str], pd.DataFrame],
    *,
    progress: Callable[[int, int, str], None] | None = None,
    run_id: str | None = None,
    foreign_flow_frame: pd.DataFrame | None = None,
    stock_summary_frame: pd.DataFrame | None = None,
    ownership_frame: pd.DataFrame | None = None,
    capital_action_frame: pd.DataFrame | None = None,
    sector_map: Mapping[str, str] | None = None,
    config: ZapiFlowConfig | None = None,
) -> tuple[str, pd.DataFrame, list[dict[str, str]]]:
    config = config or ZapiFlowConfig()
    run_id = run_id or str(uuid.uuid4())
    foreign_flow_frame = foreign_flow_frame if foreign_flow_frame is not None else pd.DataFrame()
    stock_summary_frame = stock_summary_frame if stock_summary_frame is not None else pd.DataFrame()
    ownership_frame = ownership_frame if ownership_frame is not None else pd.DataFrame()
    capital_action_frame = capital_action_frame if capital_action_frame is not None else pd.DataFrame()
    rows: list[dict[str, object]] = []
    errors: list[dict[str, str]] = []

    price_map: dict[str, pd.DataFrame] = {}
    loader_errors: dict[str, str] = {}
    for ticker in universe:
        t = canonical_ticker(ticker)
        try:
            price_map[t] = completed_idx_session_frame(price_loader(t))
        except Exception as exc:
            price_map[t] = pd.DataFrame()
            loader_errors[t] = str(exc)

    market_context = compute_market_context(price_map, sector_map=sector_map)
    reference_date = market_context.get("reference_date")
    total = len(universe)

    for i, ticker in enumerate(universe, 1):
        t = canonical_ticker(ticker)
        try:
            price = price_map.get(t, pd.DataFrame())
            if price.empty and t in loader_errors:
                raise ValueError(loader_errors[t])
            foreign = (
                foreign_flow_frame[foreign_flow_frame["ticker"].eq(t)].copy()
                if not foreign_flow_frame.empty and "ticker" in foreign_flow_frame.columns
                else pd.DataFrame()
            )
            stock = (
                stock_summary_frame[stock_summary_frame["ticker"].eq(t)].copy()
                if not stock_summary_frame.empty and "ticker" in stock_summary_frame.columns
                else pd.DataFrame()
            )
            ownership = (
                ownership_frame[ownership_frame["ticker"].eq(t)].copy()
                if not ownership_frame.empty and "ticker" in ownership_frame.columns
                else pd.DataFrame()
            )
            actions = (
                capital_action_frame[capital_action_frame["ticker"].eq(t)].copy()
                if not capital_action_frame.empty and "ticker" in capital_action_frame.columns
                else pd.DataFrame()
            )
            mf = ticker_market_features(t, market_context)
            rows.append(
                scan_one_zapi(
                    t,
                    price,
                    foreign_flow=foreign,
                    market_features=mf,
                    reference_date=str(reference_date) if reference_date else None,
                    stock_summary=stock,
                    ownership=ownership,
                    capital_actions=actions,
                    config=config,
                ).to_dict()
            )
        except Exception as exc:
            errors.append({"ticker": t, "error": str(exc)})
        if progress:
            progress(i, total, t)

    out = pd.DataFrame(rows)
    if not out.empty:
        out = out.sort_values(
            ["production_authorized", "final_score", "ticker"],
            ascending=[False, False, True],
            kind="stable",
        ).reset_index(drop=True)
    return run_id, out, errors
