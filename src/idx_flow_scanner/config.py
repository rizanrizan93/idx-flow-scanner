from __future__ import annotations

from dataclasses import dataclass, field


@dataclass(frozen=True)
class FlowWeights:
    accumulation: float = 0.25
    operator_dominance: float = 0.15
    cost_basis: float = 0.10
    retail_exhaustion: float = 0.10
    foreign_institutional: float = 0.10
    supply_concentration: float = 0.08
    price_flow_divergence: float = 0.07
    market_sector: float = 0.05
    smc_execution: float = 0.05
    risk_liquidity: float = 0.05

    def as_dict(self) -> dict[str, float]:
        return self.__dict__.copy()

    def validate(self) -> None:
        total = sum(self.as_dict().values())
        if abs(total - 1.0) > 1e-9:
            raise ValueError(f"FlowWeights must sum to 1.0, got {total:.6f}")


@dataclass(frozen=True)
class ScannerConfig:
    windows: tuple[int, ...] = (5, 20, 60)
    minimum_price_bars: int = 80
    minimum_broker_days: int = 10
    direct_broker_min_coverage_pct: float = 70.0
    direct_broker_min_distinct_brokers: int = 6
    direct_broker_max_balance_error_pct: float = 10.0
    real_money_min_coverage_pct: float = 80.0
    real_money_min_price_quality_score: float = 70.0
    max_price_staleness_days: int = 3
    top_brokers: int = 5
    max_price_extension_from_cost_pct: float = 35.0
    weights: FlowWeights = field(default_factory=FlowWeights)

    def __post_init__(self) -> None:
        self.weights.validate()
        if self.direct_broker_min_distinct_brokers < 2:
            raise ValueError("direct_broker_min_distinct_brokers must be >= 2")
        if not 0 <= self.direct_broker_max_balance_error_pct <= 100:
            raise ValueError("direct_broker_max_balance_error_pct must be between 0 and 100")
        if not 0 <= self.real_money_min_price_quality_score <= 100:
            raise ValueError("real_money_min_price_quality_score must be between 0 and 100")
        if self.max_price_staleness_days < 0:
            raise ValueError("max_price_staleness_days must be >= 0")
