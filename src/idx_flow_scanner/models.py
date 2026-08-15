from __future__ import annotations

from dataclasses import dataclass, asdict
from typing import Any


@dataclass
class ScanResult:
    ticker: str
    as_of_date: str
    final_score: float
    phase: str
    action: str
    evidence_tier: str
    evidence_coverage_pct: float
    accumulation_score: float
    operator_dominance_score: float
    cost_basis_score: float
    retail_exhaustion_score: float
    supply_concentration_score: float
    price_flow_divergence_score: float
    smc_execution_score: float
    risk_liquidity_score: float
    distribution_risk: float
    estimated_smart_money_cost: float | None
    premium_to_cost_pct: float | None
    entry_low: float | None
    entry_high: float | None
    invalidation: float | None
    tp1: float | None
    tp2: float | None
    real_money_state: str
    guardrail_reason: str
    diagnostics: dict[str, Any]

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)
