from __future__ import annotations

import hashlib
import re
from datetime import datetime
from typing import Any
from urllib.parse import quote, urljoin, urlsplit, urlunsplit

from .data import canonical_ticker

OFFICIAL_DISCOVERY_HOST = "block.idx.id"
OFFICIAL_STATIC_HOST = "www.idx.co.id"
OFFICIAL_HOSTS = frozenset({OFFICIAL_DISCOVERY_HOST, OFFICIAL_STATIC_HOST})
FINANCIAL_DISCOVERY_SOURCE = "IDX_OFFICIAL_BLOCK_GETFINANCIALREPORT"
ANNOUNCEMENT_DISCOVERY_SOURCE = "IDX_OFFICIAL_BLOCK_GETANNOUNCEMENT"
FINANCIAL_PROVENANCE = "VERIFIED_OFFICIAL_IDX_XBRL_INSTANCE"
ANNOUNCEMENT_METADATA_PROVENANCE = "VERIFIED_OFFICIAL_IDX_ANNOUNCEMENT_METADATA"
ANNOUNCEMENT_ATTACHMENT_PROVENANCE = "VERIFIED_OFFICIAL_IDX_ANNOUNCEMENT_ATTACHMENT"

_EVENT_PATTERNS: tuple[tuple[str, re.Pattern[str]], ...] = (
    ("rights_issue_private_placement", re.compile(r"\b(right issue|hak memesan efek terlebih dahulu|hmetd|private placement|penambahan modal tanpa hak memesan)\b", re.I)),
    ("buyback", re.compile(r"\b(buyback|pembelian kembali saham)\b", re.I)),
    ("stock_split", re.compile(r"\b(stock split|pemecahan nilai nominal)\b", re.I)),
    ("dividend", re.compile(r"\b(dividen|dividend)\b", re.I)),
    ("management_change", re.compile(r"\b(direksi|direktur|komisaris|dewan komisaris|pengunduran diri|pengangkatan)\b", re.I)),
    ("acquisition_divestment", re.compile(r"\b(akuisisi|acquisition|divestasi|divestment|pengambilalihan)\b", re.I)),
    ("subsidiary_change", re.compile(r"\b(entitas anak|anak perusahaan|subsidiar|pendirian perusahaan)\b", re.I)),
    ("debt_refinancing", re.compile(r"\b(refinancing|refinancing|pembiayaan kembali|pinjaman|utang|obligasi|sukuk)\b", re.I)),
    ("litigation", re.compile(r"\b(gugatan|litigasi|litigation|perkara|pengadilan|arbitrase)\b", re.I)),
    ("contract_project", re.compile(r"\b(kontrak|contract|proyek|project|order|pesanan|tender)\b", re.I)),
    ("capex", re.compile(r"\b(capex|belanja modal|capital expenditure)\b", re.I)),
    ("guidance", re.compile(r"\b(guidance|target kinerja|proyeksi|outlook)\b", re.I)),
    ("ownership_controller_change", re.compile(r"\b(pengendali|perubahan kepemilikan|pemegang saham utama)\b", re.I)),
    ("operational_disruption", re.compile(r"\b(gangguan operasional|penghentian operasi|force majeure|kebakaran|banjir)\b", re.I)),
    ("regulatory_event", re.compile(r"\b(sanksi|regulator|otoritas|perizinan|izin usaha)\b", re.I)),
    ("material_transaction", re.compile(r"\b(transaksi material|transaksi afiliasi|material transaction)\b", re.I)),
)


def validate_official_url(value: str, *, allow_hosts: frozenset[str] = OFFICIAL_HOSTS) -> str:
    raw = str(value or "").strip()
    if not raw:
        raise ValueError("official URL is empty")
    parts = urlsplit(raw)
    host = (parts.hostname or "").lower()
    if parts.scheme.lower() != "https" or host not in allow_hosts:
        raise ValueError(f"untrusted official URL host: {host or '<missing>'}")
    if parts.username or parts.password or parts.port not in (None, 443):
        raise ValueError("official URL contains unsupported authority components")
    return urlunsplit(("https", parts.netloc, quote(parts.path, safe="/%:@-._~!$&'()*+,;="), parts.query, ""))


def resolve_official_url(path_or_url: str, *, base: str = "https://block.idx.id/") -> str:
    return validate_official_url(urljoin(base, str(path_or_url or "").strip()))


def validate_no_redirect(response: Any, *, expected_url: str | None = None) -> str:
    status = int(getattr(response, "status_code", 0) or 0)
    if 300 <= status < 400:
        raise ValueError(f"official download redirect rejected: HTTP {status}")
    history = getattr(response, "history", None) or []
    if history:
        raise ValueError("official download redirect chain rejected")
    final_url = validate_official_url(str(getattr(response, "url", "") or expected_url or ""))
    if expected_url is not None and final_url != validate_official_url(expected_url):
        raise ValueError("official download final URL changed")
    return final_url


def sha256_bytes(content: bytes) -> str:
    return hashlib.sha256(bytes(content)).hexdigest()


def validate_file_magic(content: bytes, document_type: str) -> None:
    data = bytes(content)
    kind = str(document_type or "").strip().lower()
    if kind in {"instance_xbrl_zip", "inline_xbrl_zip", "zip"}:
        if not data.startswith(b"PK"):
            raise ValueError("invalid ZIP magic")
    elif kind == "pdf":
        if not data.startswith(b"%PDF-"):
            raise ValueError("invalid PDF magic")
    elif kind in {"xlsx", "xlsm"}:
        if not data.startswith(b"PK"):
            raise ValueError("invalid XLSX magic")
    else:
        raise ValueError(f"unsupported document type: {document_type}")


def classify_announcement(title: str | None, subject: str | None = None) -> list[str]:
    text = f"{title or ''} {subject or ''}".strip()
    categories = [name for name, pattern in _EVENT_PATTERNS if pattern.search(text)]
    return categories or ["other_disclosure"]


def normalize_announcement_reply(reply: dict[str, Any]) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    if not isinstance(reply, dict):
        raise TypeError("announcement reply must be an object")
    announcement = reply.get("pengumuman")
    attachments = reply.get("attachments") or []
    if not isinstance(announcement, dict):
        raise ValueError("announcement metadata is missing")
    if not isinstance(attachments, list):
        raise ValueError("announcement attachments must be a list")

    ticker = canonical_ticker(announcement.get("Kode_Emiten"))
    event_id = str(announcement.get("Id2") or "").strip()
    announced_at = str(announcement.get("TglPengumuman") or "").strip()
    title = str(announcement.get("JudulPengumuman") or "").strip()
    if not ticker or not event_id or not announced_at or not title:
        raise ValueError("announcement lacks ticker/id/date/title")
    try:
        parsed = datetime.fromisoformat(announced_at.replace("Z", "+00:00"))
    except ValueError as exc:
        raise ValueError("invalid announcement timestamp") from exc

    clean_attachments: list[dict[str, Any]] = []
    for attachment in attachments:
        if not isinstance(attachment, dict):
            continue
        raw_url = str(attachment.get("FullSavePath") or "").strip()
        if not raw_url:
            continue
        try:
            url = validate_official_url(raw_url, allow_hosts=frozenset({OFFICIAL_STATIC_HOST}))
        except ValueError:
            continue
        clean_attachments.append(
            {
                "url": url,
                "original_filename": str(attachment.get("OriginalFilename") or "").strip() or None,
                "stored_filename": str(attachment.get("PDFFilename") or "").strip() or None,
                "is_attachment": bool(attachment.get("IsAttachment")),
            }
        )

    metadata = {
        "ticker": ticker,
        "event_id": event_id,
        "announced_at": parsed.isoformat(),
        "announcement_number": str(announcement.get("NoPengumuman") or "").strip() or None,
        "title": title,
        "announcement_type": str(announcement.get("JenisPengumuman") or "").strip() or None,
        "subject": str(announcement.get("PerihalPengumuman") or "").strip() or None,
        "form_id": str(announcement.get("Form_Id") or "").strip() or None,
        "categories": classify_announcement(title, announcement.get("PerihalPengumuman")),
        "discovery_source": ANNOUNCEMENT_DISCOVERY_SOURCE,
        "source_verified": True,
        "provenance_state": ANNOUNCEMENT_METADATA_PROVENANCE,
    }
    return metadata, clean_attachments


__all__ = [
    "OFFICIAL_HOSTS",
    "OFFICIAL_DISCOVERY_HOST",
    "OFFICIAL_STATIC_HOST",
    "FINANCIAL_DISCOVERY_SOURCE",
    "ANNOUNCEMENT_DISCOVERY_SOURCE",
    "FINANCIAL_PROVENANCE",
    "ANNOUNCEMENT_METADATA_PROVENANCE",
    "ANNOUNCEMENT_ATTACHMENT_PROVENANCE",
    "validate_official_url",
    "resolve_official_url",
    "validate_no_redirect",
    "sha256_bytes",
    "validate_file_magic",
    "classify_announcement",
    "normalize_announcement_reply",
]
