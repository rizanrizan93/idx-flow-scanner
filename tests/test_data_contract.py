import pandas as pd
import pytest
from idx_flow_scanner.data import completed_idx_session_frame, normalize_broker_summary, normalize_price_frame


def test_broker_contract_rejects_missing_columns():
    with pytest.raises(ValueError):
        normalize_broker_summary(pd.DataFrame({"ticker":["ELSA"]}))



def test_intraday_current_daily_bar_is_excluded_before_market_close():
    raw = pd.DataFrame({
        "date": ["2026-08-27", "2026-08-28"],
        "open": [100.0, 110.0],
        "high": [101.0, 150.0],
        "low": [99.0, 90.0],
        "close": [100.0, 145.0],
        "volume": [1_000_000, 10_000_000],
    })
    normalized = normalize_price_frame(raw)
    out = completed_idx_session_frame(
        normalized,
        now="2026-08-28T10:00:00+07:00",
    )

    assert out["date"].dt.strftime("%Y-%m-%d").tolist() == ["2026-08-27"]


def test_current_daily_bar_is_allowed_only_after_regular_session_close():
    raw = pd.DataFrame({
        "date": ["2026-08-27", "2026-08-28"],
        "open": [100.0, 101.0],
        "high": [101.0, 103.0],
        "low": [99.0, 100.0],
        "close": [100.0, 102.0],
        "volume": [1_000_000, 1_200_000],
    })
    normalized = normalize_price_frame(raw)
    out = completed_idx_session_frame(
        normalized,
        now="2026-08-28T17:00:00+07:00",
    )

    assert out["date"].dt.strftime("%Y-%m-%d").tolist() == ["2026-08-27", "2026-08-28"]
