from __future__ import annotations

import hashlib
import math
import time
from datetime import date, datetime
from pathlib import PurePosixPath
from typing import Any, Iterable
from urllib.parse import quote, urlparse
from zoneinfo import ZoneInfo

from curl_cffi import requests as curl_requests

from idx_flow_scanner.providers.block_idx_evidence import (
    download_official_idx_attachment,
    is_official_idx_url,
)

IDX_WIB = ZoneInfo("Asia/Jakarta")
BLOCK_IDX_METADATA_HOSTS = (
    "https://block.idx.id",
    "https://www.idx.id",
    "https://idx.id",
)
FINANCIAL_REPORT_PATH = "/primary/ListedCompany/GetFinancialReport"
PROFILE_ANNOUNCEMENT_PATH = "/primary/ListedCompany/GetProfileAnnouncement"
STRUCTURED_SUFFIXES = {".xlsx", ".xls", ".zip", ".xml", ".xhtml"}
PERIOD_END_MONTH_DAY = {
    "TW1": (3, 31),
    "TW2": (6, 30),
    "TW3": (9, 30),
    "AUDIT": (12, 31),
}


def _sha256_text(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def _collapse(value: object) -> str:
    return " ".join(str(value or "").split())


def _parse_wib_timestamp(value: object) -> datetime:
    raw = str(value or "").strip()
    if not raw:
        raise ValueError("missing IDX timestamp")
    parsed = datetime.fromisoformat(raw)
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=IDX_WIB)
    return parsed.astimezone(IDX_WIB)


def _normalize_name(value: object) -> str:
    return _collapse(value).casefold()


def _is_financial_title(value: object) -> bool:
    text = _collapse(value).upper()
    return "LAPORAN KEUANGAN" in text or "FINANCIAL STATEMENT" in text


def _period_key(value: object) -> str | None:
    raw = _collapse(value).upper()
    return "AUDIT" if raw == "AUDIT" else raw if raw in {"TW1", "TW2", "TW3"} else None


def _period_end(year: int, period: str) -> date:
    month, day = PERIOD_END_MONTH_DAY[period]
    return date(int(year), month, day)


def _official_file_url(value: object) -> str | None:
    raw = str(value or "").strip()
    if not raw:
        return None
    if raw.lower().startswith("https://"):
        return raw if is_official_idx_url(raw) else None
    normalized = raw.replace("\\", "/")
    if not normalized.startswith("/"):
        normalized = "/" + normalized
    encoded = quote(normalized, safe="/:._-~()[]")
    url = "https://www.idx.co.id" + encoded
    return url if is_official_idx_url(url) else None


def _request_json(
    path: str,
    *,
    params: dict[str, object],
    timeout: float = 60.0,
    retries: int = 2,
) -> dict[str, Any]:
    if path not in {FINANCIAL_REPORT_PATH, PROFILE_ANNOUNCEMENT_PATH}:
        raise ValueError("unsupported Block IDX metadata path")
    headers = {
        "Accept": "application/json,text/plain,*/*",
        "Accept-Language": "id-ID,id;q=0.9,en;q=0.8",
        "Referer": "https://block.idx.id/id/perusahaan-tercatat/profil-perusahaan-tercatat/AADI",
        "User-Agent": "Mozilla/5.0",
    }
    last_error: Exception | None = None
    last_status = 0
    for host in BLOCK_IDX_METADATA_HOSTS:
        session = curl_requests.Session(impersonate="chrome")
        for attempt in range(max(1, int(retries))):
            try:
                response = session.get(host + path, params=params, headers=headers, timeout=timeout)
                last_status = int(response.status_code)
                if response.status_code == 200:
                    payload = response.json()
                    if isinstance(payload, dict):
                        return payload
                    raise RuntimeError("Block IDX JSON payload is not an object")
                if response.status_code in {403, 429, 500, 502, 503, 504}:
                    time.sleep(min(6.0, 1.0 * (2**attempt)))
                    continue
                response.raise_for_status()
            except Exception as exc:  # pragma: no cover - network path
                last_error = exc
                time.sleep(min(6.0, 1.0 * (2**attempt)))
    if last_error is not None:
        raise RuntimeError(
            f"Block IDX metadata request failed for {path}: HTTP {last_status} / {type(last_error).__name__}"
        ) from last_error
    raise RuntimeError(f"Block IDX metadata request failed for {path}: HTTP {last_status}")


def fetch_financial_report_market(
    year: int,
    period: str,
    *,
    ticker: str | None = None,
    timeout: float = 60.0,
) -> dict[str, Any]:
    period_key = _period_key(period)
    if period_key is None:
        raise ValueError("period must be TW1, TW2, TW3, or AUDIT")
    return _request_json(
        FINANCIAL_REPORT_PATH,
        params={
            "periode": "audit" if period_key == "AUDIT" else period_key,
            "year": int(year),
            "indexFrom": 0,
            "pageSize": 1000,
            "reportType": "rdf",
            "kodeEmiten": _collapse(ticker).upper() if ticker else "",
        },
        timeout=timeout,
    )


def parse_financial_report_payload(payload: dict[str, Any]) -> list[dict[str, object]]:
    rows: list[dict[str, object]] = []
    results = payload.get("Results") if isinstance(payload, dict) else None
    if not isinstance(results, list):
        return rows
    seen: set[tuple[str, int, str, str]] = set()
    for result in results:
        if not isinstance(result, dict):
            continue
        ticker = _collapse(result.get("KodeEmiten")).upper()
        period = _period_key(result.get("Report_Period"))
        try:
            year = int(str(result.get("Report_Year") or ""))
            modified = _parse_wib_timestamp(result.get("File_Modified"))
        except Exception:
            continue
        if not ticker or period is None:
            continue
        attachments: list[dict[str, object]] = []
        for item in result.get("Attachments") or []:
            if not isinstance(item, dict):
                continue
            file_name = _collapse(item.get("File_Name"))
            suffix = str(item.get("File_Type") or PurePosixPath(file_name).suffix).lower()
            file_url = _official_file_url(item.get("File_Path"))
            if not file_name or file_url is None:
                continue
            attachments.append(
                {
                    "file_id": _collapse(item.get("File_ID")) or None,
                    "file_name": file_name,
                    "file_url": file_url,
                    "file_type": suffix,
                    "file_size": item.get("File_Size"),
                    "structured": suffix in STRUCTURED_SUFFIXES,
                }
            )
        if not attachments:
            continue
        key = (ticker, year, period, modified.replace(microsecond=0).isoformat())
        if key in seen:
            continue
        seen.add(key)
        rows.append(
            {
                "ticker": ticker,
                "report_year": year,
                "report_period": period,
                "report_period_end": _period_end(year, period).isoformat(),
                "file_modified_at": modified.isoformat(),
                "file_modified_second": modified.replace(microsecond=0).isoformat(),
                "issuer_name": _collapse(result.get("NamaEmiten")) or None,
                "attachments": attachments,
            }
        )
    return rows


def fetch_profile_announcements_market(
    date_from: date,
    date_to: date,
    *,
    ticker: str | None = None,
    page_size: int = 1000,
    timeout: float = 60.0,
) -> list[dict[str, Any]]:
    if date_to < date_from:
        raise ValueError("date_to must be >= date_from")
    page_size = min(1000, max(10, int(page_size)))
    replies: list[dict[str, Any]] = []
    page = 0
    while True:
        payload = _request_json(
            PROFILE_ANNOUNCEMENT_PATH,
            params={
                "KodeEmiten": _collapse(ticker).upper() if ticker else "",
                "indexFrom": page,
                "pageSize": page_size,
                "dateFrom": date_from.strftime("%Y%m%d"),
                "dateTo": date_to.strftime("%Y%m%d"),
                "lang": "id",
                "keyword": "",
            },
            timeout=timeout,
        )
        batch = payload.get("Replies") if isinstance(payload, dict) else None
        batch = batch if isinstance(batch, list) else []
        replies.extend(item for item in batch if isinstance(item, dict))
        try:
            total = int(payload.get("ResultCount") or 0)
        except Exception:
            total = len(replies)
        total_pages = max(1, math.ceil(total / page_size)) if total else 1
        page += 1
        if page >= total_pages or not batch:
            break
    return replies


def parse_profile_announcement_replies(replies: Iterable[dict[str, Any]]) -> list[dict[str, object]]:
    rows: list[dict[str, object]] = []
    seen: set[str] = set()
    for reply in replies:
        announcement = reply.get("pengumuman") if isinstance(reply, dict) else None
        if not isinstance(announcement, dict):
            continue
        title = _collapse(announcement.get("JudulPengumuman"))
        if not _is_financial_title(title):
            continue
        ticker = _collapse(announcement.get("Kode_Emiten")).upper()
        try:
            published = _parse_wib_timestamp(announcement.get("TglPengumuman"))
        except Exception:
            continue
        announcement_id = _collapse(announcement.get("Id2"))
        if not ticker or not announcement_id or announcement_id in seen:
            continue
        seen.add(announcement_id)
        attachment_names: list[str] = []
        attachment_urls: list[str] = []
        for item in reply.get("attachments") or []:
            if not isinstance(item, dict):
                continue
            name = _collapse(item.get("OriginalFilename") or item.get("PDFFilename"))
            if name:
                attachment_names.append(name)
            url = _official_file_url(item.get("FullSavePath"))
            if url is not None:
                attachment_urls.append(url)
        rows.append(
            {
                "announcement_id": announcement_id,
                "ticker": ticker,
                "published_at": published.isoformat(),
                "published_second": published.replace(microsecond=0).isoformat(),
                "announcement_no": _collapse(announcement.get("NoPengumuman")) or None,
                "title": title,
                "jmsx_group_id": _collapse(announcement.get("JMSXGroupID")) or None,
                "attachment_names": attachment_names,
                "attachment_urls": attachment_urls,
            }
        )
    return rows


def match_point_in_time_financial_filings(
    reports: Iterable[dict[str, object]],
    announcements: Iterable[dict[str, object]],
    *,
    now: datetime | None = None,
) -> tuple[list[dict[str, object]], dict[str, int]]:
    current = now.astimezone(IDX_WIB) if now is not None else datetime.now(IDX_WIB)
    announcement_index: dict[tuple[str, str], list[dict[str, object]]] = {}
    announcement_count = 0
    for announcement in announcements:
        ticker = _collapse(announcement.get("ticker")).upper()
        published_second = str(announcement.get("published_second") or "")
        if not ticker or not published_second:
            continue
        announcement_index.setdefault((ticker, published_second), []).append(announcement)
        announcement_count += 1

    filings: list[dict[str, object]] = []
    report_groups = 0
    matched_groups = 0
    unmatched_groups = 0
    skipped_non_pit = 0
    skipped_attachment_identity = 0
    seen_urls: set[tuple[str, int, str, str]] = set()

    for report in reports:
        report_groups += 1
        ticker = _collapse(report.get("ticker")).upper()
        period = _period_key(report.get("report_period"))
        try:
            year = int(report.get("report_year"))
            modified = _parse_wib_timestamp(report.get("file_modified_at"))
        except Exception:
            unmatched_groups += 1
            continue
        if not ticker or period is None:
            unmatched_groups += 1
            continue
        key = (ticker, modified.replace(microsecond=0).isoformat())
        candidates = announcement_index.get(key, [])
        report_names = {
            _normalize_name(item.get("file_name"))
            for item in (report.get("attachments") or [])
            if isinstance(item, dict) and item.get("file_name")
        }
        matched: dict[str, object] | None = None
        matched_names: set[str] = set()
        for candidate in candidates:
            candidate_names = {_normalize_name(name) for name in (candidate.get("attachment_names") or []) if name}
            overlap = report_names & candidate_names
            if overlap:
                matched = candidate
                matched_names = overlap
                break
        if matched is None:
            unmatched_groups += 1
            continue
        matched_groups += 1
        published = _parse_wib_timestamp(matched.get("published_at"))
        period_end = _period_end(year, period)
        if published.date() < period_end or published > current:
            skipped_non_pit += 1
            continue

        for attachment in report.get("attachments") or []:
            if not isinstance(attachment, dict) or not attachment.get("structured"):
                continue
            file_name = _collapse(attachment.get("file_name"))
            file_url = str(attachment.get("file_url") or "")
            if _normalize_name(file_name) not in matched_names:
                skipped_attachment_identity += 1
                continue
            if not file_url or not is_official_idx_url(file_url):
                skipped_attachment_identity += 1
                continue
            dedupe = (ticker, year, period, file_url)
            if dedupe in seen_urls:
                continue
            seen_urls.add(dedupe)
            material = "|".join((ticker, str(year), period, published.isoformat(), file_url))
            filings.append(
                {
                    "filing_id": f"BLOCKIDX-FILING-{_sha256_text(material)[:32]}",
                    "ticker": ticker,
                    "report_year": year,
                    "report_period": period,
                    "report_period_end": period_end.isoformat(),
                    "published_at": published.isoformat(),
                    "file_modified_at": modified.isoformat(),
                    "file_url": file_url,
                    "file_name": file_name,
                    "file_type": str(attachment.get("file_type") or PurePosixPath(file_name).suffix).lower(),
                    "report_type": "IDX_LISTED_COMPANY_FINANCIAL_REPORT",
                    "source_key": "IDX_XBRL_FINANCIAL_REPORT",
                    "content_hash": None,
                    "publication_time_verified": True,
                    "source_verified": True,
                    "point_in_time_eligible": True,
                    "extraction_state": "FILE_INDEXED_PIT_VERIFIED",
                    "provenance_state": "OFFICIAL_BLOCK_IDX_FINANCIAL_REPORT_PLUS_PROFILE_ANNOUNCEMENT",
                    "announcement_id": matched.get("announcement_id"),
                    "announcement_no": matched.get("announcement_no"),
                    "announcement_title": matched.get("title"),
                    "announcement_jmsx_group_id": matched.get("jmsx_group_id"),
                }
            )

    return filings, {
        "financial_announcement_rows": announcement_count,
        "report_groups": report_groups,
        "matched_report_groups": matched_groups,
        "unmatched_report_groups": unmatched_groups,
        "skipped_non_pit_groups": skipped_non_pit,
        "skipped_attachment_identity": skipped_attachment_identity,
        "filing_rows": len(filings),
    }


def verify_attachment_hashes(
    filings: list[dict[str, object]],
    *,
    limit: int = 3,
    timeout: float = 90.0,
) -> list[dict[str, object]]:
    verified: list[dict[str, object]] = []
    for row in filings[: max(0, int(limit))]:
        data, digest, content_type = download_official_idx_attachment(str(row["file_url"]), timeout=timeout, retries=2)
        row["content_hash"] = digest
        row["extraction_state"] = "FILE_HASH_VERIFIED_NOT_PARSED"
        verified.append(
            {
                "ticker": row["ticker"],
                "file_name": row["file_name"],
                "bytes": len(data),
                "sha256": digest,
                "content_type": content_type,
            }
        )
    return verified


__all__ = [
    "FINANCIAL_REPORT_PATH",
    "PROFILE_ANNOUNCEMENT_PATH",
    "fetch_financial_report_market",
    "parse_financial_report_payload",
    "fetch_profile_announcements_market",
    "parse_profile_announcement_replies",
    "match_point_in_time_financial_filings",
    "verify_attachment_hashes",
]
