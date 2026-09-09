from __future__ import annotations

from pathlib import Path

import pandas as pd
import pytest

from idx_flow_scanner.operational_top900 import (
    OperationalUniverseUnavailable,
    apply_operational_membership_guards,
    load_bundled_operational_top900,
    materialize_runtime_top900,
    validate_operational_top900,
)


ROOT = Path(__file__).resolve().parents[1]
BUNDLED = ROOT / "data" / "universe" / "idx_900_all.csv"
MIGRATION = ROOT / "supabase" / "migrations" / "20260909093000_operational_top900_runtime_v1.sql"


def test_bundled_operational_top900_is_exact_and_preserves_actionability_split():
    frame = load_bundled_operational_top900(BUNDLED)

    assert len(frame) == 900
    assert frame["ticker"].nunique() == 900
    assert frame["universe_rank"].astype(int).tolist() == list(range(1, 901))
    assert frame["runtime_ranking_eligible"].all()
    assert int(frame["current_tradeable"].sum()) == 873
    assert int(frame["production_actionable"].sum()) == 834
    assert int((~frame["current_tradeable"]).sum()) == 27
    assert frame["membership_state"].eq("CURRENT_TOP900_NOT_HISTORICAL").all()


def test_partial_canonical_response_falls_back_to_exact_bundled_snapshot(tmp_path):
    class Response:
        data = [{"ticker": "BBCA"}]

    class Call:
        def execute(self):
            return Response()

    class Client:
        def rpc(self, name, payload):
            assert name == "flow_load_operational_universe_v1"
            assert payload == {}
            return Call()

    store = type("Store", (), {"client": Client()})()
    output = tmp_path / "runtime.csv"

    path = materialize_runtime_top900(store, bundled_path=BUNDLED, runtime_path=output)
    materialized = pd.read_csv(path)

    assert len(materialized) == 900
    assert materialized["ticker"].nunique() == 900


def test_top900_validation_fails_closed_on_duplicate_or_false_eligibility():
    frame = pd.read_csv(BUNDLED)
    duplicate = frame.copy()
    duplicate.loc[899, "ticker"] = duplicate.loc[0, "ticker"]
    with pytest.raises(OperationalUniverseUnavailable):
        validate_operational_top900(duplicate)

    ineligible = frame.copy()
    ineligible.loc[0, "runtime_ranking_eligible"] = False
    with pytest.raises(OperationalUniverseUnavailable):
        validate_operational_top900(ineligible)


def test_operational_top900_migration_is_service_only_and_keeps_phase2_shadow():
    sql = MIGRATION.read_text(encoding="utf-8").lower()

    assert "idx_operational_top900_v1" in sql
    assert "flow_load_operational_universe_v1" in sql
    assert "flow_load_operational_prices_v1" in sql
    assert "security invoker" in sql
    assert "set search_path=''" in sql
    assert "from public,anon,authenticated" in sql
    assert "to service_role" in sql
    assert "predictive_attribution_production_influence_enabled=false" in sql
    assert "coalesce(missing_robustness" not in sql


def test_all_valid_members_rank_but_non_actionable_member_is_execution_blocked():
    membership = pd.read_csv(BUNDLED)
    actionable = membership.loc[membership["production_actionable"]].iloc[0]
    blocked = membership.loc[~membership["production_actionable"]].iloc[0]
    results = pd.DataFrame(
        [
            {
                "ticker": blocked["ticker"],
                "final_score": 99.0,
                "production_authorized": True,
                "real_money_state": "ELIGIBLE",
                "action": "BUY_RETEST",
                "guardrail_reason": "",
                "diagnostics": {},
            },
            {
                "ticker": actionable["ticker"],
                "final_score": 80.0,
                "production_authorized": True,
                "real_money_state": "ELIGIBLE",
                "action": "BUY_RETEST",
                "guardrail_reason": "",
                "diagnostics": {},
            },
        ]
    )

    guarded = apply_operational_membership_guards(results, membership)

    assert len(guarded) == 2
    actionable_row = guarded.loc[guarded["ticker"].eq(actionable["ticker"])].iloc[0]
    blocked_row = guarded.loc[guarded["ticker"].eq(blocked["ticker"])].iloc[0]
    assert int(blocked_row["scanner_rank"]) == 1
    assert int(actionable_row["scanner_rank"]) == 2
    assert bool(actionable_row["production_authorized"])
    assert not bool(blocked_row["production_authorized"])
    assert blocked_row["action"] == "RESEARCH_ONLY"
    assert "not currently production-actionable" in blocked_row["guardrail_reason"]
    assert not blocked_row["diagnostics"][
        "predictive_attribution_production_influence_enabled"
    ]
