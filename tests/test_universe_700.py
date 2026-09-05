from pathlib import Path

import pandas as pd

from idx_flow_scanner.universe_700 import build_universe_700_frame, normalize_sector

ROOT = Path(__file__).resolve().parents[1]


def test_sector_normalization_keeps_market_groups_consistent():
    assert normalize_sector("Energi") == "Energy"
    assert normalize_sector("Keuangan") == "Financials"
    assert normalize_sector("Barang Konsumen Non-Primer") == "Consumer Cyclicals"


def test_expanded_universe_preserves_base_and_adds_by_liquidity():
    base = pd.DataFrame(
        {
            "ticker": ["AAA", "BBB", "CCC", "DDD"],
            "sector": ["Energy", "Technology", "Healthcare", "Industrials"],
        }
    )
    companies = pd.DataFrame(
        {
            "ticker": ["AAA", "BBB", "CCC", "DDD", "EEE", "FFF", "GGG", "HHH"],
            "sector": [
                "Energi",
                "Teknologi",
                "Kesehatan",
                "Perindustrian",
                "Keuangan",
                "Barang Baku",
                "Infrastruktur",
                "Transportasi & Logistik",
            ],
        }
    )
    activity = pd.DataFrame(
        {
            "ticker": ["EEE", "FFF", "GGG", "HHH"],
            "traded_value": [10.0, 40.0, 30.0, 20.0],
            "frequency": [1.0, 1.0, 1.0, 1.0],
            "volume": [1.0, 1.0, 1.0, 1.0],
        }
    )

    out = build_universe_700_frame(base, companies, activity, target_size=7)

    assert out["ticker"].tolist() == ["AAA", "BBB", "CCC", "DDD", "FFF", "GGG", "HHH"]
    assert len(out) == 7
    assert out["ticker"].is_unique
    assert set(base["ticker"]).issubset(set(out["ticker"]))
    assert out.loc[out["ticker"].eq("FFF"), "sector"].iloc[0] == "Basic Materials"
    assert out.loc[out["ticker"].eq("GGG"), "sector"].iloc[0] == "Infrastructures"


def test_bundled_700_snapshot_preserves_legacy_400_and_adds_exactly_300():
    legacy = pd.read_csv(ROOT / "data" / "universe" / "idx_400_syariah.csv")
    expanded = pd.read_csv(ROOT / "data" / "universe" / "idx_700_all.csv")

    legacy_tickers = legacy["ticker"].astype(str).str.upper()
    expanded_tickers = expanded["ticker"].astype(str).str.upper()

    assert len(expanded) == 700
    assert expanded_tickers.nunique() == 700
    assert set(legacy_tickers).issubset(set(expanded_tickers))
    assert int(expanded["universe_source"].eq("LEGACY_400").sum()) == 400
    assert int(expanded["universe_source"].eq("IDX_ACTIVE_LIQUIDITY_ADD").sum()) == 300
