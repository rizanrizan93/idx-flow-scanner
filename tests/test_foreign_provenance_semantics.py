import pandas as pd

from idx_flow_scanner.engines.flow import compute_official_foreign_features


def _price(dates):
    return pd.DataFrame({
        "date": dates,
        "open": 100.0,
        "high": 101.0,
        "low": 99.0,
        "close": 100.0,
        "volume": 10_000_000,
    })


def _flow(dates, source):
    return pd.DataFrame({
        "trade_date": dates,
        "foreign_buy": 1_500_000,
        "foreign_sell": 500_000,
        "foreign_net": 1_000_000,
        "volume": 10_000_000,
        "source": source,
        "foreign_evidence_source": source,
    })


def test_zapi_coverage_is_verified_foreign_but_not_direct_idx_official():
    dates = pd.bdate_range("2026-07-20", periods=20)
    feat = compute_official_foreign_features(
        _flow(dates, "ZAPI_IDX_FOREIGN_FLOW"), _price(dates)
    )
    assert feat["foreign_evidence_coverage_pct"] == 100.0
    assert feat["official_foreign_coverage_pct"] == 0.0
    assert feat["foreign_evidence_source"] == "ZAPI_IDX_FOREIGN_FLOW"


def test_direct_idx_coverage_remains_official():
    dates = pd.bdate_range("2026-07-20", periods=20)
    feat = compute_official_foreign_features(
        _flow(dates, "IDX_OFFICIAL_STOCK_SUMMARY"), _price(dates)
    )
    assert feat["foreign_evidence_coverage_pct"] == 100.0
    assert feat["official_foreign_coverage_pct"] == 100.0
    assert feat["foreign_evidence_source"] == "IDX_OFFICIAL_STOCK_SUMMARY"
