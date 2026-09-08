from __future__ import annotations

from datetime import datetime
from functools import lru_cache
from pathlib import PurePosixPath
from urllib.parse import quote, urlparse

from idx_flow_scanner.providers.block_idx_evidence import is_official_idx_url
from idx_flow_scanner.providers.block_idx_financial_history import fetch_profile_announcements_market


def _collapse(value: object) -> str:
    return " ".join(str(value or "").split())


def _published_second(value: object) -> str:
    parsed = datetime.fromisoformat(str(value or "").strip())
    if parsed.tzinfo is None:
        raise ValueError("published_at must be timezone-aware")
    return parsed.replace(tzinfo=None, microsecond=0).isoformat()


def _official_file_url(value: object) -> str | None:
    raw = str(value or "").strip()
    if not raw:
        return None
    if raw.lower().startswith("https://"):
        return raw if is_official_idx_url(raw) else None
    normalized = "/" + "/".join(
        part for part in raw.replace("\\", "/").split("/") if part
    )
    encoded = quote(normalized, safe="/:._-~()[]")
    url = "https://www.idx.co.id" + encoded
    return url if is_official_idx_url(url) else None


@lru_cache(maxsize=8192)
def _announcement_replies(ticker: str, published_date: str) -> tuple[dict[str, object], ...]:
    day = datetime.fromisoformat(published_date).date()
    return tuple(fetch_profile_announcements_market(day, day, ticker=ticker, timeout=60.0))


def clear_financial_profile_locator_cache() -> None:
    _announcement_replies.cache_clear()


def resolve_exact_profile_announcement_attachment(
    filing: dict[str, object],
) -> dict[str, object] | None:
    """Re-resolve a historical attachment from its original official announcement.

    Identity is preserved by ticker + exact publication second + exact attachment
    filename, and by announcement_id when that identity is present in the historical
    cache. The locator never substitutes another publication/revision.
    """

    ticker = _collapse(filing.get("ticker")).upper()
    published = datetime.fromisoformat(str(filing.get("published_at") or "").strip())
    if published.tzinfo is None:
        raise ValueError("published_at must be timezone-aware")
    published_second = _published_second(filing.get("published_at"))
    published_date = published.date().isoformat()
    expected_announcement_id = _collapse(filing.get("announcement_id"))
    file_name = _collapse(filing.get("file_name"))
    original_url = str(filing.get("file_url") or "").strip()
    if not ticker or not file_name:
        return None

    matches: list[dict[str, object]] = []
    for reply in _announcement_replies(ticker, published_date):
        announcement = reply.get("pengumuman") if isinstance(reply, dict) else None
        if not isinstance(announcement, dict):
            continue
        if _collapse(announcement.get("Kode_Emiten")).upper() != ticker:
            continue
        try:
            candidate_second = datetime.fromisoformat(
                str(announcement.get("TglPengumuman") or "").strip()
            ).replace(microsecond=0).isoformat()
        except Exception:
            continue
        if candidate_second != published_second:
            continue
        announcement_id = _collapse(announcement.get("Id2"))
        if expected_announcement_id and announcement_id != expected_announcement_id:
            continue

        for attachment in reply.get("attachments") or []:
            if not isinstance(attachment, dict):
                continue
            candidate_name = _collapse(
                attachment.get("OriginalFilename") or attachment.get("PDFFilename")
            )
            if candidate_name.casefold() != file_name.casefold():
                continue
            candidate_url = _official_file_url(attachment.get("FullSavePath"))
            if candidate_url is None:
                continue
            matches.append(
                {
                    "resolved_file_url": candidate_url,
                    "original_file_url": original_url,
                    "file_name": candidate_name,
                    "ticker": ticker,
                    "published_second": published_second,
                    "announcement_id": announcement_id or None,
                    "announcement_jmsx_group_id": _collapse(announcement.get("JMSXGroupID")) or None,
                    "resolution_state": "EXACT_PROFILE_ANNOUNCEMENT_TIMESTAMP_FILENAME",
                    "point_in_time_identity_preserved": True,
                }
            )

    unique = {str(row["resolved_file_url"]): row for row in matches}
    if len(unique) != 1:
        return None
    return next(iter(unique.values()))


__all__ = [
    "clear_financial_profile_locator_cache",
    "resolve_exact_profile_announcement_attachment",
]
