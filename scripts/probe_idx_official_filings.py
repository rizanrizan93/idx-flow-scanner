from __future__ import annotations

import json
from datetime import date, timedelta
from urllib.parse import urlencode

from curl_cffi import requests

BASE = "https://block.idx.id"
ANNOUNCEMENT_API = f"{BASE}/primary/ListedCompany/GetAnnouncement"
FINANCIAL_API = f"{BASE}/primary/ListedCompany/GetFinancialReport"


def _get_json(url: str, params: dict[str, object]) -> dict[str, object]:
    response = requests.get(
        f"{url}?{urlencode(params)}",
        impersonate="chrome",
        timeout=45,
        headers={"Accept": "application/json, text/plain, */*", "Referer": BASE + "/"},
        allow_redirects=False,
    )
    print("GET", url.rsplit("/", 1)[-1], "status", response.status_code, "location", response.headers.get("location"))
    response.raise_for_status()
    payload = response.json()
    if not isinstance(payload, dict):
        raise TypeError("IDX response is not an object")
    return payload


def probe_announcements() -> None:
    today = date.today()
    payload = _get_json(
        ANNOUNCEMENT_API,
        {
            "kodeEmiten": "BBCA",
            "emitenType": "*",
            "indexFrom": 0,
            "pageSize": 5,
            "dateFrom": (today - timedelta(days=90)).strftime("%Y%m%d"),
            "dateTo": today.strftime("%Y%m%d"),
            "lang": "id",
            "keyword": "",
        },
    )
    rows = payload.get("Results") or payload.get("results") or []
    print("announcement_top_keys", sorted(payload.keys()))
    print("announcement_count", payload.get("ResultCount") or payload.get("resultCount") or len(rows))
    if rows and isinstance(rows[0], dict):
        row = rows[0]
        safe = {key: row.get(key) for key in sorted(row) if key.lower() not in {"content", "isi", "body"}}
        print("announcement_row", json.dumps(safe, ensure_ascii=False, default=str)[:8000])


def probe_financial() -> None:
    payload = _get_json(
        FINANCIAL_API,
        {
            "periode": "TW2",
            "year": 2026,
            "indexFrom": 0,
            "pageSize": 5,
            "reportType": "rdf",
            "kodeEmiten": "BBCA",
        },
    )
    rows = payload.get("Results") or []
    print("financial_count", payload.get("ResultCount") or len(rows))
    if rows and isinstance(rows[0], dict):
        print("financial_keys", sorted(rows[0].keys()))
        attachments = rows[0].get("Attachments") or []
        print("financial_attachment_names", [a.get("File_Name") for a in attachments if isinstance(a, dict)])


def main() -> None:
    probe_announcements()
    probe_financial()


if __name__ == "__main__":
    main()
