from __future__ import annotations

from io import StringIO
from pathlib import Path
from types import SimpleNamespace

import pandas as pd

import idx_flow_scanner.funnel as funnel
import idx_flow_scanner.streamlit_app as streamlit_app
from idx_flow_scanner.authorization import apply_production_authorization, export_scan_csv
from idx_flow_scanner.broker_freshness import evaluate_broker_freshness
from idx_flow_scanner.engines.flow import compute_official_foreign_features
from idx_flow_scanner.foreign_evidence import prepare_foreign_evidence


def _price(dates: pd.DatetimeIndex) -> pd.DataFrame:
    return pd.DataFrame(
        {
            "date": dates,
            "open": 100.0,
            "high": 102.0,
            "low": 99.0,
            "close": 101.0,
            "volume": 10_000_000,
        }
    )


def _foreign(ticker: str, dates: pd.DatetimeIndex, source: str, net: float = 50_000.0) -> pd.DataFrame:
    buy = 100_000.0 + max(net, 0.0)
    sell = buy - net
    return pd.DataFrame(
        {
            "ticker": ticker,
            "trade_date": dates,
            "foreign_buy": buy,
            "foreign_sell": sell,
            "foreign_net": net,
            "volume": 10_000_000.0,
            "source": source,
        }
    )


def _decision(frame: pd.DataFrame) -> dict[str, object]:
    row = frame.iloc[0]
    return {
        "provider": row["foreign_provider_selected"],
        "selection": row["foreign_provider_selection_state"],
        "reconciliation": row["foreign_provider_reconciliation_state"],
        "window": row["foreign_window_state"],
        "freshness": row["foreign_data_freshness"],
        "conflict": bool(row["foreign_provider_conflict"]),
    }


def test_provider_selection_matrix_and_partial_window_states_are_explicit():
    dates = pd.bdate_range("2026-07-20", periods=20)
    price = _price(dates)
    direct = "IDX_OFFICIAL_STOCK_SUMMARY"
    zapi = "ZAPI_IDX_FOREIGN_FLOW"

    cases = [
        (_foreign("P1", dates, direct), "IDX_DIRECT", "FULL"),
        (_foreign("P2", dates, zapi), "ZAPI", "FULL"),
        (pd.concat([_foreign("P3", dates, direct), _foreign("P3", dates, zapi)]), "IDX_DIRECT", "FULL"),
        (pd.concat([_foreign("P4", dates[-14:], direct), _foreign("P4", dates, zapi)]), "ZAPI", "FULL"),
        (pd.concat([_foreign("P5", dates[:-1], direct), _foreign("P5", dates[-2:], zapi)]), "ZAPI", "INSUFFICIENT"),
        (pd.concat([_foreign("P6", dates[-14:], direct), _foreign("P6", dates[:-1], zapi)]), "IDX_DIRECT", "PARTIAL"),
    ]
    for candidates, provider, window in cases:
        ticker = str(candidates.iloc[0]["ticker"])
        selected, _ = prepare_foreign_evidence([ticker], candidates, lambda _: price)
        decision = _decision(selected)
        assert decision["provider"] == provider
        assert decision["window"] == window
        assert decision["selection"] == (provider if window == "FULL" else "PARTIAL_ONLY")


def test_runtime_loader_collects_both_providers_before_one_canonical_selection(monkeypatch):
    dates = pd.bdate_range("2026-07-20", periods=20)
    direct = _foreign("BOTH", dates, "IDX_OFFICIAL_STOCK_SUMMARY")
    zapi = _foreign("BOTH", dates, "ZAPI_IDX_FOREIGN_FLOW")
    calls: list[tuple[str, tuple[str, ...]]] = []

    def load_zapi(universe, **_kwargs):
        calls.append(("ZAPI", tuple(universe)))
        return zapi

    def load_direct(universe, **_kwargs):
        calls.append(("IDX_DIRECT", tuple(universe)))
        return direct

    monkeypatch.setattr(streamlit_app, "load_bundled_zapi_foreign_flows", load_zapi)
    monkeypatch.setattr(streamlit_app, "load_bundled_idx_official_flows", load_direct)
    selected, _, _, stats = streamlit_app._zapi_first_foreign(
        ["BOTH"], None, lambda _ticker: _price(dates)
    )
    assert calls == [("ZAPI", ("BOTH",)), ("IDX_DIRECT", ("BOTH",))]
    assert _decision(selected)["provider"] == "IDX_DIRECT"
    assert stats["policy"] == "COMPARE_VALIDITY_FRESHNESS_COMPLETENESS_AUTHORITY"


def test_invalid_conflicting_mixed_and_reordered_provider_rows_fail_closed_per_ticker():
    dates = pd.bdate_range("2026-07-20", periods=20)
    prices = {ticker: _price(dates) for ticker in ("BAD", "CONFLICT", "DIRECT", "ZAPI")}
    direct = "IDX_OFFICIAL_STOCK_SUMMARY"
    zapi = "ZAPI_IDX_FOREIGN_FLOW"

    bad_direct = _foreign("BAD", dates[:1], direct)
    bad_direct = pd.concat([bad_direct, bad_direct.assign(foreign_net=999.0)], ignore_index=True)
    bad_zapi = _foreign("BAD", dates[:1], zapi).assign(foreign_buy=-1.0)
    conflict = pd.concat(
        [_foreign("CONFLICT", dates, direct, 50_000.0), _foreign("CONFLICT", dates, zapi, -50_000.0)]
    )
    mixed = pd.concat(
        [bad_direct, bad_zapi, conflict, _foreign("DIRECT", dates, direct), _foreign("ZAPI", dates, zapi)],
        ignore_index=True,
    )

    first, _ = prepare_foreign_evidence(prices, mixed, lambda ticker: prices[ticker])
    second, _ = prepare_foreign_evidence(
        list(reversed(prices)), mixed.sample(frac=1.0, random_state=7), lambda ticker: prices[ticker]
    )
    first_decisions = {ticker: _decision(group) for ticker, group in first.groupby("ticker", sort=False)}
    second_decisions = {ticker: _decision(group) for ticker, group in second.groupby("ticker", sort=False)}
    assert first_decisions == second_decisions
    assert first_decisions["BAD"]["selection"] == "NO_VALID_PROVIDER"
    assert first_decisions["CONFLICT"]["selection"] == "IDX_DIRECT"
    assert first_decisions["CONFLICT"]["reconciliation"] == "DIRECTION_CONFLICT"
    assert first_decisions["CONFLICT"]["conflict"] is True
    assert first_decisions["DIRECT"]["provider"] == "IDX_DIRECT"
    assert first_decisions["ZAPI"]["provider"] == "ZAPI"


def test_foreign_full_partial_insufficient_missing_and_zero_are_distinct():
    dates = pd.bdate_range("2026-07-20", periods=20)
    direct = "IDX_OFFICIAL_STOCK_SUMMARY"
    candidates = pd.concat(
        [
            _foreign("FULL", dates, direct, 0.0),
            _foreign("PARTIAL", dates[-14:], direct),
            _foreign("INSUFFICIENT", dates[-2:], direct),
        ],
        ignore_index=True,
    )
    out, _ = prepare_foreign_evidence(
        ["FULL", "PARTIAL", "INSUFFICIENT", "MISSING"], candidates, lambda _: _price(dates)
    )
    states = {ticker: group.iloc[0]["foreign_window_state"] for ticker, group in out.groupby("ticker")}
    assert states == {
        "FULL": "FULL",
        "PARTIAL": "PARTIAL",
        "INSUFFICIENT": "INSUFFICIENT",
        "MISSING": "MISSING",
    }
    full = out[out["ticker"].eq("FULL")]
    assert len(full) == 20
    assert full["foreign_net"].eq(0.0).all()

    partial = out[out["ticker"].eq("PARTIAL")]
    features = compute_official_foreign_features(partial, _price(dates))
    assert features["foreign_window_state"] == "PARTIAL"
    assert features["foreign_observed_observations"] == 14
    assert features["foreign_net_20d"] > 0


def _broker(ticker: str, trade_date: object) -> pd.DataFrame:
    return pd.DataFrame(
        {
            "ticker": [ticker],
            "trade_date": [trade_date],
            "broker_code": ["AA"],
            "buy_value": [100.0],
            "sell_value": [90.0],
            "source": ["INDEX_ALPHA_BROKER_SUMMARY"],
            "provenance_state": ["VERIFIED_VENDOR_API_EXACT_DAY_ALL_RG_VOLUME_UNIT_PROVIDER_NATIVE"],
        }
    )


def test_broker_fresh_stale_unknown_missing_are_row_local():
    dates = pd.bdate_range("2026-07-20", periods=20)
    price = _price(dates)
    assert evaluate_broker_freshness(_broker("FRESH", dates[-1]), price, "FRESH", max_age_days=3)[
        "broker_freshness_state"
    ] == "FRESH"
    stale = evaluate_broker_freshness(_broker("STALE", dates[-10]), price, "STALE", max_age_days=3)
    assert stale["broker_freshness_state"] == "STALE"
    assert stale["broker_latest_age_days"] > 3
    unknown = evaluate_broker_freshness(_broker("UNKNOWN", "not-a-date"), price, "UNKNOWN", max_age_days=3)
    assert unknown["broker_freshness_state"] == "UNKNOWN"
    assert unknown["broker_data_valid"] is False
    missing = evaluate_broker_freshness(pd.DataFrame(), price, "MISSING", max_age_days=3)
    assert missing["broker_freshness_state"] == "MISSING"
    assert missing["broker_data_available"] is False


def _authorization_row(**overrides: object) -> dict[str, object]:
    row: dict[str, object] = {
        "ticker": "GOOD",
        "broker_verification_status": "BROKER_VERIFIED",
        "evidence_tier": "BROKER_DIRECT",
        "real_money_state": "ELIGIBLE",
        "diagnostics": {
            "broker_data_valid": True,
            "broker_freshness_state": "FRESH",
            "foreign_provider_selected": "IDX_DIRECT",
            "foreign_provider_selection_state": "IDX_DIRECT",
            "foreign_provider_reconciliation_state": "SINGLE_PROVIDER",
            "foreign_provider_conflict": False,
            "foreign_window_state": "FULL",
            "foreign_data_valid": True,
            "foreign_data_freshness": "FRESH",
        },
    }
    row.update(overrides)
    return row


def test_authorization_and_csv_are_canonical_boolean_and_fail_closed():
    rows = [
        _authorization_row(),
        _authorization_row(ticker="STALE", diagnostics={**_authorization_row()["diagnostics"], "broker_freshness_state": "STALE"}),
        _authorization_row(ticker="CONFLICT", diagnostics={**_authorization_row()["diagnostics"], "foreign_provider_conflict": True, "foreign_provider_reconciliation_state": "DIRECTION_CONFLICT"}),
        _authorization_row(ticker="UNRESOLVED", diagnostics={**_authorization_row()["diagnostics"], "foreign_provider_conflict": False, "foreign_provider_reconciliation_state": "UNRESOLVED"}),
        _authorization_row(ticker="PARTIAL", diagnostics={**_authorization_row()["diagnostics"], "foreign_window_state": "PARTIAL", "foreign_provider_selection_state": "PARTIAL_ONLY"}),
        _authorization_row(ticker="LEGACY", diagnostics={key: value for key, value in _authorization_row()["diagnostics"].items() if key != "foreign_provider_reconciliation_state"}),
        {"ticker": "MISSING", "production_authorized": True},
        {"ticker": "NAN", "production_authorized": float("nan")},
    ]
    authorized = apply_production_authorization(pd.DataFrame(rows))
    by_ticker = authorized.set_index("ticker")["production_authorized"].to_dict()
    assert by_ticker == {
        "GOOD": True,
        "STALE": False,
        "CONFLICT": False,
        "UNRESOLVED": False,
        "PARTIAL": False,
        "LEGACY": False,
        "MISSING": False,
        "NAN": False,
    }
    exported = pd.read_csv(StringIO(export_scan_csv(authorized).decode("utf-8")))
    assert "production_authorized" in exported.columns
    assert exported["production_authorized"].tolist() == [True, False, False, False, False, False, False, False]

    raw_export = pd.read_csv(StringIO(export_scan_csv(pd.DataFrame([_authorization_row()])).decode("utf-8")))
    assert raw_export["production_authorized"].tolist() == [False]

    repeated = apply_production_authorization(authorized)
    assert repeated["production_authorized"].tolist() == authorized["production_authorized"].tolist()


def test_authorization_normalizes_nullable_reconciliation_scalars_row_locally():
    cases = {
        "AGREED": ("AGREED", True),
        "SINGLE": ("SINGLE_PROVIDER", True),
        "UNRESOLVED": ("UNRESOLVED", False),
        "PANDAS_NA": (pd.NA, False),
        "NONE": (None, False),
        "NAN": (float("nan"), False),
        "MISSING": (None, False),
        "UNKNOWN": ("UNKNOWN", False),
        "DIRECTION": ("DIRECTION_CONFLICT", False),
        "NOT_COMPARABLE": ("NOT_COMPARABLE", False),
    }
    rows = []
    for ticker, (reconciliation, _expected) in cases.items():
        diagnostics = {**_authorization_row()["diagnostics"]}
        if ticker == "MISSING":
            diagnostics.pop("foreign_provider_reconciliation_state")
        else:
            diagnostics["foreign_provider_reconciliation_state"] = reconciliation
        diagnostics["foreign_provider_conflict"] = (
            isinstance(reconciliation, str) and reconciliation == "DIRECTION_CONFLICT"
        )
        rows.append(_authorization_row(ticker=ticker, diagnostics=diagnostics))

    authorized = apply_production_authorization(pd.DataFrame(rows)).set_index("ticker")

    assert authorized["production_authorized"].to_dict() == {
        ticker: expected for ticker, (_reconciliation, expected) in cases.items()
    }


def test_broker_verification_requires_freshness_and_authorizes_only_fresh_row(monkeypatch):
    base = pd.DataFrame(
        [
            {
                "ticker": ticker,
                "guarded_rank": rank,
                "guarded_score": 80.0,
                "final_score": 80.0,
                "market_context_score": 50.0,
                "as_of_date": "2026-08-14",
                "diagnostics": {},
            }
            for rank, ticker in enumerate(("FRESH", "STALE"), 1)
        ]
    )

    def fake_scan_one(ticker, *_args, **_kwargs):
        fresh = ticker == "FRESH"
        return SimpleNamespace(
            to_dict=lambda: {
                **_authorization_row(ticker=ticker),
                "final_score": 80.0,
                "accumulation_score": 70.0,
                "distribution_risk": 20.0,
                "phase": "ACCUMULATION",
                "action": "BUY_ON_WEAKNESS",
                "diagnostics": {
                    **_authorization_row()["diagnostics"],
                    "broker_freshness_state": "FRESH" if fresh else "STALE",
                },
            }
        )

    monkeypatch.setattr(funnel, "scan_one", fake_scan_one)
    out, errors = funnel.verify_guarded_top5(
        base,
        lambda _ticker: pd.DataFrame({"date": ["2026-08-14"]}),
        pd.DataFrame({"ticker": ["FRESH", "STALE"]}),
    )
    assert not errors
    rows = out.set_index("ticker")
    assert rows.loc["FRESH", "broker_verification_status"] == "BROKER_VERIFIED"
    assert bool(rows.loc["FRESH", "production_authorized"]) is True
    assert rows.loc["STALE", "broker_verification_status"] == "BROKER_PENDING"
    assert rows.loc["STALE", "real_money_state"] == "GUARDED"
    assert bool(rows.loc["STALE", "production_authorized"]) is False


def test_broker_verification_reuses_canonical_reconciliation_contract(monkeypatch):
    cases = {
        "AGREED": ("AGREED", True, "FRESH", "BROKER_VERIFIED", "ELIGIBLE", True),
        "SINGLE": ("SINGLE_PROVIDER", True, "FRESH", "BROKER_VERIFIED", "ELIGIBLE", True),
        "UNRESOLVED": ("UNRESOLVED", True, "FRESH", "BROKER_GUARDED", "GUARDED", False),
        "DIRECTION": ("DIRECTION_CONFLICT", True, "FRESH", "BROKER_GUARDED", "GUARDED", False),
        "NOT_COMPARABLE": ("NOT_COMPARABLE", True, "FRESH", "BROKER_GUARDED", "GUARDED", False),
        "UNKNOWN": ("UNKNOWN", True, "FRESH", "BROKER_GUARDED", "GUARDED", False),
        "MISSING": (None, True, "FRESH", "BROKER_GUARDED", "GUARDED", False),
        "NAN": (float("nan"), True, "FRESH", "BROKER_GUARDED", "GUARDED", False),
        "PANDAS_NA": (pd.NA, True, "FRESH", "BROKER_GUARDED", "GUARDED", False),
        "STALE": ("AGREED", True, "STALE", "BROKER_PENDING", "GUARDED", False),
        "NO_BROKER": ("AGREED", False, "MISSING", "BROKER_PENDING", "GUARDED", False),
    }
    guarded = pd.DataFrame(
        [
            {
                "ticker": ticker,
                "guarded_rank": rank,
                "guarded_score": 80.0,
                "final_score": 80.0,
                "market_context_score": 50.0,
                "as_of_date": "2026-08-14",
                "diagnostics": {},
            }
            for rank, ticker in enumerate(cases, 1)
        ]
    )

    def fake_scan_one(ticker, *_args, **_kwargs):
        reconciliation, broker_valid, broker_freshness, *_expected = cases[ticker]
        diagnostics = {
            **_authorization_row()["diagnostics"],
            "broker_data_valid": broker_valid,
            "broker_freshness_state": broker_freshness,
        }
        if reconciliation is None:
            diagnostics.pop("foreign_provider_reconciliation_state", None)
        else:
            diagnostics["foreign_provider_reconciliation_state"] = reconciliation
        diagnostics["foreign_provider_conflict"] = (
            isinstance(reconciliation, str) and reconciliation == "DIRECTION_CONFLICT"
        )
        return SimpleNamespace(
            to_dict=lambda: {
                **_authorization_row(ticker=ticker),
                "final_score": 80.0,
                "accumulation_score": 70.0,
                "distribution_risk": 20.0,
                "phase": "ACCUMULATION",
                "action": "BUY_ON_WEAKNESS",
                "diagnostics": diagnostics,
            }
        )

    monkeypatch.setattr(funnel, "scan_one", fake_scan_one)
    out, errors = funnel.verify_guarded_top5(
        guarded,
        lambda _ticker: pd.DataFrame({"date": ["2026-08-14"]}),
        pd.DataFrame({"ticker": list(cases)}),
    )
    assert not errors
    rows = out.set_index("ticker")
    for ticker, (*_inputs, expected_status, expected_state, expected_authorized) in cases.items():
        assert rows.loc[ticker, "broker_verification_status"] == expected_status
        assert rows.loc[ticker, "real_money_state"] == expected_state
        assert bool(rows.loc[ticker, "production_authorized"]) is expected_authorized


def test_indexalpha_loader_never_calls_more_than_final_top_five(monkeypatch):
    calls: list[str] = []
    dates = pd.bdate_range("2026-07-20", periods=20)
    monkeypatch.setattr(streamlit_app, "_secret", lambda _name: "test-key")
    monkeypatch.setattr(streamlit_app, "load_bundled_indexalpha_broker_flows", lambda *_args, **_kwargs: pd.DataFrame())
    monkeypatch.setattr(streamlit_app, "merge_indexalpha_broker_frames", lambda *_args: pd.DataFrame())
    monkeypatch.setattr(streamlit_app, "select_broker_evidence", lambda frame: (frame, {}))

    def fake_fetch(ticker, *_args, **_kwargs):
        calls.append(ticker)
        return pd.DataFrame()

    monkeypatch.setattr(streamlit_app, "fetch_indexalpha_broker_summary", fake_fetch)
    finalists = [f"T{i}" for i in range(8)]
    _, stats = streamlit_app._load_indexalpha_for_finalists(
        finalists, lambda _ticker: _price(dates), None, allow_live_pull=True
    )
    assert calls == finalists[:5]
    assert stats["requests_attempted"] == 5


def test_provider_reconciliation_has_no_percentage_boundary_and_is_symmetric():
    dates = pd.bdate_range("2026-07-20", periods=20)
    direct = "IDX_OFFICIAL_STOCK_SUMMARY"
    zapi = "ZAPI_IDX_FOREIGN_FLOW"
    expected = {
        (100.0, 100.0): "AGREED",
        (100.0, 109.0): "UNRESOLVED",
        (100.0, 111.0): "UNRESOLVED",
        (1.0, 2.0): "UNRESOLVED",
        (0.0, 1.0): "UNRESOLVED",
        (0.0, 0.0): "AGREED",
        (-100.0, -109.0): "UNRESOLVED",
        (-100.0, 100.0): "DIRECTION_CONFLICT",
        (100.0, -100.0): "DIRECTION_CONFLICT",
    }

    for (idx_value, zapi_value), expected_state in expected.items():
        candidates = pd.concat(
            [
                _foreign("PAIR", dates, direct, idx_value),
                _foreign("PAIR", dates, zapi, zapi_value),
            ],
            ignore_index=True,
        )
        selected, _ = prepare_foreign_evidence(["PAIR"], candidates, lambda _: _price(dates))
        swapped, _ = prepare_foreign_evidence(
            ["PAIR"],
            pd.concat(
                [
                    _foreign("PAIR", dates, direct, zapi_value),
                    _foreign("PAIR", dates, zapi, idx_value),
                ],
                ignore_index=True,
            ),
            lambda _: _price(dates),
        )
        assert _decision(selected)["reconciliation"] == expected_state
        assert _decision(swapped)["reconciliation"] == expected_state

    source = Path(prepare_foreign_evidence.__code__.co_filename).read_text()
    assert "_MATERIAL_CONFLICT_RATIO" not in source
    assert "difference / scale" not in source


def test_incomparable_semantics_and_windows_preserve_both_providers_and_fail_closed():
    dates = pd.bdate_range("2026-07-20", periods=20)
    direct = "IDX_OFFICIAL_STOCK_SUMMARY"
    zapi = "ZAPI_IDX_FOREIGN_FLOW"

    different_window = pd.concat(
        [
            _foreign("WINDOW", dates, direct, 100.0),
            _foreign("WINDOW", dates[1:], zapi, 100.0),
        ],
        ignore_index=True,
    )
    window_selected, _ = prepare_foreign_evidence(
        ["WINDOW"], different_window, lambda _: _price(dates)
    )
    window_row = window_selected.iloc[0]
    assert window_row["foreign_provider_selected"] == "IDX_DIRECT"
    assert window_row["foreign_provider_selection_state"] == "IDX_DIRECT"
    assert window_row["foreign_provider_reconciliation_state"] == "NOT_COMPARABLE"
    assert window_row["foreign_provider_alternate"] == "ZAPI"
    assert window_row["foreign_provider_alternate_source"] == zapi
    evidence = window_row["foreign_provider_evidence"]
    assert evidence["IDX_DIRECT"]["net_total"] == 2_000.0
    assert evidence["ZAPI"]["net_total"] == 1_900.0

    different_unit = pd.concat(
        [
            _foreign("UNIT", dates, direct, 100.0).assign(flow_unit="SHARES"),
            _foreign("UNIT", dates, zapi, 100.0).assign(flow_unit="IDR"),
        ],
        ignore_index=True,
    )
    unit_selected, _ = prepare_foreign_evidence(["UNIT"], different_unit, lambda _: _price(dates))
    assert _decision(unit_selected)["reconciliation"] == "NOT_COMPARABLE"

    different_definition = pd.concat(
        [
            _foreign("DEFINITION", dates, direct, 100.0).assign(
                foreign_measure_definition="NET_FOREIGN_SHARES"
            ),
            _foreign("DEFINITION", dates, zapi, 100.0).assign(
                foreign_measure_definition="GROSS_FOREIGN_SHARES"
            ),
        ],
        ignore_index=True,
    )
    definition_selected, _ = prepare_foreign_evidence(
        ["DEFINITION"], different_definition, lambda _: _price(dates)
    )
    assert _decision(definition_selected)["reconciliation"] == "NOT_COMPARABLE"

    attacked = _authorization_row(
        ticker="WINDOW",
        diagnostics={
            **_authorization_row()["diagnostics"],
            "foreign_provider_reconciliation_state": "NOT_COMPARABLE",
            "foreign_provider_conflict": False,
        },
    )
    assert bool(apply_production_authorization(pd.DataFrame([attacked])).iloc[0]["production_authorized"]) is False
