import numpy as np
import pandas as pd

from idx_flow_scanner.official_index_context import apply_official_index_overlay


def _index_frame(*, sector_code="IDXENERGY", sector_growth=1.20, market_growth=1.08, periods=30):
    dates = pd.bdate_range("2026-07-27", periods=periods)
    rows = []
    for code, growth in (("COMPOSITE", market_growth), (sector_code, sector_growth)):
        closes = np.geomspace(100.0, 100.0 * growth, periods)
        for day, close in zip(dates, closes):
            rows.append(
                {
                    "trade_date": day,
                    "index_code": code,
                    "close": close,
                    "source": "IDX_OFFICIAL_INDEX_SUMMARY",
                    "source_verified": True,
                    "provenance_state": "VERIFIED_OFFICIAL_IDX_INDEX_SUMMARY",
                }
            )
    return pd.DataFrame(rows)


def _base(sector="Energy", score=50.0):
    return {
        "sector": sector,
        "market_sector_score": score,
        "market_context_basis": "INTERNAL_CONTEXT",
        "unrelated_key": "preserved",
    }


def test_known_sector_gets_55pct_official_overlay():
    frame = _index_frame()
    result = apply_official_index_overlay(
        "ADRO",
        _base("Energy", 50.0),
        reference_date=frame["trade_date"].max(),
        frame=frame,
    )
    assert result["official_index_context_available"] is True
    assert result["official_sector_index_code"] == "IDXENERGY"
    assert result["market_context_official_weight"] == 0.55
    assert result["market_sector_score"] > 50.0
    assert result["official_sector_relative_strength_20d_pct"] > 0
    assert result["unrelated_key"] == "preserved"
    assert result["market_context_basis"].endswith("__OFFICIAL_IDX_INDEX_OVERLAY")


def test_unknown_sector_uses_market_only_30pct_overlay():
    frame = _index_frame()
    result = apply_official_index_overlay(
        "TEST",
        _base("Unknown Future Sector", 55.0),
        reference_date=frame["trade_date"].max(),
        frame=frame,
    )
    assert result["official_index_context_available"] is True
    assert result["official_sector_index_code"] is None
    assert result["market_context_official_weight"] == 0.30
    assert result["official_sector_regime_label"] == "UNAVAILABLE"


def test_stale_official_index_is_fail_neutral():
    frame = _index_frame()
    base = _base("Energy", 61.0)
    reference_date = pd.Timestamp(frame["trade_date"].max()) + pd.Timedelta(days=10)
    result = apply_official_index_overlay(
        "ADRO",
        base,
        reference_date=reference_date,
        frame=frame,
    )
    assert result["market_sector_score"] == 61.0
    assert result["official_index_context_available"] is False
    assert result["market_context_official_weight"] == 0.0


def test_missing_index_frame_is_fail_neutral():
    base = _base("Energy", 47.0)
    result = apply_official_index_overlay("ADRO", base, frame=pd.DataFrame())
    assert result["market_sector_score"] == 47.0
    assert result["official_index_context_available"] is False
    assert result["unrelated_key"] == "preserved"
