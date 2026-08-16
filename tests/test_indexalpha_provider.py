import pandas as pd

from idx_flow_scanner.providers.indexalpha import (
    INDEX_ALPHA_SOURCE,
    choose_indexalpha_daily_jobs,
    normalize_indexalpha_broker_payload,
)


def test_indexalpha_normalizer_keeps_stock_level_buy_sell_and_avg():
    payload = {
        "success": True,
        "data": [
            {
                "code": "YP",
                "buy_freq": 12,
                "buy_volume": 1500,
                "buy_value": 15000000,
                "sell_freq": 4,
                "sell_volume": 500,
                "sell_value": 5100000,
                "buy_avg": 10000,
                "sell_avg": 10200,
            },
            {
                "code": "CC",
                "buy_freq": 3,
                "buy_volume": 200,
                "buy_value": 1980000,
                "sell_freq": 8,
                "sell_volume": 700,
                "sell_value": 7000000,
                "buy_avg": 9900,
                "sell_avg": 10000,
            },
        ],
    }
    out = normalize_indexalpha_broker_payload(payload, "BBCA.JK", "2026-08-14")
    assert len(out) == 2
    assert set(out["broker_code"]) == {"YP", "CC"}
    assert set(out["ticker"]) == {"BBCA"}
    assert set(out["trade_date"].dt.strftime("%Y-%m-%d")) == {"2026-08-14"}
    assert set(out["source"]) == {INDEX_ALPHA_SOURCE}
    assert out["source_verified"].all()
    yp = out[out["broker_code"].eq("YP")].iloc[0]
    assert float(yp["buy_value"]) == 15000000
    assert float(yp["sell_value"]) == 5100000
    assert float(yp["buy_avg"]) == 10000
    assert float(yp["sell_avg"]) == 10200
    assert float(yp["net_value"]) == 9900000
    assert "EXACT_DAY" in yp["provenance_state"]


def test_indexalpha_scheduler_builds_same_five_daily_before_older_backfill():
    targets = ["MMIX", "PKPK", "DAYA", "MDLA", "OMED"]
    dates = ["2026-08-14", "2026-08-13", "2026-08-12"]
    jobs = choose_indexalpha_daily_jobs(targets, pd.DataFrame(), dates, budget_requests=5)
    assert jobs == [(ticker, "2026-08-14") for ticker in targets]

    existing = pd.DataFrame({
        "ticker": targets,
        "trade_date": [pd.Timestamp("2026-08-14")] * 5,
    })
    jobs = choose_indexalpha_daily_jobs(targets, existing, dates, budget_requests=5)
    assert jobs == [(ticker, "2026-08-13") for ticker in targets]


def test_indexalpha_scheduler_never_invents_missing_dates():
    jobs = choose_indexalpha_daily_jobs(
        ["MMIX", "PKPK"], pd.DataFrame(), ["2026-08-14", "2026-08-12"], budget_requests=4
    )
    assert jobs == [
        ("MMIX", "2026-08-14"), ("PKPK", "2026-08-14"),
        ("MMIX", "2026-08-12"), ("PKPK", "2026-08-12"),
    ]
