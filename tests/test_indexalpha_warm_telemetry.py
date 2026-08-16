from __future__ import annotations

import pandas as pd

from idx_flow_scanner.providers.indexalpha import IndexAlphaUnavailable
from scripts.build_flow_evidence_cache import _run_indexalpha_jobs


def test_plan_limit_counts_real_request_without_marking_key_invalid():
    calls: list[tuple[str, str, str, str]] = []

    def fetcher(ticker: str, day: str, *, investor: str, market: str) -> pd.DataFrame:
        calls.append((ticker, day, investor, market))
        raise IndexAlphaUnavailable("Index Alpha plan does not allow broker summary")

    parts, status, attempted, succeeded = _run_indexalpha_jobs(
        [("MMIX", "2026-08-13"), ("PKPK", "2026-08-13")], fetcher=fetcher
    )

    assert calls == [("MMIX", "2026-08-13", "all", "RG")]
    assert attempted == 1
    assert succeeded == 0
    assert not parts
    assert status.startswith("PLAN_LIMIT:")
    assert "invalid" not in status.lower()


def test_success_counts_attempted_and_succeeded_exact_day_jobs():
    calls: list[tuple[str, str, str, str]] = []

    def fetcher(ticker: str, day: str, *, investor: str, market: str) -> pd.DataFrame:
        calls.append((ticker, day, investor, market))
        return pd.DataFrame({"ticker": [ticker], "trade_date": [pd.Timestamp(day)]})

    parts, status, attempted, succeeded = _run_indexalpha_jobs(
        [("MMIX", "2026-08-13"), ("PKPK", "2026-08-13")], fetcher=fetcher
    )

    assert calls == [
        ("MMIX", "2026-08-13", "all", "RG"),
        ("PKPK", "2026-08-13", "all", "RG"),
    ]
    assert attempted == 2
    assert succeeded == 2
    assert len(parts) == 2
    assert status == "UPDATED"


def test_generic_unavailable_remains_distinct_from_plan_limit():
    def fetcher(ticker: str, day: str, *, investor: str, market: str) -> pd.DataFrame:
        raise IndexAlphaUnavailable("Index Alpha HTTP 500")

    parts, status, attempted, succeeded = _run_indexalpha_jobs(
        [("MMIX", "2026-08-13")], fetcher=fetcher
    )

    assert attempted == 1
    assert succeeded == 0
    assert not parts
    assert status == "UNAVAILABLE: Index Alpha HTTP 500"
