import pandas as pd

from idx_flow_scanner.broker_evidence import select_broker_evidence


def _rows(source, day, verified=True, brokers=("YP", "CC")):
    return pd.DataFrame([
        {
            "ticker": "MMIX",
            "trade_date": day,
            "broker_code": code,
            "buy_value": 1000 + i * 100,
            "sell_value": 700 + i * 50,
            "buy_volume": 10 + i,
            "sell_volume": 7 + i,
            "buy_avg": 100,
            "sell_avg": 101,
            "market_type": "RG" if source == "INDEX_ALPHA_BROKER_SUMMARY" else "ALL",
            "source": source,
            "source_verified": verified,
            "source_url": "https://example.invalid",
            "provenance_state": "TEST",
        }
        for i, code in enumerate(brokers)
    ])


def test_indexalpha_wins_same_ticker_day_over_goapi_without_double_count():
    frame = pd.concat([
        _rows("GOAPI_BROKER_SUMMARY_NET", "2026-08-14"),
        _rows("INDEX_ALPHA_BROKER_SUMMARY", "2026-08-14"),
    ], ignore_index=True)
    out, stats = select_broker_evidence(frame)
    assert set(out["source"]) == {"INDEX_ALPHA_BROKER_SUMMARY"}
    assert len(out) == 2
    assert stats["selected_ticker_days"] == 1
    assert stats["source_ticker_days"] == {"INDEX_ALPHA_BROKER_SUMMARY": 1}


def test_verified_unknown_source_beats_unverified_known_source_fail_closed():
    frame = pd.concat([
        _rows("INDEX_ALPHA_BROKER_SUMMARY", "2026-08-14", verified=False),
        _rows("USER_VERIFIED_IMPORT", "2026-08-14", verified=True),
    ], ignore_index=True)
    out, _ = select_broker_evidence(frame)
    assert set(out["source"]) == {"USER_VERIFIED_IMPORT"}


def test_selector_can_assemble_history_from_different_providers_without_same_day_mix():
    frame = pd.concat([
        _rows("INDEX_ALPHA_BROKER_SUMMARY", "2026-08-14"),
        _rows("GOAPI_BROKER_SUMMARY_NET", "2026-08-13"),
    ], ignore_index=True)
    out, stats = select_broker_evidence(frame)
    assert out["trade_date"].nunique() == 2
    assert len(out) == 4
    assert stats["source_ticker_days"] == {
        "INDEX_ALPHA_BROKER_SUMMARY": 1,
        "GOAPI_BROKER_SUMMARY_NET": 1,
    }


def test_official_idx_broker_summary_wins_same_day_over_indexalpha():
    frame = pd.concat([
        _rows("INDEX_ALPHA_BROKER_SUMMARY", "2026-08-14", brokers=("YP", "CC", "PD")),
        _rows("IDX_OFFICIAL_BROKER_SUMMARY", "2026-08-14", brokers=("YP", "CC")),
    ], ignore_index=True)
    out, stats = select_broker_evidence(frame)
    assert set(out["source"]) == {"IDX_OFFICIAL_BROKER_SUMMARY"}
    assert stats["source_ticker_days"] == {"IDX_OFFICIAL_BROKER_SUMMARY": 1}
