from __future__ import annotations

import hashlib
import re
import time
from datetime import datetime
from pathlib import PurePosixPath
from typing import Any
from urllib.parse import urljoin, urlparse
from zoneinfo import ZoneInfo

from bs4 import BeautifulSoup
from curl_cffi import requests as curl_requests

BLOCK_IDX_BASE = "https://block.idx.id"
BLOCK_IDX_ANNOUNCEMENT_PAGE = f"{BLOCK_IDX_BASE}/id/berita/pengumuman"
BLOCK_IDX_ANNOUNCEMENT_API = f"{BLOCK_IDX_BASE}/primary/NewsAnnouncement/GetAllAnnouncement"
IDX_OFFICIAL_ATTACHMENT_HOSTS = {"idx.co.id", "www.idx.co.id", "block.idx.id"}
IDX_WIB = ZoneInfo("Asia/Jakarta")


def _collapse(value: object) -> str:
    return " ".join(str(value or "").split())


def _sha256_text(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def is_official_idx_url(url: str) -> bool:
    try:
        parsed = urlparse(str(url or "").strip())
    except Exception:
        return False
    return parsed.scheme == "https" and parsed.netloc.lower() in IDX_OFFICIAL_ATTACHMENT_HOSTS


def parse_block_idx_timestamp(text: str) -> datetime:
    clean = _collapse(text)
    parsed = datetime.strptime(clean, "%d %b %Y %H:%M:%S")
    return parsed.replace(tzinfo=IDX_WIB)


def classify_disclosure(title: str) -> str:
    value = _collapse(title).upper()
    if "LAPORAN KEUANGAN" in value or "FINANCIAL STATEMENT" in value:
        return "FINANCIAL_REPORT"
    if "REGISTRASI PEMEGANG EFEK" in value or "KEPEMILIKAN" in value or "PEMEGANG SAHAM" in value:
        return "OWNERSHIP"
    if "PUBLIC EXPOSE" in value:
        return "PUBLIC_EXPOSE"
    if "VOLATILITAS" in value or "PERMINTAAN PENJELASAN" in value:
        return "VOLATILITY_EXPLANATION"
    if any(token in value for token in ("DIREKSI", "KOMISARIS", "KOMITE AUDIT", "SEKRETARIS PERUSAHAAN")):
        return "MANAGEMENT_GOVERNANCE"
    if any(token in value for token in ("DIVIDEN", "RIGHTS ISSUE", "HMETD", "PRIVATE PLACEMENT", "PEMECAHAN SAHAM", "STOCK SPLIT")):
        return "CAPITAL_ACTION"
    return "OTHER_DISCLOSURE"


def _ticker_from_title(title_node: Any, title: str) -> str | None:
    if title_node is not None:
        span = title_node.find("span")
        if span is not None:
            ticker = _collapse(span.get_text(" ", strip=True)).upper()
            if ticker:
                return ticker
    match = re.search(r"\[\s*([A-Z0-9.-]{2,15})\s*\]\s*$", title.upper())
    return match.group(1) if match else None


def _official_href(value: object, base: str = BLOCK_IDX_ANNOUNCEMENT_PAGE) -> str | None:
    raw = str(value or "").strip()
    if not raw:
        return None
    href = urljoin(base, raw)
    return href if is_official_idx_url(href) else None


def parse_block_idx_announcement_html(html: str) -> list[dict[str, object]]:
    """Parse server-rendered Block IDX announcement cards.

    The public JSON endpoint is intermittently blocked from cloud egress, while
    the server-rendered HTML contains the same timestamp/title/ticker and official
    IDX attachment links. Rows fail closed if timestamp or official primary URL
    cannot be verified from the official page.
    """
    soup = BeautifulSoup(str(html or ""), "html.parser")
    rows: list[dict[str, object]] = []
    for card in soup.select("div.attach-card"):
        time_node = card.select_one("time.text-small")
        title_node = card.select_one("h6.title")
        if time_node is None or title_node is None:
            continue
        try:
            published = parse_block_idx_timestamp(time_node.get_text(" ", strip=True))
        except Exception:
            continue
        title = _collapse(title_node.get_text(" ", strip=True))
        ticker = _ticker_from_title(title_node, title)
        primary_anchor = title_node.find_parent("a", href=True)
        primary_url = _official_href(primary_anchor.get("href") if primary_anchor else None)
        if not title or primary_url is None:
            continue

        attachments: list[dict[str, str]] = []
        seen: set[str] = set()
        # Preserve the primary document as evidence attachment 0.
        primary_name = PurePosixPath(urlparse(primary_url).path).name or "primary_document"
        attachments.append({"url": primary_url, "file_name": primary_name, "role": "PRIMARY"})
        seen.add(primary_url)
        for anchor in card.select("ul.list-nostyle a[href]"):
            url = _official_href(anchor.get("href"))
            if url is None or url in seen:
                continue
            small = anchor.find("small")
            name = _collapse(small.get_text(" ", strip=True) if small else anchor.get_text(" ", strip=True))
            if not name:
                name = PurePosixPath(urlparse(url).path).name
            attachments.append({"url": url, "file_name": name, "role": "ATTACHMENT"})
            seen.add(url)

        published_iso = published.isoformat()
        stable_material = "|".join((published_iso, ticker or "", title, primary_url))
        announcement_id = f"BLOCKIDX-{_sha256_text(stable_material)[:32]}"
        rows.append(
            {
                "announcement_id": announcement_id,
                "ticker": ticker,
                "published_at": published_iso,
                "announcement_no": None,
                "title": title,
                "disclosure_type": classify_disclosure(title),
                "official_detail_url": primary_url,
                "attachment_urls": attachments,
                "source_key": "IDX_DISCLOSURE_ANNOUNCEMENT",
                "content_hash": _sha256_text(stable_material + "|" + "|".join(a["url"] for a in attachments)),
                "publication_time_verified": True,
                "source_verified": True,
                "point_in_time_eligible": True,
                "narrative_extraction_state": "METADATA_WITH_OFFICIAL_ATTACHMENTS",
                "provenance_state": "OFFICIAL_BLOCK_IDX_SSR_POINT_IN_TIME",
            }
        )
    return rows


def _new_session() -> Any:
    return curl_requests.Session(impersonate="chrome")


def fetch_block_idx_current_announcements(*, timeout: float = 40.0, retries: int = 3) -> list[dict[str, object]]:
    session = _new_session()
    headers = {
        "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        "Accept-Language": "id-ID,id;q=0.9,en;q=0.8",
        "User-Agent": "Mozilla/5.0",
    }
    last_error: Exception | None = None
    for attempt in range(max(1, int(retries))):
        try:
            response = session.get(BLOCK_IDX_ANNOUNCEMENT_PAGE, headers=headers, timeout=timeout)
            if response.status_code == 200:
                rows = parse_block_idx_announcement_html(response.text)
                if rows:
                    return rows
            if response.status_code in {401, 403, 429, 500, 502, 503, 504}:
                time.sleep(min(8.0, 1.5 * (2**attempt)))
                continue
            response.raise_for_status()
        except Exception as exc:  # pragma: no cover - network path
            last_error = exc
            time.sleep(min(8.0, 1.5 * (2**attempt)))
    if last_error:
        raise RuntimeError(f"Block IDX announcement page unavailable: {type(last_error).__name__}") from last_error
    return []


def infer_financial_period(title: str, file_name: str) -> tuple[int | None, str | None]:
    text = f"{title} {file_name}".upper()
    years = re.findall(r"(?<!\d)(20\d{2})(?!\d)", text)
    year = int(years[0]) if years else None
    if any(token in text for token in ("TAHUNAN", "AUDIT", "ANNUAL")):
        return year, "AUDIT"
    if any(token in text for token in ("TW3", "Q3", "TRIWULAN III", "TRIWULAN 3")):
        return year, "TW3"
    if any(token in text for token in ("TW2", "Q2", "TRIWULAN II", "TRIWULAN 2", "SEMESTER I", "SEMESTER 1")):
        return year, "TW2"
    if any(token in text for token in ("TW1", "Q1", "TRIWULAN I", "TRIWULAN 1")):
        return year, "TW1"
    return year, None


def financial_filings_from_announcements(rows: list[dict[str, object]]) -> list[dict[str, object]]:
    filings: list[dict[str, object]] = []
    for row in rows:
        if row.get("disclosure_type") != "FINANCIAL_REPORT" or not row.get("ticker"):
            continue
        attachments = row.get("attachment_urls") if isinstance(row.get("attachment_urls"), list) else []
        for attachment in attachments:
            if not isinstance(attachment, dict):
                continue
            url = str(attachment.get("url") or "")
            file_name = str(attachment.get("file_name") or PurePosixPath(urlparse(url).path).name)
            suffix = PurePosixPath(file_name).suffix.lower()
            if suffix not in {".xlsx", ".xls", ".zip", ".xml", ".xhtml"}:
                continue
            year, period = infer_financial_period(str(row.get("title") or ""), file_name)
            if year is None or period is None:
                continue
            period_end = {
                "TW1": f"{year}-03-31",
                "TW2": f"{year}-06-30",
                "TW3": f"{year}-09-30",
                "AUDIT": f"{year}-12-31",
            }[period]
            filing_material = f"{row['announcement_id']}|{url}"
            filings.append(
                {
                    "filing_id": f"BLOCKIDX-FILING-{_sha256_text(filing_material)[:32]}",
                    "ticker": row["ticker"],
                    "report_year": year,
                    "report_period": period,
                    "report_period_end": period_end,
                    "published_at": row["published_at"],
                    "file_modified_at": None,
                    "file_url": url,
                    "file_name": file_name,
                    "file_type": suffix,
                    "report_type": "BLOCK_IDX_ANNOUNCEMENT_ATTACHMENT",
                    "source_key": "IDX_XBRL_FINANCIAL_REPORT",
                    "content_hash": None,
                    "publication_time_verified": True,
                    "source_verified": is_official_idx_url(url),
                    "point_in_time_eligible": bool(row.get("point_in_time_eligible") and is_official_idx_url(url)),
                    "extraction_state": "FILE_INDEXED_NOT_PARSED",
                    "provenance_state": "OFFICIAL_BLOCK_IDX_FINANCIAL_FILING_POINT_IN_TIME",
                }
            )
    return filings


def download_official_idx_attachment(url: str, *, timeout: float = 60.0, retries: int = 3) -> tuple[bytes, str, str | None]:
    if not is_official_idx_url(url):
        raise ValueError("non-official IDX URL rejected")
    headers = {
        "Accept": "*/*",
        "Accept-Language": "id-ID,id;q=0.9,en;q=0.8",
        "Referer": BLOCK_IDX_ANNOUNCEMENT_PAGE,
        "User-Agent": "Mozilla/5.0",
    }
    session = _new_session()
    last_status = 0
    for attempt in range(max(1, int(retries))):
        response = session.get(url, headers=headers, timeout=timeout)
        last_status = int(response.status_code)
        if response.status_code == 200 and response.content:
            data = bytes(response.content)
            # Reject HTML error/challenge pages pretending to be a file.
            prefix = data[:32].lstrip().lower()
            if prefix.startswith(b"<!doctype html") or prefix.startswith(b"<html"):
                raise RuntimeError("IDX attachment returned HTML instead of evidence file")
            digest = hashlib.sha256(data).hexdigest()
            return data, digest, response.headers.get("content-type")
        if response.status_code in {403, 429, 500, 502, 503, 504}:
            time.sleep(min(8.0, 1.5 * (2**attempt)))
            continue
        break
    raise RuntimeError(f"IDX attachment download failed with HTTP {last_status}")


__all__ = [
    "BLOCK_IDX_ANNOUNCEMENT_PAGE",
    "BLOCK_IDX_ANNOUNCEMENT_API",
    "is_official_idx_url",
    "parse_block_idx_timestamp",
    "classify_disclosure",
    "parse_block_idx_announcement_html",
    "fetch_block_idx_current_announcements",
    "infer_financial_period",
    "financial_filings_from_announcements",
    "download_official_idx_attachment",
]
