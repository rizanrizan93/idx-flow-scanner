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
    direct_broker_min_verified_source_pct: float = 95.0
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
        if not 0 <= self.direct_broker_min_verified_source_pct <= 100:
            raise ValueError("direct_broker_min_verified_source_pct must be between 0 and 100")
        if not 0 <= self.real_money_min_price_quality_score <= 100:
            raise ValueError("real_money_min_price_quality_score must be between 0 and 100")
        if self.max_price_staleness_days < 0:
            raise ValueError("max_price_staleness_days must be >= 0")


@dataclass(frozen=True)
class ZapiFlowWeights:
    """Active v0.4 ZAPI-only evidence weights.

    These are research priors. Calibration may recommend future revisions, but
    runtime never mutates them automatically from in-sample outcomes.
    """

    accumulation: float = 0.24
    foreign_flow: float = 0.20
    market_sector: float = 0.15
    free_float: float = 0.10
    ownership: float = 0.08
    corporate_action: float = 0.05
    retail_exhaustion: float = 0.06
    price_flow_divergence: float = 0.04
    smc_execution: float = 0.04
    risk_liquidity: float = 0.04

    def as_dict(self) -> dict[str, float]:
        return self.__dict__.copy()

    def validate(self) -> None:
        total = sum(self.as_dict().values())
        if abs(total - 1.0) > 1e-9:
            raise ValueError(f"ZapiFlowWeights must sum to 1.0, got {total:.6f}")


@dataclass(frozen=True)
class ZapiFlowConfig:
    minimum_price_bars: int = 80
    minimum_foreign_coverage_pct: float = 80.0
    decision_score_floor: float = 65.0
    max_distribution_risk: float = 70.0
    minimum_price_quality_score: float = 70.0
    max_price_staleness_days: int = 3
    extreme_low_free_float_pct: float = 7.5
    material_dilution_pct: float = 15.0
    weights: ZapiFlowWeights = field(default_factory=ZapiFlowWeights)

    def __post_init__(self) -> None:
        self.weights.validate()
        for value in (
            self.minimum_foreign_coverage_pct,
            self.decision_score_floor,
            self.max_distribution_risk,
            self.minimum_price_quality_score,
            self.extreme_low_free_float_pct,
            self.material_dilution_pct,
        ):
            if not 0 <= float(value) <= 100:
                raise ValueError("ZAPI decision thresholds must be between 0 and 100")
        if self.minimum_price_bars < 20:
            raise ValueError("minimum_price_bars must be >= 20")
        if self.max_price_staleness_days < 0:
            raise ValueError("max_price_staleness_days must be >= 0")
