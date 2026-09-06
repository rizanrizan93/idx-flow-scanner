from __future__ import annotations

import json
from datetime import date, timedelta
from urllib.parse import urlencode, urljoin, urlsplit

from curl_cffi import requests

from idx_flow_scanner.official_filings import sha256_bytes, validate_file_magic, validate_no_redirect, validate_official_url
from idx_flow_scanner.official_xbrl import parse_instance_zip

BASE = "https://block.idx.id"
ANNOUNCEMENT_API = f"{BASE}/primary/ListedCompany/GetAnnouncement"
FINANCIAL_API = f"{BASE}/primary/ListedCompany/GetFinancialReport"


def _get(url: str, *, accept: str, require_200: bool = True):
    response = requests.get(
        url,
        impersonate="chrome",
        timeout=45,
        headers={"Accept": accept, "Referer": BASE + "/"},
        allow_redirects=False,
    )
    print("GET", urlsplit(url).hostname, urlsplit(url).path.rsplit("/", 1)[-1], "status", response.status_code, "location", response.headers.get("location"))
    validate_no_redirect(response, expected_url=url)
    if require_200:
        response.raise_for_status()
    return response


def _get_json(url: str, params: dict[str, object]) -> dict[str, object]:
    response = _get(f"{url}?{urlencode(params)}", accept="application/json, text/plain, */*")
    payload = response.json()
    if not isinstance(payload, dict):
        raise TypeError("IDX response is not an object")
    return payload


def probe_announcements() -> None:
    today = date.today()
    payload = _get_json(
        ANNOUNCEMENT_API,
        {
            "kodeEmiten": "BBCA", "emitenType": "*", "indexFrom": 0, "pageSize": 5,
            "dateFrom": (today - timedelta(days=90)).strftime("%Y%m%d"),
            "dateTo": today.strftime("%Y%m%d"), "lang": "id", "keyword": "",
        },
    )
    rows = payload.get("Replies") or []
    print("announcement_count", payload.get("ResultCount") or len(rows), "page_rows", len(rows))
    if not rows or not isinstance(rows[0], dict):
        return
    attachments = rows[0].get("attachments") or []
    candidate = next((a for a in attachments if isinstance(a, dict) and a.get("FullSavePath")), None)
    if not candidate:
        return
    original = validate_official_url(str(candidate["FullSavePath"]), allow_hosts=frozenset({"www.idx.co.id"}))
    direct = _get(original, accept="application/pdf, application/octet-stream, */*", require_200=False)
    print("announcement_www_static_status", direct.status_code)
    path = urlsplit(original).path
    alternate = validate_official_url(f"https://block.idx.id{path}", allow_hosts=frozenset({"block.idx.id"}))
    response = _get(alternate, accept="application/pdf, application/octet-stream, */*")
    content = bytes(response.content)
    validate_file_magic(content, "pdf")
    print("announcement_block_static_pdf", json.dumps({"bytes": len(content), "sha256": sha256_bytes(content), "transport_url": alternate}))


def probe_financial() -> None:
    payload = _get_json(
        FINANCIAL_API,
        {"periode": "TW2", "year": 2026, "indexFrom": 0, "pageSize": 5, "reportType": "rdf", "kodeEmiten": "BBCA"},
    )
    rows = payload.get("Results") or []
    if not rows or not isinstance(rows[0], dict):
        return
    attachments = rows[0].get("Attachments") or []
    instance = next(a for a in attachments if isinstance(a, dict) and str(a.get("File_Name") or "").lower() == "instance.zip")
    path = str(instance.get("File_Path") or "")
    response = _get(urljoin(BASE + "/", path.lstrip("/")), accept="application/zip, application/octet-stream, */*")
    parsed = parse_instance_zip(bytes(response.content))
    contexts = parsed.get("contexts") or {}
    identifiers = sorted({str(v.get("identifier")) for v in contexts.values() if isinstance(v, dict) and v.get("identifier")})
    facts = parsed.get("facts") or []
    entity_codes = sorted({str(getattr(f, "raw_value", "")) for f in facts if getattr(f, "concept", "") == "EntityCode" and getattr(f, "raw_value", None)})
    print("xbrl_identifiers", identifiers)
    print("xbrl_entity_codes", entity_codes)


def main() -> None:
    probe_announcements()
    probe_financial()


if __name__ == "__main__":
    main()
