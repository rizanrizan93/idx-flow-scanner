from pathlib import Path

import numpy as np
import pandas as pd

from idx_flow_scanner.data_quality import compute_price_quality_features


def _split_frame(total=100, event_index=80):
    dates = pd.bdate_range("2026-01-02", periods=total)
    close = np.full(total, 100.0)
    open_ = np.full(total, 100.0)
    high = np.full(total, 102.0)
    low = np.full(total, 98.0)
    volume = np.full(total, 2_000_000.0)
    open_[event_index:] = 50.0
    close[event_index:] = 50.0
    high[event_index:] = 51.0
    low[event_index:] = 49.0
    return pd.DataFrame({
        "date": dates,
        "open": open_,
        "high": high,
        "low": low,
        "close": close,
        "volume": volume,
    })


def test_recent_split_like_event_guards_price_quality():
    price = _split_frame(total=100, event_index=80)
    q = compute_price_quality_features(price, reference_date=price["date"].iloc[-1])
    assert q["split_like_event_detected"] is True
    assert q["split_like_event_recent"] is True
    assert q["split_like_bars_ago"] == 19
    assert q["price_data_quality_score"] < 100


def test_old_split_like_event_stops_blocking_after_60_post_event_bars():
    price = _split_frame(total=130, event_index=50)
    q = compute_price_quality_features(price, reference_date=price["date"].iloc[-1])
    assert q["split_like_event_detected"] is True
    assert q["split_like_event_recent"] is False
    assert q["split_like_bars_ago"] == 79


def test_oos_sql_requires_exact_baseline_and_excludes_forward_corporate_actions():
    text = Path("supabase/migrations/20260816045000_broker_provenance_and_oos_exclusion.sql").read_text()
    assert "ep.trade_date = o.as_of_date" in text
    assert "CORPORATE_ACTION_LIKE_GAP_IN_FORWARD_WINDOW" in text
    assert "'EXCLUDED'" in text
    assert "o.evaluation_status in ('PENDING','PARTIAL')" in text


def test_zero_volume_ratios_are_explicit_across_20d_and_60d_windows():
    price = _split_frame(total=100, event_index=20)
    price.loc[price.index[-15:], "volume"] = 0.0
    q = compute_price_quality_features(price, reference_date=price["date"].iloc[-1])
    assert q["zero_volume_ratio_20d"] == 0.75
    assert q["zero_volume_ratio_60d"] == 0.25
