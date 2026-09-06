from __future__ import annotations

import json
from datetime import date, timedelta
from urllib.parse import urlencode, urljoin

from curl_cffi import requests

from idx_flow_scanner.official_xbrl import parse_instance_zip

BASE = "https://block.idx.id"
ANNOUNCEMENT_API = f"{BASE}/primary/ListedCompany/GetAnnouncement"
FINANCIAL_API = f"{BASE}/primary/ListedCompany/GetFinancialReport"


def _get(url: str, *, accept: str):
    response = requests.get(
        url,
        impersonate="chrome",
        timeout=45,
        headers={"Accept": accept, "Referer": BASE + "/"},
        allow_redirects=False,
    )
    print("GET", url.split("?", 1)[0].rsplit("/", 1)[-1], "status", response.status_code, "location", response.headers.get("location"))
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
    print("announcement_top_keys", sorted(payload.keys()))
    print("announcement_count", payload.get("ResultCount") or len(rows), "page_rows", len(rows))
    if rows and isinstance(rows[0], dict):
        print("announcement_reply", json.dumps(rows[0], ensure_ascii=False, default=str)[:12000])


def probe_financial() -> None:
    payload = _get_json(
        FINANCIAL_API,
        {"periode": "TW2", "year": 2026, "indexFrom": 0, "pageSize": 5, "reportType": "rdf", "kodeEmiten": "BBCA"},
    )
    rows = payload.get("Results") or []
    print("financial_count", payload.get("ResultCount") or len(rows))
    if not rows or not isinstance(rows[0], dict):
        return
    attachments = rows[0].get("Attachments") or []
    instance = next(a for a in attachments if isinstance(a, dict) and str(a.get("File_Name") or "").lower() == "instance.zip")
    print("financial_instance", json.dumps(instance, ensure_ascii=False, default=str))
    path = str(instance.get("File_Path") or "")
    response = _get(urljoin(BASE + "/", path.lstrip("/")), accept="application/zip, application/octet-stream, */*")
    parsed = parse_instance_zip(bytes(response.content))
    contexts = parsed.get("contexts") or {}
    identifiers = sorted({str(v.get("identifier")) for v in contexts.values() if isinstance(v, dict) and v.get("identifier")})
    print("xbrl_identifiers", identifiers)
    print("xbrl_context_sample", json.dumps(dict(list(contexts.items())[:8]), ensure_ascii=False, default=str))
    facts = parsed.get("facts") or []
    print("xbrl_fact_sample", [getattr(f, "concept", None) for f in facts[:40]])


def main() -> None:
    probe_announcements()
    probe_financial()


if __name__ == "__main__":
    main()
