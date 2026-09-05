import pandas as pd

from idx_flow_scanner.universe_700 import build_universe_700_frame, normalize_sector


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
