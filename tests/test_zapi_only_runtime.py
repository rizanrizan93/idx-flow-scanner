from __future__ import annotations

from datetime import date
from io import BytesIO
from pathlib import Path

import numpy as np
import pandas as pd

import idx_flow_scanner.providers.zapi_slow as zapi_slow
from idx_flow_scanner.calibration import build_calibration_report, calibration_readiness
from idx_flow_scanner.config import ZapiFlowConfig, ZapiFlowWeights
from idx_flow_scanner.decision import select_execution_ready, select_zapi_decision_top
from idx_flow_scanner.market_context import compute_market_context, ticker_market_features
from idx_flow_scanner.providers.zapi_slow import (
    fetch_zapi_company_profile_ownership,
    normalize_zapi_capital_actions,
    parse_ownership_workbook,
)
from idx_flow_scanner.slow_evidence import compute_slow_evidence


def _price(ticker: str, start: float, end: float, periods: int = 90) -> pd.DataFrame:
    dates = pd.bdate_range("2026-04-20", periods=periods)
    close = np.linspace(start, end, periods)
    return pd.DataFrame(
        {
            "ticker": ticker,
            "date": dates,
            "open": close,
            "high": close * 1.01,
            "low": close * 0.99,
            "close": close,
            "volume": np.full(periods, 1_000_000.0),
        }
    )


def test_active_zapi_weights_sum_to_one_and_have_no_broker_component():
    weights = ZapiFlowWeights()
    weights.validate()
    assert abs(sum(weights.as_dict().values()) - 1.0) < 1e-12
    assert all("broker" not in key for key in weights.as_dict())
    assert ZapiFlowConfig().minimum_foreign_coverage_pct == 80.0


def test_sector_context_is_explicit_when_sector_map_is_available():
    prices = {
        "AAAA": _price("AAAA", 100, 150),
        "AAAB": _price("AAAB", 100, 145),
        "AAAC": _price("AAAC", 100, 140),
        "BBBB": _price("BBBB", 100, 105),
        "BBBC": _price("BBBC", 100, 102),
        "BBBD": _price("BBBD", 100, 98),
    }
    sectors = {
        "AAAA": "Technology",
        "AAAB": "Technology",
        "AAAC": "Technology",
        "BBBB": "Energy",
        "BBBC": "Energy",
        "BBBD": "Energy",
    }
    context = compute_market_context(prices, sector_map=sectors)
    features = ticker_market_features("AAAA", context)
    assert features["sector"] == "Technology"
    assert features["sector_context_coverage"] == 3
    assert features["market_context_basis"] == "MARKET_30__SECTOR_30__SECTOR_RS_25__MARKET_RS_15"
    assert features["sector_regime_score"] > 50


def test_free_float_and_foreign_flow_are_normalized_to_tradable_shares():
    price = _price("AAAA", 100, 110)
    stock = pd.DataFrame(
        [
            {
                "ticker": "AAAA",
                "trade_date": "2026-08-31",
                "listed_shares": 1_000_000,
                "tradable_shares": 200_000,
            }
        ]
    )
    features = compute_slow_evidence(
        "AAAA",
        price,
        {"foreign_net_20d": 20_000},
        stock_summary=stock,
    )
    assert features["free_float_pct"] == 20.0
    assert features["foreign_net_to_float_20d_pct"] == 10.0
    assert features["free_float_structure_score"] > 50


def test_ownership_workbook_is_factual_and_period_bounded():
    raw = pd.DataFrame(
        [
            [
                "Kode Emiten",
                "Nama Pemegang Saham",
                "Jumlah Saham",
                "Persentase Kepemilikan",
                "Lokal Asing",
                "Tanggal Posisi",
            ],
            ["AAAA", "Institution A", 100_000, "10,0%", "ASING", "31/08/2026"],
        ]
    )
    buffer = BytesIO()
    with pd.ExcelWriter(buffer, engine="openpyxl") as writer:
        raw.to_excel(writer, sheet_name="Data", header=False, index=False)
    frame = parse_ownership_workbook(
        buffer.getvalue(),
        category="lima-persen",
        publication_date=date(2026, 9, 1),
        source_url="https://www.ksei.co.id/files/ownership.xlsx",
    )
    assert len(frame) == 1
    row = frame.iloc[0]
    assert row["ticker"] == "AAAA"
    assert row["ownership_percentage"] == 10.0
    assert row["local_foreign_state"] == "ASING"
    assert row["report_date"] == "2026-08-31"
    assert row["source_verified"] is True or bool(row["source_verified"]) is True



def test_company_profile_ownership_fallback_is_structured_and_bounded(monkeypatch):
    def fake_request(url, params, *, api_key, timeout):
        assert url == zapi_slow.COMPANY_PROFILE_URL
        assert params == {"code": "AAAA"}
        assert api_key == "zpi_test"
        return {
            "code": "AAAA",
            "dataset": "company-profile",
            "provider": "idx",
            "shareholders": [
                {
                    "name": "Institution A",
                    "shares": 600_000,
                    "category": "Lebih dari 5%",
                    "sharePct": 60.0,
                }
            ],
        }

    monkeypatch.setattr(zapi_slow, "_request_json", fake_request)
    frame, meta = fetch_zapi_company_profile_ownership(
        ["AAAA", "BBBB"],
        observed_on=date(2026, 9, 2),
        api_key="zpi_test",
        max_tickers=1,
    )

    assert frame["ticker"].tolist() == ["AAAA"]
    assert frame.iloc[0]["ownership_percentage"] == 60.0
    assert frame.iloc[0]["report_date"] == "2026-09-02"
    assert frame.iloc[0]["report_date_kind"] == "OBSERVED_PROFILE_SNAPSHOT"
    assert frame.iloc[0]["provenance_state"] == "VERIFIED_IDX_COMPANY_PROFILE_VIA_ZAPI"
    assert meta["requests_attempted"] == 1
    assert meta["tickers_requested"] == 1
    assert meta["tickers_with_rows"] == 1

def test_upcoming_material_rights_issue_becomes_slow_evidence_hard_block():
    actions = normalize_zapi_capital_actions(
        [
            {
                "code": "AAAA",
                "eventDate": "2026-09-10",
                "action": "rights issue",
                "sharesBefore": 1_000_000,
                "newSharesIssued": 200_000,
            }
        ],
        feed="rights-offerings",
        source_period=date(2026, 9, 1),
        observed_on=date(2026, 9, 2),
    )
    assert float(actions.iloc[0]["delta_percent"]) == 20.0
    price = _price("AAAA", 100, 110)
    price["date"] = pd.bdate_range(end="2026-09-02", periods=len(price))
    features = compute_slow_evidence(
        "AAAA",
        price,
        {"foreign_net_20d": 0.0},
        capital_actions=actions,
    )
    assert features["slow_evidence_hard_block"] is True
    assert features["recent_dilution_pct"] == 20.0


def test_decision_lanes_require_zapi_and_authorization():
    diagnostics = {
        "foreign_window_state": "FULL",
        "foreign_data_freshness": "FRESH",
        "foreign_data_valid": True,
    }
    frame = pd.DataFrame(
        [
            {
                "ticker": "AAAA",
                "final_score": 80.0,
                "phase": "ACCUMULATION",
                "action": "BUY_ON_WEAKNESS",
                "evidence_tier": "ZAPI_FLOW",
                "distribution_risk": 20.0,
                "price_data_quality_score": 95.0,
                "accumulation_score": 80.0,
                "foreign_institutional_score": 75.0,
                "market_context_score": 70.0,
                "smc_execution_score": 70.0,
                "production_authorized": True,
                "diagnostics": diagnostics,
            },
            {
                "ticker": "BBBB",
                "final_score": 90.0,
                "phase": "ACCUMULATION",
                "action": "RESEARCH_ONLY",
                "evidence_tier": "PRICE_PROXY",
                "distribution_risk": 20.0,
                "price_data_quality_score": 95.0,
                "accumulation_score": 90.0,
                "foreign_institutional_score": 50.0,
                "market_context_score": 70.0,
                "smc_execution_score": 70.0,
                "production_authorized": False,
                "diagnostics": diagnostics,
            },
        ]
    )
    decision = select_zapi_decision_top(frame, top_n=20)
    ready = select_execution_ready(frame, top_n=10)
    assert decision["ticker"].tolist() == ["AAAA"]
    assert ready["ticker"].tolist() == ["AAAA"]


def test_calibration_is_shadow_only_until_sample_is_large_enough():
    outcomes = pd.DataFrame(
        {
            "final_score": [62, 68, 72, 78, 82] * 10,
            "phase": ["ACCUMULATION"] * 50,
            "evidence_tier": ["ZAPI_FLOW"] * 50,
            "return_5d": np.linspace(-1, 3, 50),
            "return_20d": np.linspace(-2, 8, 50),
            "return_60d": [np.nan] * 50,
            "mfe_20d": np.linspace(1, 12, 50),
            "mae_20d": np.linspace(-8, -1, 50),
        }
    )
    readiness = calibration_readiness(outcomes)
    report = build_calibration_report(outcomes)
    assert readiness["ready_for_threshold_review"] is False
    assert readiness["ready_for_weight_review"] is False
    assert not report.empty


def test_active_runtime_and_warm_job_do_not_call_broker_providers():
    root = Path(__file__).resolve().parents[1]
    app = (root / "app.py").read_text(encoding="utf-8")
    streamlit = (root / "src/idx_flow_scanner/streamlit_app.py").read_text(encoding="utf-8")
    run_body = streamlit.split("def run() -> None:", 1)[1]
    builder = (root / "scripts/build_flow_evidence_cache.py").read_text(encoding="utf-8")
    workflow = (root / ".github/workflows/warm-flow-evidence.yml").read_text(encoding="utf-8")

    assert "install_cache_only_indexalpha_finalist_loader" not in app
    assert "install_universe_wide_idx_broker" not in app
    assert "_load_indexalpha_for_finalists(" not in run_body
    assert "verify_guarded_top5(" not in run_body
    assert "GOAPI_KEY" not in workflow
    assert "INDEX_ALPHA_KEY" not in workflow
    assert "ZAPI_OWNERSHIP_PROFILE_FALLBACK_LIMIT" in workflow
    assert "* * 1-5" in workflow
    assert "fetch_goapi" not in builder
    assert "fetch_indexalpha" not in builder
    assert "fetch_idx_official" not in builder
