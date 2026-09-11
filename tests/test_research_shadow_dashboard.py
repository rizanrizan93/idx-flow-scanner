from __future__ import annotations

from pathlib import Path

import pandas as pd

from idx_flow_scanner.research_shadow import (
    load_latest_financial_shadow_scores,
    load_latest_shadow_predictive_scores,
    load_shadow_strategy_lifecycle,
)


ROOT = Path(__file__).resolve().parents[1]


class _Response:
    def __init__(self, data):
        self.data = data


class _Query:
    def __init__(self, rows):
        self.rows = [dict(row) for row in rows]
        self.selected = None
        self.filters: list[tuple[str, object]] = []
        self.ordering: tuple[str, bool] | None = None
        self.row_limit: int | None = None

    def select(self, columns):
        self.selected = [part.strip() for part in str(columns).split(",") if part.strip()]
        return self

    def eq(self, column, value):
        self.filters.append((str(column), value))
        return self

    def order(self, column, desc=False):
        self.ordering = (str(column), bool(desc))
        return self

    def limit(self, value):
        self.row_limit = int(value)
        return self

    def execute(self):
        rows = self.rows
        for column, value in self.filters:
            rows = [row for row in rows if row.get(column) == value]
        if self.ordering is not None:
            column, desc = self.ordering
            rows = sorted(
                rows,
                key=lambda row: (row.get(column) is None, row.get(column)),
                reverse=desc,
            )
        if self.row_limit is not None:
            rows = rows[: self.row_limit]
        if self.selected is not None:
            rows = [
                {column: row.get(column) for column in self.selected}
                for row in rows
            ]
        return _Response(rows)


class _Client:
    def __init__(self, tables):
        self.tables = tables

    def table(self, name):
        return _Query(self.tables.get(name, []))


class _Store:
    def __init__(self, tables):
        self.client = _Client(tables)


def test_shadow_score_loaders_only_return_research_rows() -> None:
    store = _Store(
        {
            "flow_shadow_predictive_score_v1": [
                {
                    "model_contract": "SHADOW_PREDICTIVE_SCORE_V1",
                    "signal_date": "2026-09-09",
                    "ticker": "AAAA",
                    "shadow_rank": 2,
                    "shadow_predictive_score": "88.5",
                    "production_influence_enabled": False,
                },
                {
                    "model_contract": "SHADOW_PREDICTIVE_SCORE_V1",
                    "signal_date": "2026-09-09",
                    "ticker": "BBBB",
                    "shadow_rank": 1,
                    "shadow_predictive_score": "92.0",
                    "production_influence_enabled": False,
                },
                {
                    "model_contract": "SHADOW_PREDICTIVE_SCORE_V1",
                    "signal_date": "2026-09-09",
                    "ticker": "PROD",
                    "shadow_rank": 0,
                    "shadow_predictive_score": "99.0",
                    "production_influence_enabled": True,
                },
            ],
            "flow_financial_shadow_scan_comparison_v5": [
                {
                    "as_of_date": "2026-09-07",
                    "ticker": "CCCC",
                    "financial_shadow_rank": 1,
                    "financial_shadow_score": "81.0",
                    "production_influence_enabled": False,
                },
                {
                    "as_of_date": "2026-09-07",
                    "ticker": "LIVE",
                    "financial_shadow_rank": 2,
                    "financial_shadow_score": "80.0",
                    "production_influence_enabled": True,
                },
            ],
        }
    )

    predictive = load_latest_shadow_predictive_scores(store)
    financial = load_latest_financial_shadow_scores(store)

    assert predictive["ticker"].tolist() == ["BBBB", "AAAA"]
    assert predictive["research_status"].eq("RESEARCH ONLY").all()
    assert not predictive["production_influence_enabled"].any()
    assert pd.api.types.is_numeric_dtype(predictive["shadow_predictive_score"])

    assert financial["ticker"].tolist() == ["CCCC"]
    assert financial["research_status"].eq("RESEARCH ONLY").all()
    assert not financial["production_influence_enabled"].any()


def test_lifecycle_merges_latest_gate15_assessment_and_excludes_production() -> None:
    store = _Store(
        {
            "flow_strategy_lifecycle_state_v3": [
                {
                    "candidate_id": "FIN_BALANCE",
                    "candidate_type": "DRIVER",
                    "promotion_state": "EVIDENCE_ACCUMULATING",
                    "weight": "0",
                    "maximum_weight": "0.10",
                    "production_influence_enabled": False,
                    "integrity_state": "PASS",
                },
                {
                    "candidate_id": "PRODUCTION_MODEL",
                    "candidate_type": "DRIVER",
                    "promotion_state": "LIMITED_PRODUCTION",
                    "weight": "0.05",
                    "maximum_weight": "0.10",
                    "production_influence_enabled": True,
                    "integrity_state": "PASS",
                },
            ],
            "flow_gate15_promotion_assessment_v2": [
                {
                    "candidate_id": "FIN_BALANCE",
                    "candidate_type": "DRIVER",
                    "assessment_state": "INSUFFICIENT_EVIDENCE",
                    "independent_matured_signal_dates": 0,
                    "minimum_matured_sample_across_horizons": 0,
                    "robustness_state": "INSUFFICIENT_EVIDENCE",
                    "assessed_at": "2026-09-10T12:25:00+00:00",
                    "production_influence_enabled": False,
                }
            ],
        }
    )

    lifecycle = load_shadow_strategy_lifecycle(store)

    assert lifecycle["candidate_id"].tolist() == ["FIN_BALANCE"]
    assert lifecycle.iloc[0]["assessment_state"] == "INSUFFICIENT_EVIDENCE"
    assert lifecycle.iloc[0]["research_status"] == "RESEARCH ONLY"
    assert float(lifecycle.iloc[0]["weight"]) == 0.0


def test_research_page_is_explicitly_non_execution_and_has_three_tabs() -> None:
    source = (ROOT / "pages" / "5_Research_Shadow.py").read_text(encoding="utf-8")

    assert "RESEARCH ONLY" in source
    assert "bukan execution recommendation" in source
    assert "Production ranking remains isolated" in source
    assert "Shadow Ranking" in source
    assert "Financial Shadow" in source
    assert "Strategy Lifecycle / Gate-15" in source
    assert "production_influence_enabled" in source


def test_research_loader_is_read_only() -> None:
    source = (ROOT / "src" / "idx_flow_scanner" / "research_shadow.py").read_text(
        encoding="utf-8"
    )

    assert "flow_shadow_predictive_score_v1" in source
    assert "flow_financial_shadow_scan_comparison_v5" in source
    assert "flow_strategy_lifecycle_state_v3" in source
    assert "flow_gate15_promotion_assessment_v2" in source
    assert source.count('.eq("production_influence_enabled", False)') >= 4
    assert ".insert(" not in source
    assert ".upsert(" not in source
    assert ".update(" not in source
    assert ".delete(" not in source


def test_research_dashboard_release_version() -> None:
    assert (ROOT / "VERSION").read_text(encoding="utf-8").strip() == "0.5.2"
