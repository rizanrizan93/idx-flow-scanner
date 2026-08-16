from __future__ import annotations

import numpy as np
import pandas as pd

from idx_flow_scanner.config import ScannerConfig
from idx_flow_scanner.data import normalize_broker_summary
from idx_flow_scanner.engines.flow import compute_broker_features


def test_zero_sum_broker_market_can_still_show_persistent_accumulator_cohort():
    dates = pd.bdate_range("2026-05-01", periods=60)
    rows = []
    buyers = [("YP", 1.0), ("BK", 0.8), ("AK", 0.6)]
    sellers = [("NI", 1.0), ("PD", 0.8), ("CC", 0.6)]
    for d in dates:
        for code, scale in buyers:
            rows.append({
                "ticker":"TEST","trade_date":d,"broker_code":code,
                "buy_value":12_000_000*scale,"sell_value":2_000_000*scale,
                "buy_volume":120_000*scale,"sell_volume":20_000*scale,
                "buy_avg":104.0,"sell_avg":105.0,
            })
        for code, scale in sellers:
            rows.append({
                "ticker":"TEST","trade_date":d,"broker_code":code,
                "buy_value":2_000_000*scale,"sell_value":12_000_000*scale,
                "buy_volume":20_000*scale,"sell_volume":120_000*scale,
                "buy_avg":104.0,"sell_avg":105.0,
            })
    broker = normalize_broker_summary(pd.DataFrame(rows))
    close = 104 + np.linspace(0, 4, len(dates))
    price = pd.DataFrame({
        "date":dates,"open":close-0.5,"high":close+1,"low":close-1,"close":close,
        "volume":np.full(len(dates),2_000_000),
    })
    feat = compute_broker_features(broker, price, ScannerConfig())
    assert feat["broker_balance_error_pct"] < 1e-9
    assert feat["persistence_20d"] > 0.95
    assert feat["broker_cohort_stability"] > 0.95
    assert feat["accumulation_score"] > 65
    assert feat["top_accumulating_brokers"][0] == "YP"
