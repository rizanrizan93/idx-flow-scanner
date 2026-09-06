import json
from pathlib import Path

import pandas as pd

from idx_flow_scanner.evidence_700 import (
    enrich_universe_sector_metadata,
    write_evidence_coverage_report,
)


def test_persisted_700_universe_has_complete_sector_metadata():
    frame = pd.read_csv(Path("data/universe/idx_700_all.csv"))
    assert len(frame) == 700
    assert frame["ticker"].astype(str).str.upper().nunique() == 700
    sector = frame["sector"].fillna("UNKNOWN").astype(str).str.upper()
    assert not sector.isin({"", "UNKNOWN", "NAN", "NONE", "NULL"}).any()


def test_sector_enrichment_carries_forward_known_metadata_without_web(tmp_path):
    path = tmp_path / "idx_700_all.csv"
    pd.DataFrame(
        {
            "ticker": ["AAAA", "BBBB", "CCCC"],
            "sector": ["Energy", "UNKNOWN", "UNKNOWN"],
            "universe_source": ["LEGACY_400", "IDX_ACTIVE_LIQUIDITY_ADD", "IDX_ACTIVE_LIQUIDITY_ADD"],
        }
    ).to_csv(path, index=False)
    previous = pd.DataFrame(
        {
            "ticker": ["BBBB", "CCCC"],
            "sector": ["Financial Services", "Teknologi"],
        }
    )

    meta = enrich_universe_sector_metadata(
        path,
        previous_frame=previous,
        max_web_requests=0,
    )
    out = pd.read_csv(path).set_index("ticker")

    assert out.loc["AAAA", "sector"] == "Energy"
    assert out.loc["BBBB", "sector"] == "Financials"
    assert out.loc["CCCC", "sector"] == "Technology"
    assert meta["coverage_pct"] == 100.0
    assert meta["requests"] == 0


def test_evidence_coverage_report_measures_real_intersections(tmp_path):
    universe_path = tmp_path / "idx_700_all.csv"
    cache_dir = tmp_path / "cache"
    cache_dir.mkdir()
    output_path = cache_dir / "idx_700_evidence_coverage.json"

    pd.DataFrame(
        {
            "ticker": ["AAAA", "BBBB", "CCCC"],
            "sector": ["Energy", "Financials", "Technology"],
        }
    ).to_csv(universe_path, index=False)
    pd.DataFrame(
        {
            "ticker": ["AAAA", "BBBB", "CCCC"],
            "date": ["2026-09-04"] * 3,
            "close": [100, 200, 300],
        }
    ).to_csv(cache_dir / "idx_700_ohlcv_1y.csv.gz", index=False, compression="gzip")
    pd.DataFrame(
        {
            "ticker": ["AAAA", "BBBB"],
            "trade_date": ["2026-09-04", "2026-09-04"],
            "foreign_net": [10, 20],
        }
    ).to_csv(cache_dir / "zapi_idx_foreign_60d.csv.gz", index=False, compression="gzip")
    pd.DataFrame(
        {
            "ticker": ["AAAA", "BBBB"],
            "listed_shares": [1000, 1000],
            "tradable_shares": [400, 500],
        }
    ).to_csv(cache_dir / "zapi_stock_summary_latest.csv.gz", index=False, compression="gzip")
    pd.DataFrame(
        {
            "ticker": ["AAAA"],
            "report_date": ["2026-09-01"],
        }
    ).to_csv(cache_dir / "zapi_ownership_latest.csv.gz", index=False, compression="gzip")
    pd.DataFrame(
        {
            "ticker": ["BBBB"],
            "event_date": ["2026-09-04"],
            "event_type": ["STOCK_SPLIT"],
        }
    ).to_csv(cache_dir / "zapi_capital_actions.csv.gz", index=False, compression="gzip")
    (cache_dir / "flow_evidence_meta.json").write_text(
        json.dumps(
            {
                "zapi_idx_foreign": {"status": "UPDATED"},
                "zapi_stock_summary": {"status": "UPDATED"},
                "zapi_ownership": {"status": "UPDATED"},
                "zapi_capital_actions": {"status": "UPDATED"},
            }
        ),
        encoding="utf-8",
    )

    report = write_evidence_coverage_report(
        universe_path,
        cache_dir=cache_dir,
        output_path=output_path,
    )

    assert report["schema_version"] == 2
    assert report["coverage"]["ohlcv"]["tickers"] == 3
    assert report["coverage"]["foreign_flow"]["tickers"] == 2
    assert report["coverage"]["stock_summary"]["tickers"] == 2
    assert report["coverage"]["free_float"]["tickers"] == 0
    assert report["coverage"]["free_float"]["required_for_core"] is False
    assert report["coverage"]["free_float"]["semantics"] == "UNAVAILABLE_NOT_INFERRED_FROM_TRADABLE_SHARES"
    assert report["coverage"]["ownership"]["tickers"] == 1
    assert report["coverage"]["core_complete"]["tickers"] == 2
    assert report["coverage"]["full_complete_including_ownership"]["tickers"] == 1
    assert report["coverage"]["corporate_action_events"]["tickers_with_events"] == 1
    assert report["readiness_contract"]["free_float_required_for_core"] is False
    assert output_path.exists()
