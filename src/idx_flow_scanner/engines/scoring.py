from __future__ import annotations

import numpy as np

from ..config import ScannerConfig


def phase_from_features(features: dict[str, object]) -> str:
    direct = bool(features.get("direct_broker", False))
    acc = float(features.get("accumulation_score", 0) or 0) if direct else float(features.get("proxy_accumulation_score", 0) or 0)
    dist = float(features.get("distribution_risk", 50) or 50) if direct else float(features.get("proxy_distribution_risk", 50) or 50)
    premium = features.get("premium_to_cost_pct")
    premium = float(premium) if premium is not None and np.isfinite(premium) else None
    price20 = float(features.get("price_return_20d", 0) or 0)
    stability = float(features.get("broker_cohort_stability", 0.0) or 0.0)
    quality = float(features.get("accumulation_quality_score", acc) or acc)
    if dist >= 65:
        return "DISTRIBUTION"
    if direct:
        if acc >= 72 and quality >= 68 and stability >= 0.45 and (premium is None or premium <= 12) and price20 <= 12:
            return "ACCUMULATION"
        if acc >= 62 and quality >= 58 and (premium is None or premium <= 25) and 0 < price20 <= 22:
            return "EARLY_MARKUP"
        if acc >= 48 and price20 > 8:
            return "MARKUP"
        if acc < 32 and price20 < -8:
            return "MARKDOWN"
        return "NEUTRAL"
    if acc >= 70 and price20 <= 12:
        return "ACCUMULATION"
    if acc >= 60 and price20 > 0:
        return "EARLY_MARKUP"
    if acc >= 45 and price20 > 8:
        return "MARKUP"
    if acc < 35 and price20 < -8:
        return "MARKDOWN"
    return "NEUTRAL"


def action_from_phase(phase: str, final_score: float, dist_risk: float, direct: bool) -> str:
    if phase == "DISTRIBUTION" or dist_risk >= 75:
        return "REDUCE_AVOID"
    if not direct:
        return "RESEARCH_ONLY"
    if phase == "ACCUMULATION" and final_score >= 75:
        return "BUY_ON_WEAKNESS"
    if phase == "EARLY_MARKUP" and final_score >= 72:
        return "BUY_RETEST"
    if phase == "MARKUP" and final_score >= 70:
        return "HOLD_DO_NOT_CHASE"
    return "WATCHLIST"


def final_score(features: dict[str, object], config: ScannerConfig) -> float:
    w = config.weights
    direct = bool(features.get("direct_broker", False))
    foreign = float(features.get("foreign_institutional_score", 50.0) or 50.0)
    market = float(features.get("market_sector_score", 50.0) or 50.0)
    price_quality = float(features.get("price_data_quality_score", 100.0) or 0.0)
    if direct:
        accumulation = float(features.get("accumulation_score", 0.0) or 0.0)
        dominance = float(features.get("operator_dominance_score", 0.0) or 0.0)
        cost_basis = float(features.get("cost_basis_score", 0.0) or 0.0)
        supply = float(features.get("supply_concentration_score", 0.0) or 0.0)
        distribution = float(features.get("distribution_risk", 50.0) or 50.0)
    else:
        accumulation = min(82.0, float(features.get("proxy_accumulation_score", 30.0) or 30.0))
        dominance = min(75.0, float(features.get("proxy_absorption_score", 30.0) or 30.0))
        cost_basis = 50.0
        supply = min(75.0, float(features.get("proxy_supply_tightness_score", 30.0) or 30.0))
        distribution = float(features.get("proxy_distribution_risk", 50.0) or 50.0)
    parts = {
        "accumulation": accumulation,
        "operator_dominance": dominance,
        "cost_basis": cost_basis,
        "retail_exhaustion": float(features.get("retail_exhaustion_score", 0.0) or 0.0),
        "foreign_institutional": foreign,
        "supply_concentration": supply,
        "price_flow_divergence": float(features.get("price_flow_divergence_score", 0.0) or 0.0),
        "market_sector": market,
        "smc_execution": float(features.get("smc_execution_score", 0.0) or 0.0),
        "risk_liquidity": float(features.get("risk_liquidity_score", 0.0) or 0.0),
    }
    if direct:
        score = sum(parts[k] * getattr(w, k) for k in parts)
    else:
        # PRICE_PROXY uses one latent price-flow family only.  Absorption,
        # supply-tightness, retail-exhaustion and divergence are diagnostics derived
        # from the same OHLCV state and must not masquerade as independent votes.
        # Preserve the relative weight of the genuinely distinct retained families
        # from the original model, then renormalize them to 100%.
        retained = {
            "accumulation": parts["accumulation"],
            "foreign_institutional": parts["foreign_institutional"],
            "market_sector": parts["market_sector"],
            "smc_execution": parts["smc_execution"],
            "risk_liquidity": parts["risk_liquidity"],
        }
        retained_weights = {
            "accumulation": w.accumulation,
            "foreign_institutional": w.foreign_institutional,
            "market_sector": w.market_sector,
            "smc_execution": w.smc_execution,
            "risk_liquidity": w.risk_liquidity,
        }
        denominator = sum(retained_weights.values())
        score = sum(retained[k] * retained_weights[k] for k in retained) / max(denominator, 1e-12)
    score -= max(0.0, distribution - 55.0) * 0.22
    # Data integrity is not a separate alpha factor. It is a confidence haircut.
    # Healthy data (>=80) is effectively neutral; stale/illiquid/split-like data
    # is progressively de-rated so bad bars cannot manufacture accumulation.
    score -= max(0.0, 80.0 - price_quality) * 0.18
    if direct:
        quality = float(features.get("accumulation_quality_score", 50.0) or 50.0)
        stability = float(features.get("broker_cohort_stability", 0.0) or 0.0)
        score += float(np.clip((quality - 50.0) * 0.04 + (stability - 0.5) * 4.0, -3.0, 3.0))
    else:
        score = 50.0 + 0.88 * (score - 50.0)
    return float(np.clip(score, 0, 100))
