import numpy as np
import pandas as pd

from idx_flow_scanner.data_quality import compute_price_quality_features
from idx_flow_scanner.market_context import compute_market_context, ticker_market_features
from idx_flow_scanner.pipeline import scan_universe


def prices(n=100, start=100.0, drift=0.003, end=None):
    dates = pd.bdate_range("2026-01-02", periods=n)
    close = start * np.cumprod(np.full(n, 1.0 + drift))
    if end is not None:
        dates = pd.bdate_range(end=end, periods=n)
    return pd.DataFrame({
        "date": dates,
        "open": close * 0.997,
        "high": close * 1.01,
        "low": close * 0.99,
        "close": close,
        "volume": np.full(n, 2_000_000.0),
    })


def test_market_context_is_not_permanent_neutral():
    px = {"AAA": prices(drift=0.004), "BBB": prices(drift=0.002), "CCC": prices(drift=-0.001)}
    ctx = compute_market_context(px)
    assert ctx["coverage_count"] == 3
    assert ctx["market_regime_label"] in {"RISK_ON", "CONSTRUCTIVE", "NEUTRAL", "DEFENSIVE", "RISK_OFF"}
    feat = ticker_market_features("AAA", ctx)
    assert feat["market_context_basis"] == "UNIVERSE_BREADTH_RELATIVE_STRENGTH"
    assert feat["market_sector_score"] != 50.0


def test_stale_price_is_downgraded_against_universe_reference():
    fresh = prices(end="2026-08-14")
    stale = prices(end="2026-07-31")
    q_fresh = compute_price_quality_features(fresh, reference_date="2026-08-14")
    q_stale = compute_price_quality_features(stale, reference_date="2026-08-14")
    assert q_fresh["price_staleness_days"] == 0
    assert q_stale["price_staleness_days"] > 3
    assert q_stale["price_data_quality_score"] < q_fresh["price_data_quality_score"]


def test_split_like_gap_is_flagged_without_calling_it_direct_broker_evidence():
    px = prices(n=100, drift=0.001)
    i = 80
    prior = float(px.loc[i-1, "close"])
    px.loc[i:, ["open", "high", "low", "close"]] *= 0.5
    px.loc[i, "open"] = prior * 0.5
    px.loc[i, "high"] = px.loc[i, "open"] * 1.02
    px.loc[i, "low"] = px.loc[i, "open"] * 0.98
    px.loc[i, "close"] = px.loc[i, "open"] * 1.01
    q = compute_price_quality_features(px, reference_date=px["date"].iloc[-1])
    assert q["split_like_event_recent"] is True
    assert q["split_like_factor"] == 0.5
    assert q["price_data_quality_score"] < 80


def test_scan_universe_populates_cross_sectional_market_component():
    price_map = {"AAA": prices(drift=0.004), "BBB": prices(drift=0.002), "CCC": prices(drift=-0.001)}
    _, results, errors = scan_universe(["AAA", "BBB", "CCC"], lambda t: price_map[t])
    assert not errors
    assert len(results) == 3
    assert "market_context_score" in results.columns
    assert results["market_context_score"].nunique() >= 2
    assert "price_data_quality_score" in results.columns
