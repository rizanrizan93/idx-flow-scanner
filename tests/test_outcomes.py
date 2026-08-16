from __future__ import annotations

import numpy as np
import pandas as pd

from idx_flow_scanner.outcomes import compute_signal_outcome


def test_forward_outcome_uses_only_future_bars_after_signal():
    dates = pd.bdate_range("2026-01-02", periods=90)
    close = 100 + np.arange(90, dtype=float)
    price = pd.DataFrame({
        "date": dates,
        "open": close - 0.5,
        "high": close + 1.0,
        "low": close - 1.0,
        "close": close,
        "volume": 1_000_000,
    })
    out = compute_signal_outcome(price, dates[10])
    assert round(out.entry_close, 6) == 110.0
    assert round(out.return_5d, 6) == round(100 * (115 / 110 - 1), 6)
    assert round(out.return_20d, 6) == round(100 * (130 / 110 - 1), 6)
    assert out.return_60d is not None
    assert out.evaluation_status == "COMPLETE"
