from __future__ import annotations

from .config import ScannerConfig


def real_money_guard(
    *,
    evidence_tier: str,
    evidence_coverage_pct: float,
    broker_days: int,
    distribution_risk: float,
    score: float,
    config: ScannerConfig,
) -> tuple[str, str]:
    reasons: list[str] = []
    if evidence_tier != "BROKER_DIRECT":
        reasons.append("direct broker evidence unavailable")
    if evidence_coverage_pct < config.real_money_min_coverage_pct:
        reasons.append(f"broker evidence coverage {evidence_coverage_pct:.1f}% < {config.real_money_min_coverage_pct:.0f}%")
    if broker_days < config.minimum_broker_days:
        reasons.append(f"broker history {broker_days}d < {config.minimum_broker_days}d")
    if distribution_risk >= 70:
        reasons.append(f"distribution risk high ({distribution_risk:.1f})")
    if score < 65:
        reasons.append(f"score {score:.1f} below decision floor")
    if reasons:
        return "GUARDED", "; ".join(reasons)
    return "ELIGIBLE", "direct evidence and minimum quality gates passed"
