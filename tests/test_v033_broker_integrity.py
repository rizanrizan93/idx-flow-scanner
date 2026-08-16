from pathlib import Path

import numpy as np
import pandas as pd

from idx_flow_scanner.data import normalize_broker_summary
from idx_flow_scanner.pipeline import scan_one


ROOT = Path(__file__).resolve().parents[1]


def _prices(n: int = 100) -> pd.DataFrame:
    dates = pd.bdate_range("2026-01-02", periods=n)
    close = 100.0 + np.linspace(0, 8, n) + np.sin(np.arange(n) / 5.0)
    return pd.DataFrame(
        {
            "date": dates,
            "open": close - 0.5,
            "high": close + 1.0,
            "low": close - 1.0,
            "close": close,
            "volume": np.full(n, 2_000_000),
        }
    )


def _balanced_broker(dates: pd.Series) -> pd.DataFrame:
    rows: list[dict[str, object]] = []
    buyers = [("YP", 1.0), ("BK", 0.8), ("AK", 0.6)]
    sellers = [("NI", 1.0), ("PD", 0.8), ("CC", 0.6)]
    for day in dates:
        for code, scale in buyers:
            rows.append(
                {
                    "ticker": "TEST",
                    "trade_date": day,
                    "broker_code": code,
                    "buy_value": 10_000_000 * scale,
                    "sell_value": 2_000_000 * scale,
                    "buy_volume": 100_000 * scale,
                    "sell_volume": 20_000 * scale,
                    "buy_avg": 104.0,
                    "sell_avg": 105.0,
                    "market_type": "RG",
                    "source": "INDEX_ALPHA_BROKER_SUMMARY",
                    "source_verified": True,
                    "source_url": "https://api.indexalpha.id/stocks/broker-summary",
                    "provenance_state": "VERIFIED_VENDOR_API_EXACT_DAY_ALL_RG_VOLUME_UNIT_PROVIDER_NATIVE",
                }
            )
        for code, scale in sellers:
            rows.append(
                {
                    "ticker": "TEST",
                    "trade_date": day,
                    "broker_code": code,
                    "buy_value": 2_000_000 * scale,
                    "sell_value": 10_000_000 * scale,
                    "buy_volume": 20_000 * scale,
                    "sell_volume": 100_000 * scale,
                    "buy_avg": 104.0,
                    "sell_avg": 105.0,
                    "market_type": "RG",
                    "source": "INDEX_ALPHA_BROKER_SUMMARY",
                    "source_verified": True,
                    "source_url": "https://api.indexalpha.id/stocks/broker-summary",
                    "provenance_state": "VERIFIED_VENDOR_API_EXACT_DAY_ALL_RG_VOLUME_UNIT_PROVIDER_NATIVE",
                }
            )
    return normalize_broker_summary(pd.DataFrame(rows))


def test_broker_direct_requires_price_freshness_gate():
    price = _prices()
    broker = _balanced_broker(price["date"].tail(60))
    last_day = pd.Timestamp(price["date"].iloc[-1]).normalize()

    fresh = scan_one("TEST", price, broker, reference_date=str(last_day.date()))
    assert fresh.evidence_tier == "BROKER_DIRECT"
    assert fresh.diagnostics["broker_alpha_applied"] is True

    stale_reference = last_day + pd.Timedelta(days=10)
    stale = scan_one("TEST", price, broker, reference_date=str(stale_reference.date()))
    assert stale.evidence_tier == "PRICE_PROXY"
    assert stale.real_money_state == "GUARDED"
    assert stale.diagnostics["broker_alpha_applied"] is False
    assert stale.estimated_smart_money_cost is None
    assert "price stale" in stale.guardrail_reason


def test_scheduled_indexalpha_budget_is_exactly_five():
    workflow = (ROOT / ".github" / "workflows" / "warm-flow-evidence.yml").read_text(encoding="utf-8")
    assert "INDEX_ALPHA_DAILY_BUDGET: '5'" in workflow
    assert "pinned five-ticker cohort" in workflow


def test_indexalpha_persistence_migration_requires_exact_provenance_and_balance():
    migration = (
        ROOT
        / "supabase"
        / "migrations"
        / "20260816160228_indexalpha_persistence_integrity_v033.sql"
    ).read_text(encoding="utf-8")
    assert "VERIFIED_VENDOR_API_EXACT_DAY_ALL_RG_VOLUME_UNIT_PROVIDER_NATIVE" in migration
    assert "v_error > 10" in migration
    assert "source_verified is not true" in migration
