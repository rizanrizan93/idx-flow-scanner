from pathlib import Path

from idx_flow_scanner.managed import load_bundled_universe


def test_bundled_universe_has_400_unique_tickers():
    root = Path(__file__).resolve().parents[1]
    universe = load_bundled_universe(root / "data" / "universe" / "idx_400_syariah.csv")
    assert len(universe) == 400
    assert len(set(universe)) == 400
    assert universe[0] == "ABMM"
    assert universe[-1] == "WEGE"
