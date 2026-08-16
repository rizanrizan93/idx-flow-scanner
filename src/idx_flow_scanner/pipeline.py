from __future__ import annotations

from datetime import datetime, timezone
import uuid
from typing import Callable

import pandas as pd

from .config import ScannerConfig
from .data import canonical_ticker
from .engines.flow import compute_broker_features, compute_price_flow_features
from .engines.smc import compute_smc_features
from .engines.scoring import action_from_phase, final_score, phase_from_features
from .guardrails import real_money_guard
from .models import ScanResult


def scan_one(
    ticker: str,
    price: pd.DataFrame,
    broker: pd.DataFrame | None,
    config: ScannerConfig | None = None,
) -> ScanResult:
    config = config or ScannerConfig()
    ticker = canonical_ticker(ticker)
    broker = broker if broker is not None else pd.DataFrame()
    if len(price) < config.minimum_price_bars:
        raise ValueError(f"{ticker}: insufficient price history ({len(price)} bars)")

    bf = compute_broker_features(broker, price, config)
    pf = compute_price_flow_features(price, bf)
    sf = compute_smc_features(price)
    direct = bool(len(broker) and float(bf["coverage_pct"]) >= config.direct_broker_min_coverage_pct)
    features = {**bf, **pf, **sf, "direct_broker": direct}
    evidence_tier = "BROKER_DIRECT" if direct else "PRICE_PROXY"
    effective_distribution = float(bf["distribution_risk"]) if direct else float(pf.get("proxy_distribution_risk", 50.0))
    effective_accumulation = float(bf["accumulation_score"]) if direct else float(pf.get("proxy_accumulation_score", 30.0))
    effective_dominance = float(bf["operator_dominance_score"]) if direct else float(pf.get("proxy_absorption_score", 30.0))
    effective_supply = float(bf["supply_concentration_score"]) if direct else float(pf.get("proxy_supply_tightness_score", 30.0))
    effective_cost_basis = float(bf["cost_basis_score"]) if direct else 50.0
    score = final_score(features, config)
    phase = phase_from_features(features)
    action = action_from_phase(phase, score, effective_distribution, direct)
    state, reason = real_money_guard(
        evidence_tier=evidence_tier,
        evidence_coverage_pct=float(bf["coverage_pct"]),
        broker_days=int(bf["broker_days"]),
        distribution_risk=effective_distribution,
        score=score,
        config=config,
    )
    as_of = pd.to_datetime(price["date"].iloc[-1]).date().isoformat()
    return ScanResult(
        ticker=ticker,
        as_of_date=as_of,
        final_score=round(score, 2),
        phase=phase,
        action=action,
        evidence_tier=evidence_tier,
        evidence_coverage_pct=round(float(bf["coverage_pct"]), 2),
        accumulation_score=round(effective_accumulation, 2),
        operator_dominance_score=round(effective_dominance, 2),
        cost_basis_score=round(effective_cost_basis, 2),
        retail_exhaustion_score=round(float(pf["retail_exhaustion_score"]), 2),
        supply_concentration_score=round(effective_supply, 2),
        price_flow_divergence_score=round(float(pf["price_flow_divergence_score"]), 2),
        smc_execution_score=round(float(sf["smc_execution_score"]), 2),
        risk_liquidity_score=round(float(pf["risk_liquidity_score"]), 2),
        distribution_risk=round(effective_distribution, 2),
        estimated_smart_money_cost=round(float(bf["estimated_smart_money_cost"]), 4) if bf["estimated_smart_money_cost"] else None,
        premium_to_cost_pct=round(float(bf["premium_to_cost_pct"]), 2) if bf["premium_to_cost_pct"] is not None else None,
        entry_low=round(float(sf["entry_low"]), 2) if sf["entry_low"] is not None else None,
        entry_high=round(float(sf["entry_high"]), 2) if sf["entry_high"] is not None else None,
        invalidation=round(float(sf["invalidation"]), 2) if sf["invalidation"] is not None else None,
        tp1=round(float(sf["tp1"]), 2) if sf["tp1"] is not None else None,
        tp2=round(float(sf["tp2"]), 2) if sf["tp2"] is not None else None,
        real_money_state=state,
        guardrail_reason=reason,
        diagnostics={
            "broker_days": bf["broker_days"],
            "net_value_5d": bf["net_value_5d"],
            "net_value_20d": bf["net_value_20d"],
            "net_value_60d": bf["net_value_60d"],
            "persistence_20d": bf["persistence_20d"],
            "proxy_accumulation_score": pf.get("proxy_accumulation_score"),
            "proxy_absorption_score": pf.get("proxy_absorption_score"),
            "proxy_supply_tightness_score": pf.get("proxy_supply_tightness_score"),
            "proxy_distribution_risk": pf.get("proxy_distribution_risk"),
            "proxy_cmf20": pf.get("proxy_cmf20"),
            "proxy_obv_slope_norm20": pf.get("proxy_obv_slope_norm20"),
            "top_accumulating_brokers": bf["top_accumulating_brokers"],
            "top_distributing_brokers": bf["top_distributing_brokers"],
            "bos": sf["bos"], "choch": sf["choch"], "liquidity_sweep": sf["liquidity_sweep"],
            "fvg_low": sf["fvg_low"], "fvg_high": sf["fvg_high"],
        },
    )


def scan_universe(
    universe: list[str],
    price_loader: Callable[[str], pd.DataFrame],
    broker_frame: pd.DataFrame | None = None,
    config: ScannerConfig | None = None,
    progress: Callable[[int, int, str], None] | None = None,
    run_id: str | None = None,
) -> tuple[str, pd.DataFrame, list[dict[str, str]]]:
    config = config or ScannerConfig()
    run_id = run_id or str(uuid.uuid4())
    broker_frame = broker_frame if broker_frame is not None else pd.DataFrame()
    rows: list[dict[str, object]] = []
    errors: list[dict[str, str]] = []
    total = len(universe)
    for i, ticker in enumerate(universe, 1):
        t = canonical_ticker(ticker)
        try:
            price = price_loader(t)
            b = broker_frame[broker_frame["ticker"] == t] if not broker_frame.empty and "ticker" in broker_frame else pd.DataFrame()
            rows.append(scan_one(t, price, b, config).to_dict())
        except Exception as exc:
            errors.append({"ticker": t, "error": str(exc)})
        if progress:
            progress(i, total, t)
    out = pd.DataFrame(rows)
    if not out.empty:
        out = out.sort_values(["real_money_state", "final_score", "ticker"], ascending=[True, False, True], kind="stable")
    return run_id, out.reset_index(drop=True), errors
