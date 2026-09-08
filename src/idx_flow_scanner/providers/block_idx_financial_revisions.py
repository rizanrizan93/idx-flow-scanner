from __future__ import annotations

import hashlib
import re
from datetime import date, datetime
from pathlib import PurePosixPath
from typing import Any, Iterable
from urllib.parse import quote
from zoneinfo import ZoneInfo

from idx_flow_scanner.providers.block_idx_evidence import infer_financial_period, is_official_idx_url

IDX_WIB = ZoneInfo("Asia/Jakarta")
STRUCTURED_SUFFIXES = {".xlsx", ".xls", ".zip", ".xml", ".xhtml"}
PERIOD_END_MONTH_DAY = {
    "TW1": (3, 31),
    "TW2": (6, 30),
    "TW3": (9, 30),
    "AUDIT": (12, 31),
}


def _collapse(value: object) -> str:
    return " ".join(str(value or "").split())


def _parse_wib(value: object) -> datetime:
    parsed = datetime.fromisoformat(str(value or "").strip())
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=IDX_WIB)
    return parsed.astimezone(IDX_WIB)


def _official_attachment_url(value: object) -> str | None:
    raw = str(value or "").strip()
    if not raw:
        return None
    if raw.lower().startswith("https://"):
        return raw if is_official_idx_url(raw) else None
    normalized = "/" + raw.replace("\\", "/").lstrip("/")
    encoded = quote(normalized, safe="/:._-~()[]")
    url = "https://www.idx.co.id" + encoded
    return url if is_official_idx_url(url) else None


def _is_financial_title(value: object) -> bool:
    text = _collapse(value).upper()
    return "LAPORAN KEUANGAN" in text or "FINANCIAL STATEMENT" in text


def _period_end(year: int, period: str) -> date:
    month, day = PERIOD_END_MONTH_DAY[period]
    return date(year, month, day)


def _infer_from_standard_financial_filename(file_name: str) -> tuple[int | None, str | None]:
    text = _collapse(file_name).upper()
    match = re.search(
        r"FINANCIAL\s*STATEMENT[-_\s]*(20\d{2})[-_\s]*(TW[123]|Q[123]|III|II|I|3|2|1|AUDIT|TAHUNAN|ANNUAL)(?:[-_.\s]|$)",
        text,
    )
    if not match:
        match = re.search(
            r"FINANCIALSTATEMENT[-_\s]*(20\d{2})[-_\s]*(TW[123]|Q[123]|III|II|I|3|2|1|AUDIT|TAHUNAN|ANNUAL)(?:[-_.\s]|$)",
            text,
        )
    if not match:
        return None, None
    year = int(match.group(1))
    token = match.group(2)
    period = {
        "I": "TW1",
        "1": "TW1",
        "Q1": "TW1",
        "TW1": "TW1",
        "II": "TW2",
        "2": "TW2",
        "Q2": "TW2",
        "TW2": "TW2",
        "III": "TW3",
        "3": "TW3",
        "Q3": "TW3",
        "TW3": "TW3",
        "AUDIT": "AUDIT",
        "TAHUNAN": "AUDIT",
        "ANNUAL": "AUDIT",
    }.get(token)
    return year, period


def infer_profile_financial_period(title: str, attachment_names: Iterable[str]) -> tuple[int | None, str | None]:
    names = [str(name) for name in attachment_names if str(name or "").strip()]

    # The standardized IDX FinancialStatement filename is the strongest period authority.
    # This must be evaluated before title fallback because Indonesian phrases such as
    # "Tidak Diaudit" contain the substring "AUDIT" but do not mean annual/audited period.
    standard_candidates: set[tuple[int, str]] = set()
    for name in names:
        year, period = _infer_from_standard_financial_filename(name)
        if year is not None and period is not None:
            standard_candidates.add((year, period))
    if len(standard_candidates) == 1:
        return next(iter(standard_candidates))
    if len(standard_candidates) > 1:
        return None, None

    fallback_candidates: set[tuple[int, str]] = set()
    for name in names:
        year, period = infer_financial_period(title, name)
        if year is not None and period is not None:
            fallback_candidates.add((year, period))
    if len(fallback_candidates) == 1:
        return next(iter(fallback_candidates))
    return None, None


def financial_revision_filings_from_profile_replies(
    replies: Iterable[dict[str, Any]],
    *,
    report_groups: Iterable[dict[str, object]] | None = None,
    now: datetime | None = None,
) -> tuple[list[dict[str, object]], dict[str, object]]:
    current = now.astimezone(IDX_WIB) if now is not None else datetime.now(IDX_WIB)
    corroboration: dict[tuple[str, str], tuple[int, str, str]] = {}
    for report in report_groups or []:
        try:
            ticker = _collapse(report.get("ticker")).upper()
            modified = _parse_wib(report.get("file_modified_at"))
            year = int(report.get("report_year"))
            period = _collapse(report.get("report_period")).upper()
        except Exception:
            continue
        if ticker and period in PERIOD_END_MONTH_DAY:
            corroboration[(ticker, modified.replace(microsecond=0).isoformat())] = (
                year,
                period,
                modified.isoformat(),
            )

    filings: list[dict[str, object]] = []
    seen: set[tuple[str, int, str, str]] = set()
    financial_announcements = 0
    structured_financial_announcements = 0
    nonstructured_financial_notices = 0
    inferred_announcements = 0
    corroborated_fallback = 0
    unresolved_period = 0
    unresolved_structured = 0
    skipped_non_pit = 0
    skipped_nonofficial = 0
    skipped_unstructured = 0
    anomaly_samples: list[dict[str, object]] = []

    for reply in replies:
        if not isinstance(reply, dict):
            continue
        announcement = reply.get("pengumuman")
        if not isinstance(announcement, dict):
            continue
        title = _collapse(announcement.get("JudulPengumuman"))
        if not _is_financial_title(title):
            continue
        financial_announcements += 1
        ticker = _collapse(announcement.get("Kode_Emiten")).upper()
        announcement_id = _collapse(announcement.get("Id2"))
        if not ticker or not announcement_id:
            unresolved_period += 1
            continue
        try:
            published = _parse_wib(announcement.get("TglPengumuman"))
        except Exception:
            unresolved_period += 1
            continue
        attachments = [item for item in (reply.get("attachments") or []) if isinstance(item, dict)]
        attachment_names = [
            _collapse(item.get("OriginalFilename") or item.get("PDFFilename"))
            for item in attachments
            if _collapse(item.get("OriginalFilename") or item.get("PDFFilename"))
        ]
        has_structured = any(PurePosixPath(name).suffix.lower() in STRUCTURED_SUFFIXES for name in attachment_names)
        if has_structured:
            structured_financial_announcements += 1
        else:
            nonstructured_financial_notices += 1
            continue

        year, period = infer_profile_financial_period(title, attachment_names)
        file_modified_at: str | None = None
        if year is None or period is None:
            fallback = corroboration.get((ticker, published.replace(microsecond=0).isoformat()))
            if fallback is not None:
                year, period, file_modified_at = fallback
                corroborated_fallback += 1
        if year is None or period is None:
            unresolved_period += 1
            unresolved_structured += 1
            if len(anomaly_samples) < 50:
                standard_candidates = sorted({
                    candidate
                    for name in attachment_names
                    for candidate in [_infer_from_standard_financial_filename(name)]
                    if candidate[0] is not None and candidate[1] is not None
                })
                anomaly_samples.append({
                    "reason": "UNRESOLVED_STRUCTURED_PERIOD",
                    "ticker": ticker,
                    "published_at": published.isoformat(),
                    "announcement_id": announcement_id,
                    "announcement_no": _collapse(announcement.get("NoPengumuman")) or None,
                    "title": title,
                    "standard_filename_candidates": standard_candidates,
                    "attachment_names": attachment_names,
                })
            continue
        inferred_announcements += 1
        period_end = _period_end(int(year), str(period))
        if published.date() < period_end or published > current:
            skipped_non_pit += 1
            if len(anomaly_samples) < 50:
                anomaly_samples.append({
                    "reason": "NON_PIT_PUBLICATION_TIME",
                    "ticker": ticker,
                    "published_at": published.isoformat(),
                    "announcement_id": announcement_id,
                    "announcement_no": _collapse(announcement.get("NoPengumuman")) or None,
                    "title": title,
                    "inferred_report_year": int(year),
                    "inferred_report_period": str(period),
                    "report_period_end": period_end.isoformat(),
                    "current_time": current.isoformat(),
                    "attachment_names": attachment_names,
                })
            continue

        for item in attachments:
            file_name = _collapse(item.get("OriginalFilename") or item.get("PDFFilename"))
            suffix = PurePosixPath(file_name).suffix.lower()
            if suffix not in STRUCTURED_SUFFIXES:
                skipped_unstructured += 1
                continue
            file_url = _official_attachment_url(item.get("FullSavePath"))
            if file_url is None:
                skipped_nonofficial += 1
                continue
            dedupe = (ticker, int(year), str(period), file_url)
            if dedupe in seen:
                continue
            seen.add(dedupe)
            material = f"{announcement_id}|{file_url}"
            filings.append(
                {
                    "filing_id": "BLOCKIDX-FILING-" + hashlib.sha256(material.encode("utf-8")).hexdigest()[:32],
                    "ticker": ticker,
                    "report_year": int(year),
                    "report_period": str(period),
                    "report_period_end": period_end.isoformat(),
                    "published_at": published.isoformat(),
                    "file_modified_at": file_modified_at,
                    "file_url": file_url,
                    "file_name": file_name,
                    "file_type": suffix,
                    "report_type": "BLOCK_IDX_PROFILE_ANNOUNCEMENT_ATTACHMENT",
                    "source_key": "IDX_XBRL_FINANCIAL_REPORT",
                    "content_hash": None,
                    "publication_time_verified": True,
                    "source_verified": True,
                    "point_in_time_eligible": True,
                    "extraction_state": "FILE_INDEXED_PIT_VERIFIED",
                    "provenance_state": "OFFICIAL_BLOCK_IDX_PROFILE_ANNOUNCEMENT_POINT_IN_TIME",
                    "announcement_id": announcement_id,
                    "announcement_no": _collapse(announcement.get("NoPengumuman")) or None,
                    "announcement_title": title,
                    "announcement_jmsx_group_id": _collapse(announcement.get("JMSXGroupID")) or None,
                }
            )

    filings.sort(
        key=lambda row: (
            str(row["published_at"]),
            str(row["ticker"]),
            str(row["report_period"]),
            str(row["file_name"]),
        )
    )
    return filings, {
        "financial_announcements": financial_announcements,
        "structured_financial_announcements": structured_financial_announcements,
        "nonstructured_financial_notices": nonstructured_financial_notices,
        "inferred_announcements": inferred_announcements,
        "corroborated_period_fallback": corroborated_fallback,
        "unresolved_period_announcements": unresolved_period,
        "unresolved_structured_announcements": unresolved_structured,
        "skipped_non_pit_announcements": skipped_non_pit,
        "skipped_nonofficial_attachments": skipped_nonofficial,
        "skipped_unstructured_attachments": skipped_unstructured,
        "filing_rows": len(filings),
        "anomaly_samples": anomaly_samples,
    }


__all__ = [
    "infer_profile_financial_period",
    "financial_revision_filings_from_profile_replies",
]
