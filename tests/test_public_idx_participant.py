from __future__ import annotations

import pandas as pd

from idx_flow_scanner.providers.public_idx_participant import (
    aggregate_trade_detail,
    score_participant_history,
    trim_top_participants,
)


def _raw() -> pd.DataFrame:
    return pd.DataFrame(
        [
            {"tradingdate": "2026-08-14", "asset": "TEST", "participant_buy": "AB", "participant_sell": "CD", "volume": 100, "value": 100000},
            {"tradingdate": "2026-08-14", "asset": "TEST", "participant_buy": "AB", "participant_sell": "EF", "volume": 200, "value": 200000},
            {"tradingdate": "2026-08-14", "asset": "TEST", "participant_buy": "GH", "participant_sell": "CD", "volume": 50, "value": 50000},
        ]
    )


def test_aggregate_builds_participant_net_flow() -> None:
    out = aggregate_trade_detail(_raw(), "2026-08-14", ["TEST"])
    ab = out[(out["participant"] == "AB")].iloc[0]
    cd = out[(out["participant"] == "CD")].iloc[0]
    assert float(ab["net_value"]) == 300000.0
    assert float(cd["net_value"]) == -150000.0
    assert ab["participant_flow_source"] == "IDX_OFFICIAL_PUBLIC_TRADE_DETAIL_PARTICIPANT_FLOW"


def test_trim_keeps_top_buyer_and_seller() -> None:
    raw = trim_top_participants(aggregate_trade_detail(_raw(), "2026-08-14", ["TEST"]), top_n=1)
    assert set(raw["side"]) == {"TOP_NET_BUYER", "TOP_NET_SELLER"}
    assert set(raw["participant"]) == {"AB", "CD"}


def test_score_is_bounded_and_handles_no_data() -> None:
    history = trim_top_participants(aggregate_trade_detail(_raw(), "2026-08-14", ["TEST"]), top_n=10)
    out = score_participant_history(history, ["TEST", "EMPTY"])
    test = out.set_index("ticker").loc["TEST"]
    empty = out.set_index("ticker").loc["EMPTY"]
    assert 0 <= float(test["participant_accumulation_score"]) <= 100
    assert test["participant_accumulation_state"] in {"PARTICIPANT_ACCUMULATION", "PARTICIPANT_MIXED", "PARTICIPANT_DISTRIBUTION"}
    assert empty["participant_accumulation_state"] == "NO_DATA"
    assert float(empty["participant_flow_coverage_pct"]) == 0.0
