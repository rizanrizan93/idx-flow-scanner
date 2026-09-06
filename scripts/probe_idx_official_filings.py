from __future__ import annotations

import json
from datetime import date, timedelta

from curl_cffi import requests

BASE = "https://www.idx.co.id/primary"


def _get(path: str, params: dict[str, object]):
    response = requests.get(
        f"{BASE}/{path}",
        params=params,
        impersonate="chrome",
        timeout=30,
        headers={
            "accept": "application/json, text/plain, */*",
            "accept-language": "id-ID,id;q=0.9,en-US;q=0.8,en;q=0.7",
            "referer": "https://www.idx.co.id/id/perusahaan-tercatat/keterbukaan-informasi/",
        },
    )
    print(path, "status=", response.status_code, "url=", response.url)
    print("content-type=", response.headers.get("content-type"))
    if response.status_code != 200:
        print(response.text[:1000])
        return None
    try:
        return response.json()
    except Exception:
        print(response.text[:1000])
        return None


def _shape(name: str, payload: object) -> None:
    if not isinstance(payload, dict):
        print(name, "payload_type=", type(payload).__name__)
        return
    print(name, "keys=", sorted(payload.keys()))
    for key, value in payload.items():
        if isinstance(value, list):
            print(name, key, "len=", len(value))
            if value:
                first = value[0]
                print(name, key, "first_keys=", sorted(first.keys()) if isinstance(first, dict) else type(first).__name__)
                print(name, key, "first=", json.dumps(first, ensure_ascii=False, default=str)[:5000])


def main() -> None:
    today = date.today()
    announcement = _get(
        "ListedCompany/GetAnnouncement",
        {
            "kodeEmiten": "BBCA",
            "emitenType": "*",
            "indexFrom": 0,
            "pageSize": 10,
            "dateFrom": (today - timedelta(days=60)).strftime("%Y%m%d"),
            "dateTo": today.strftime("%Y%m%d"),
            "lang": "id",
            "keyword": "",
        },
    )
    _shape("announcement", announcement)

    financial = None
    for year, period in ((today.year, "TW2"), (today.year, "TW1"), (today.year - 1, "audit"), (today.year - 1, "TW3")):
        candidate = _get(
            "ListedCompany/GetFinancialReport",
            {
                "periode": period,
                "year": year,
                "indexFrom": 0,
                "pageSize": 20,
                "reportType": "rdf",
                "kodeEmiten": "BBCA",
            },
        )
        print("financial candidate", year, period)
        _shape("financial", candidate)
        if isinstance(candidate, dict) and any(isinstance(v, list) and v for v in candidate.values()):
            financial = candidate
            break
    if financial is None:
        raise SystemExit("No usable financial report payload found")


if __name__ == "__main__":
    main()
