from __future__ import annotations

import uuid
from typing import Callable

import numpy as np
import pandas as pd

from .config import ScannerConfig
from .data import canonical_ticker
from .data_quality import compute_price_quality_features
from .engines.flow import compute_broker_features, compute_official_foreign_features, compute_price_flow_features
from .engines.smc import compute_smc_features
from .engines.scoring import action_from_phase, final_score, phase_from_features
from .guardrails import real_money_guard
from .market_context import compute_market_context, ticker_market_features
from .models import ScanResult


def _broker_verified_source_pct(broker: pd.DataFrame) -> float:
    """Gross-value weighted provenance coverage for direct broker evidence.

    A complete-looking CSV is not enough to become BROKER_DIRECT. Rows need an
    explicit verified provenance flag. Missing provenance is deliberately treated
    as unverified/fail-closed.
    """
    if broker is None or broker.empty or "source_verified" not in broker.columns:
        return 0.0
    raw = broker["source_verified"]
    if pd.api.types.is_bool_dtype(raw):
        verified = raw.fillna(False)
    else:
        verified = raw.astype(str).str.strip().str.lower().isin({"1", "true", "yes", "y", "verified"})
    buy = pd.to_numeric(broker.get("buy_value"), errors="coerce").fillna(0.0).clip(lower=0.0)
    sell = pd.to_numeric(broker.get("sell_value"), errors="coerce").fillna(0.0).clip(lower=0.0)
    gross = buy + sell
    total = float(gross.sum())
    if not np.isfinite(total) or total <= 0:
        return 0.0
    verified_value = float(gross[verified].sum())
    return float(np.clip(100.0 * verified_value / total, 0.0, 100.0))


def scan_one(
    ticker: str,
    price: pd.DataFrame,
    broker: pd.DataFrame | None,
    config: ScannerConfig | None = None,
    official_flow: pd.DataFrame | None = None,
    market_features: dict[str, object] | None = None,
    reference_date: str | None = None,
) -> ScanResult:
    config = config or ScannerConfig()
    ticker = canonical_ticker(ticker)
    broker = broker if broker is not None else pd.DataFrame()
    official_flow = official_flow if official_flow is not None else pd.DataFrame()
    market_features = market_features or {
        "market_sector_score": 50.0,
        "market_regime_score": 50.0,
        "market_regime_label": "UNKNOWN",
    }
    if len(price) < config.minimum_price_bars:
        raise ValueError(f"{ticker}: insufficient price history ({len(price)} bars)")

    bf = compute_broker_features(broker, price, config)
    ff = compute_official_foreign_features(official_flow, price)
    sf = compute_smc_features(price)
    qf = compute_price_quality_features(price, reference_date=reference_date)

    distinct_brokers = int(broker["broker_code"].nunique()) if not broker.empty and "broker_code" in broker.columns else 0
    broker_balance_error = float(bf.get("broker_balance_error_pct", 100.0) or 0.0)
    verified_source_pct = _broker_verified_source_pct(broker)
    price_quality = float(qf.get("price_data_quality_score", 0.0) or 0.0)
    staleness = int(qf.get("price_staleness_days", 999) or 0)
    split_like_recent = bool(qf.get("split_like_event_recent", False))
    direct = bool(
        len(broker)
        and float(bf["coverage_pct"]) >= config.direct_broker_min_coverage_pct
        and int(bf["broker_days"]) >= config.minimum_broker_days
        and distinct_brokers >= config.direct_broker_min_distinct_brokers
        and broker_balance_error <= config.direct_broker_max_balance_error_pct
        and verified_source_pct >= config.direct_broker_min_verified_source_pct
        and price_quality >= config.real_money_min_price_quality_score
        and staleness <= config.max_price_staleness_days
        and not split_like_recent
    )

    # Broker evidence that has not passed the full direct integrity gate — including
    # price quality/freshness/corporate-action gates — must have zero alpha influence.
    # Pending rows remain visible only in diagnostics.
    pf = compute_price_flow_features(price, bf if direct else {})

    features = {**bf, **pf, **ff, **sf, **market_features, **qf, "direct_broker": direct}
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

    if not direct and not broker.empty:
        integrity_reason = (
            f"broker evidence integrity gate failed: coverage={float(bf['coverage_pct']):.0f}%, "
            f"days={int(bf['broker_days'])}, brokers={distinct_brokers}, "
            f"balance_error={broker_balance_error:.1f}%, verified_source={verified_source_pct:.1f}%"
        )
        reason = f"{reason}; {integrity_reason}" if reason else integrity_reason

    quality_reasons: list[str] = []
    if price_quality < config.real_money_min_price_quality_score:
        quality_reasons.append(
            f"price data quality {price_quality:.1f} < {config.real_money_min_price_quality_score:.0f}"
        )
    if staleness > config.max_price_staleness_days:
        quality_reasons.append(f"price stale {staleness}d > {config.max_price_staleness_days}d")
    if split_like_recent:
        quality_reasons.append(
            f"split/corporate-action-like gap detected on {qf.get('split_like_event_date') or 'unknown date'}; "
            f"post-event bars={qf.get('split_like_bars_ago')}"
        )
    if quality_reasons:
        state = "GUARDED"
        reason = "; ".join([part for part in [reason, *quality_reasons] if part])
        if phase != "DISTRIBUTION":
            action = "WATCHLIST" if direct else "RESEARCH_ONLY"

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
        foreign_institutional_score=round(float(ff.get("foreign_institutional_score", 50.0) or 50.0), 2),
        supply_concentration_score=round(effective_supply, 2),
        price_flow_divergence_score=round(float(pf["price_flow_divergence_score"]), 2),
        market_context_score=round(float(market_features.get("market_sector_score", 50.0) or 50.0), 2),
        smc_execution_score=round(float(sf["smc_execution_score"]), 2),
        risk_liquidity_score=round(float(pf["risk_liquidity_score"]), 2),
        price_data_quality_score=round(price_quality, 2),
        distribution_risk=round(effective_distribution, 2),
        estimated_smart_money_cost=(
            round(float(bf["estimated_smart_money_cost"]), 4)
            if direct and bf["estimated_smart_money_cost"]
            else None
        ),
        premium_to_cost_pct=(
            round(float(bf["premium_to_cost_pct"]), 2)
            if direct and bf["premium_to_cost_pct"] is not None
            else None
        ),
        entry_low=round(float(sf["entry_low"]), 2) if sf["entry_low"] is not None else None,
        entry_high=round(float(sf["entry_high"]), 2) if sf["entry_high"] is not None else None,
        invalidation=round(float(sf["invalidation"]), 2) if sf["invalidation"] is not None else None,
        tp1=round(float(sf["tp1"]), 2) if sf["tp1"] is not None else None,
        tp2=round(float(sf["tp2"]), 2) if sf["tp2"] is not None else None,
        real_money_state=state,
        guardrail_reason=reason,
        diagnostics={
            "broker_days": bf["broker_days"],
            "distinct_brokers": distinct_brokers,
            "broker_verified_source_pct": verified_source_pct,
            "broker_alpha_applied": direct,
            "net_value_5d": bf["net_value_5d"],
            "net_value_20d": bf["net_value_20d"],
            "net_value_60d": bf["net_value_60d"],
            "persistence_5d": bf.get("persistence_5d"),
            "persistence_20d": bf["persistence_20d"],
            "persistence_60d": bf.get("persistence_60d"),
            "accumulation_quality_score": bf.get("accumulation_quality_score"),
            "broker_cohort_stability": bf.get("broker_cohort_stability"),
            "broker_hhi": bf.get("broker_hhi"),
            "net_conversion_ratio": bf.get("net_conversion_ratio"),
            "reversal_ratio_5d": bf.get("reversal_ratio_5d"),
            "broker_balance_error_pct": bf.get("broker_balance_error_pct"),
            "cost_position": bf.get("cost_position"),
            "foreign_evidence_coverage_pct": ff.get("foreign_evidence_coverage_pct"),
            "foreign_evidence_source": ff.get("foreign_evidence_source"),
            "official_foreign_coverage_pct": ff.get("official_foreign_coverage_pct"),
            "foreign_institutional_score": ff.get("foreign_institutional_score"),
            "foreign_net_5d": ff.get("foreign_net_5d"),
            "foreign_net_20d": ff.get("foreign_net_20d"),
            "foreign_persistence_20d": ff.get("foreign_persistence_20d"),
            "foreign_intensity_20d": ff.get("foreign_intensity_20d"),
            "market_regime_score": market_features.get("market_regime_score"),
            "market_regime_label": market_features.get("market_regime_label"),
            "market_breadth_20d": market_features.get("market_breadth_20d"),
            "market_breadth_60d": market_features.get("market_breadth_60d"),
            "relative_strength_20d_pct": market_features.get("relative_strength_20d_pct"),
            "relative_strength_60d_pct": market_features.get("relative_strength_60d_pct"),
            "market_context_basis": market_features.get("market_context_basis"),
            "market_context_coverage": market_features.get("market_context_coverage"),
            "price_data_quality_score": qf.get("price_data_quality_score"),
            "price_staleness_days": qf.get("price_staleness_days"),
            "zero_volume_ratio_20d": qf.get("zero_volume_ratio_20d"),
            "unchanged_close_ratio_20d": qf.get("unchanged_close_ratio_20d"),
            "ohlc_geometry_error_ratio": qf.get("ohlc_geometry_error_ratio"),
            "split_like_event_detected": qf.get("split_like_event_detected"),
            "split_like_event_recent": qf.get("split_like_event_recent"),
            "split_like_event_date": qf.get("split_like_event_date"),
            "split_like_factor": qf.get("split_like_factor"),
            "split_like_bars_ago": qf.get("split_like_bars_ago"),
            "proxy_accumulation_score": pf.get("proxy_accumulation_score"),
            "proxy_absorption_score": pf.get("proxy_absorption_score"),
            "proxy_supply_tightness_score": pf.get("proxy_supply_tightness_score"),
            "proxy_distribution_risk": pf.get("proxy_distribution_risk"),
            "proxy_cmf20": pf.get("proxy_cmf20"),
            "proxy_obv_slope_norm20": pf.get("proxy_obv_slope_norm20"),
            "top_accumulating_brokers": bf["top_accumulating_brokers"],
            "top_distributing_brokers": bf["top_distributing_brokers"],
            "bos": sf["bos"],
            "choch": sf["choch"],
            "liquidity_sweep": sf["liquidity_sweep"],
            "fvg_low": sf["fvg_low"],
            "fvg_high": sf["fvg_high"],
            "execution_geometry_valid": sf.get("execution_geometry_valid"),
        },
    )


def scan_universe(
    universe: list[str],
    price_loader: Callable[[str], pd.DataFrame],
    broker_frame: pd.DataFrame | None = None,
    config: ScannerConfig | None = None,
    progress: Callable[[int, int, str], None] | None = None,
    run_id: str | None = None,
    official_flow_frame: pd.DataFrame | None = None,
) -> tuple[str, pd.DataFrame, list[dict[str, str]]]:
    config = config or ScannerConfig()
    run_id = run_id or str(uuid.uuid4())
    broker_frame = broker_frame if broker_frame is not None else pd.DataFrame()
    official_flow_frame = official_flow_frame if official_flow_frame is not None else pd.DataFrame()
    rows: list[dict[str, object]] = []
    errors: list[dict[str, str]] = []
    total = len(universe)

    # Load once, then derive free cross-sectional breadth/relative-strength context.
    # The normal managed loader is memory/database-first, so this adds no provider burst.
    price_map: dict[str, pd.DataFrame] = {}
    loader_errors: dict[str, str] = {}
    for ticker in universe:
        t = canonical_ticker(ticker)
        try:
            price_map[t] = price_loader(t)
        except Exception as exc:
            price_map[t] = pd.DataFrame()
            loader_errors[t] = str(exc)
    market_context = compute_market_context(price_map)
    reference_date = market_context.get("reference_date")

    for i, ticker in enumerate(universe, 1):
        t = canonical_ticker(ticker)
        try:
            price = price_map.get(t, pd.DataFrame())
            if price.empty and t in loader_errors:
                raise ValueError(loader_errors[t])
            b = broker_frame[broker_frame["ticker"] == t] if not broker_frame.empty and "ticker" in broker_frame else pd.DataFrame()
            f = official_flow_frame[official_flow_frame["ticker"] == t] if not official_flow_frame.empty and "ticker" in official_flow_frame else pd.DataFrame()
            mf = ticker_market_features(t, market_context)
            rows.append(
                scan_one(
                    t,
                    price,
                    b,
                    config,
                    official_flow=f,
                    market_features=mf,
                    reference_date=str(reference_date) if reference_date else None,
                ).to_dict()
            )
        except Exception as exc:
            errors.append({"ticker": t, "error": str(exc)})
        if progress:
            progress(i, total, t)

    out = pd.DataFrame(rows)
    if not out.empty:
        out = out.sort_values(
            ["real_money_state", "final_score", "ticker"],
            ascending=[True, False, True],
            kind="stable",
        )
    return run_id, out.reset_index(drop=True), errors