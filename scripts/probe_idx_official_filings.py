from __future__ import annotations

import hashlib
from pathlib import PurePosixPath
from urllib.parse import quote, urlencode, urljoin, urlsplit, urlunsplit

from curl_cffi import requests

BASE = "https://block.idx.id"
API = f"{BASE}/primary/ListedCompany"


def _official_attachment_url(url: str) -> str:
    parts = urlsplit(url)
    if parts.scheme != "https" or (parts.hostname or "").lower() != "block.idx.id":
        raise ValueError("attachment must use official block.idx.id HTTPS")
    encoded_path = quote(parts.path, safe="/%:@-._~!$&'()*+,;=")
    return urlunsplit((parts.scheme, parts.netloc, encoded_path, parts.query, ""))


def _get_json(session: requests.Session, path: str, params: dict[str, object], *, required: bool = True) -> dict:
    url = f"{API}/{path}?{urlencode(params)}"
    response = session.get(
        url,
        headers={"Accept": "application/json, text/plain, */*", "Referer": f"{BASE}/", "X-Requested-With": "XMLHttpRequest"},
        timeout=45,
    )
    print(path, "status=", response.status_code, "bytes=", len(response.content), "url=", response.url)
    if response.status_code != 200:
        print(response.text[:1000])
        if required:
            raise SystemExit(f"{path} HTTP {response.status_code}")
        return {}
    payload = response.json()
    if not isinstance(payload, dict):
        if required:
            raise SystemExit(f"{path} non-object payload")
        return {}
    return payload


def main() -> None:
    session = requests.Session(impersonate="chrome")

    financial = _get_json(
        session,
        "GetFinancialReport",
        {"periode": "TW2", "year": 2026, "indexFrom": 0, "pageSize": 20, "reportType": "rdf", "kodeEmiten": "BBCA"},
    )
    reports = financial.get("Results") or []
    print("financial ResultCount=", financial.get("ResultCount"), "rows=", len(reports))
    if not reports:
        raise SystemExit("no BBCA 2026 TW2 financial report")

    attachments = reports[0].get("Attachments") or []
    print("attachments=", [(a.get("File_Name"), a.get("File_Type"), a.get("File_Size")) for a in attachments])
    candidates = [a for a in attachments if PurePosixPath(str(a.get("File_Name") or "")).name.lower() == "instance.zip"]
    if len(candidates) != 1:
        raise SystemExit(f"expected exactly one instance.zip, got {len(candidates)}")
    attachment = candidates[0]
    download_url = _official_attachment_url(urljoin(f"{BASE}/", str(attachment.get("File_Path") or "")))
    file_response = session.get(
        download_url,
        headers={"Accept": "application/zip, application/octet-stream, */*", "Referer": f"{BASE}/"},
        timeout=60,
    )
    content = bytes(file_response.content)
    print(
        "instance.zip status=", file_response.status_code,
        "bytes=", len(content), "expected_bytes=", attachment.get("File_Size"),
        "magic=", content[:8].hex(),
        "sha256=", hashlib.sha256(content).hexdigest() if file_response.status_code == 200 else None,
    )
    if file_response.status_code != 200 or not content.startswith(b"PK") or len(content) != int(attachment.get("File_Size") or -1):
        raise SystemExit("official instance.zip failed integrity gate")

    ann = _get_json(
        session,
        "GetAnnouncement",
        {"kodeEmiten": "BBCA", "indexFrom": 0, "pageSize": 5, "dateFrom": "20260801", "dateTo": "20260906", "lang": "id"},
        required=False,
    )
    replies = ann.get("Replies") or []
    print("announcement ResultCount=", ann.get("ResultCount"), "rows=", len(replies))
    if replies:
        detail = replies[0].get("pengumuman") or {}
        print("announcement sample=", detail.get("NoPengumuman"), detail.get("TglPengumuman"), detail.get("JudulPengumuman"))


if __name__ == "__main__":
    main()
