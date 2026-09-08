from __future__ import annotations

from datetime import datetime
from functools import lru_cache
from typing import Any

from idx_flow_scanner.providers.block_idx_evidence import is_official_idx_url
from idx_flow_scanner.providers.block_idx_financial_history import (
    fetch_financial_report_market,
    parse_financial_report_payload,
)


def _collapse(value: object) -> str:
    return " ".join(str(value or "").split())


def _published_second(value: object) -> str:
    parsed = datetime.fromisoformat(str(value or "").strip())
    if parsed.tzinfo is None:
        raise ValueError("published_at must be timezone-aware")
    return parsed.replace(microsecond=0).isoformat()


@lru_cache(maxsize=4096)
def _current_report_rows(ticker: str, report_year: int, report_period: str) -> tuple[dict[str, object], ...]:
    payload = fetch_financial_report_market(report_year, report_period, ticker=ticker)
    return tuple(parse_financial_report_payload(payload))


def clear_financial_locator_cache() -> None:
    _current_report_rows.cache_clear()


def resolve_exact_current_report_attachment(filing: dict[str, object]) -> dict[str, object] | None:
    """Resolve a stale announcement attachment URL without changing PIT identity.

    A replacement URL is accepted only when the current official financial-report endpoint
    corroborates the *same* ticker, report year/period, publication/file-modified second, and
    exact attachment filename. This intentionally cannot substitute a later revision for an
    earlier filing.
    """

    ticker = _collapse(filing.get("ticker")).upper()
    report_year = int(filing.get("report_year"))
    report_period = _collapse(filing.get("report_period")).upper()
    period_end = str(filing.get("report_period_end") or "").strip()
    file_name = _collapse(filing.get("file_name"))
    published_second = _published_second(filing.get("published_at"))
    original_url = str(filing.get("file_url") or "").strip()

    if not ticker or report_period not in {"TW1", "TW2", "TW3", "AUDIT"} or not file_name:
        return None

    matches: list[dict[str, object]] = []
    for report in _current_report_rows(ticker, report_year, report_period):
        if _collapse(report.get("ticker")).upper() != ticker:
            continue
        if int(report.get("report_year") or 0) != report_year:
            continue
        if _collapse(report.get("report_period")).upper() != report_period:
            continue
        if str(report.get("report_period_end") or "") != period_end:
            continue
        if str(report.get("file_modified_second") or "") != published_second:
            continue
        for attachment in report.get("attachments") or []:
            if not isinstance(attachment, dict):
                continue
            candidate_name = _collapse(attachment.get("file_name"))
            candidate_url = str(attachment.get("file_url") or "").strip()
            if candidate_name.casefold() != file_name.casefold():
                continue
            if not candidate_url or not is_official_idx_url(candidate_url):
                continue
            matches.append(
                {
                    "resolved_file_url": candidate_url,
                    "original_file_url": original_url,
                    "file_name": candidate_name,
                    "ticker": ticker,
                    "report_year": report_year,
                    "report_period": report_period,
                    "report_period_end": period_end,
                    "published_second": published_second,
                    "report_file_modified_at": report.get("file_modified_at"),
                    "resolution_state": "EXACT_CURRENT_REPORT_TIMESTAMP_FILENAME",
                    "point_in_time_identity_preserved": True,
                }
            )

    unique = {str(row["resolved_file_url"]): row for row in matches}
    if len(unique) != 1:
        return None
    return next(iter(unique.values()))


__all__ = [
    "clear_financial_locator_cache",
    "resolve_exact_current_report_attachment",
]
