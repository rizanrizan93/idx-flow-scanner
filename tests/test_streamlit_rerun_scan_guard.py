from __future__ import annotations

from pathlib import Path

import pandas as pd

from idx_flow_scanner.operational_top900 import apply_operational_membership_guards


ROOT = Path(__file__).resolve().parents[1]


def _membership() -> pd.DataFrame:
    rows = []
    for index in range(900):
        ticker = f"A{index:03d}"
        rows.append(
            {
                "snapshot_date": "2026-09-09",
                "ticker": ticker,
                "universe_rank": index + 1,
                "current_tradeable": index != 1,
                "production_actionable": index != 1,
                "data_quality_state": "PASS",
                "liquidity_state": "LIQUID",
                "runtime_ranking_eligible": True,
            }
        )
    return pd.DataFrame(rows)


def _results() -> pd.DataFrame:
    return pd.DataFrame(
        [
            {
                "ticker": "A000",
                "final_score": 90.0,
                "production_authorized": True,
                "real_money_state": "EXECUTION_READY",
                "action": "BUY",
                "diagnostics": {},
                "guardrail_reason": None,
            },
            {
                "ticker": "A001",
                "final_score": 95.0,
                "production_authorized": True,
                "real_money_state": "EXECUTION_READY",
                "action": "BUY",
                "diagnostics": {},
                "guardrail_reason": None,
            },
            {
                "ticker": "A002",
                "final_score": 80.0,
                "production_authorized": True,
                "real_money_state": "WATCHLIST",
                "action": "WATCH",
                "diagnostics": {},
                "guardrail_reason": None,
            },
        ]
    )


def test_operational_membership_guard_is_idempotent_with_existing_scanner_rank() -> None:
    membership = _membership()
    once = apply_operational_membership_guards(_results(), membership)
    twice = apply_operational_membership_guards(once, membership)

    assert list(twice.columns).count("scanner_rank") == 1
    assert twice.columns[0] == "scanner_rank"

    first_rank = once.set_index("ticker")["scanner_rank"].to_dict()
    second_rank = twice.set_index("ticker")["scanner_rank"].to_dict()
    assert second_rank == first_rank == {"A000": 2, "A001": 1, "A002": 3}

    blocked = twice.set_index("ticker").loc["A001"]
    assert bool(blocked["production_authorized"]) is False
    assert blocked["real_money_state"] == "GUARDED"
    assert blocked["action"] == "RESEARCH_ONLY"
    assert (
        str(blocked["guardrail_reason"]).count(
            "Top-900 member is not currently production-actionable"
        )
        == 1
    )


def test_app_captures_pristine_patch_targets_once_across_streamlit_reruns() -> None:
    source = (ROOT / "app.py").read_text(encoding="utf-8")

    assert "def _capture_original(" in source
    for sentinel in (
        "_idx_flow_original_connect_store",
        "_idx_flow_original_zapi_foreign",
        "_idx_flow_original_scan_one_zapi",
        "_idx_flow_original_scan_universe_zapi",
        "_idx_flow_original_ticker_market_features",
        "_idx_flow_original_render_health_cards",
        "_idx_flow_original_render_section",
        "_idx_flow_original_st_columns",
        "_idx_flow_original_create_durable_run_record",
        "_idx_flow_original_stock_summary_loader",
        "_idx_flow_original_ownership_loader",
        "_idx_flow_original_capital_actions_loader",
    ):
        assert sentinel in source

    assert "_original_scan_universe_zapi = streamlit_app.scan_universe_zapi" not in source
    assert "guarded.insert(0, \"scanner_rank\"" not in (
        ROOT / "src/idx_flow_scanner/operational_top900.py"
    ).read_text(encoding="utf-8")
