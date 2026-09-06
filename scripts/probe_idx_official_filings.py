from __future__ import annotations

import hashlib
import json
import os
import time
from urllib.parse import urljoin, urlparse

from curl_cffi import requests

ZAPI = "https://api.zpi.web.id/v1/finance:idx"
IDX = "https://www.idx.co.id"


def _zapi(endpoint: str, params: dict[str, object], *, required: bool = True) -> dict:
    key = str(os.environ.get("ZAPI_KEY") or "").strip()
    if not key:
        raise SystemExit("ZAPI_KEY missing")
    last_status = None
    for attempt, delay in enumerate((0, 3, 8), start=1):
        if delay:
            time.sleep(delay)
        response = requests.get(
            f"{ZAPI}/{endpoint}",
            params=params,
            headers={"accept": "application/json", "x-api-key": key},
            impersonate="chrome",
            timeout=35,
        )
        last_status = response.status_code
        print("zapi", endpoint, "attempt=", attempt, "status=", response.status_code)
        if response.status_code == 200:
            payload = response.json()
            if not isinstance(payload, dict):
                break
            nested = payload.get("data")
            if isinstance(nested, dict) and any(k in nested for k in ("dataset", "provider", "recordsTotal", "items", "total")):
                payload = nested
            return payload
        if response.status_code not in {500, 502, 503, 504, 520, 521, 522, 523, 524}:
            print(response.text[:1000])
            break
    if required:
        raise SystemExit(f"ZAPI {endpoint} unavailable, last HTTP {last_status}")
    return {}


def _official_url(raw: str) -> str:
    value = str(raw or "").strip()
    url = value if value.startswith(("http://", "https://")) else urljoin(IDX + "/", value.lstrip("/"))
    host = (urlparse(url).hostname or "").lower()
    if not (host == "idx.co.id" or host.endswith(".idx.co.id")):
        raise SystemExit(f"non-IDX attachment host: {host}")
    return url


def _download_probe(url: str) -> dict[str, object]:
    response = requests.get(
        url,
        impersonate="chrome",
        timeout=20,
        allow_redirects=False,
        headers={"accept": "application/pdf,application/zip,application/octet-stream,*/*", "referer": "https://www.idx.co.id/"},
    )
    content = bytes(response.content)
    return {
        "url": url,
        "status": response.status_code,
        "content_type": response.headers.get("content-type"),
        "bytes": len(content),
        "sha256": hashlib.sha256(content).hexdigest() if response.status_code == 200 else None,
        "magic": content[:8].hex(),
    }


def _attachments(rows: list[dict]) -> list[dict]:
    output: list[dict] = []
    for row in rows:
        attachments = row.get("Attachments") or row.get("attachments") or []
        if isinstance(attachments, dict):
            attachments = [attachments]
        if isinstance(attachments, list):
            output.extend(item for item in attachments if isinstance(item, dict))
    return output


def main() -> None:
    financial_rows: list[dict] = []
    for year, period in ((2026, "tw2"), (2026, "tw1"), (2025, "audit"), (2025, "tw3")):
        payload = _zapi("financial-report", {"year": year, "period": period, "code": "BBCA", "length": 50, "start": 0})
        rows = payload.get("data") or payload.get("items") or []
        print("financial", year, period, "keys=", sorted(payload.keys()), "rows=", len(rows) if isinstance(rows, list) else -1)
        if isinstance(rows, list) and rows:
            financial_rows = [row for row in rows if isinstance(row, dict)]
            print("financial sample=", json.dumps(financial_rows[0], ensure_ascii=False, default=str)[:12000])
            break
    if not financial_rows:
        raise SystemExit("No usable financial-report discovery payload")

    atts = _attachments(financial_rows)
    print("financial attachment count=", len(atts))
    for item in atts[:8]:
        print("attachment meta=", json.dumps(item, ensure_ascii=False, default=str)[:4000])
        raw = item.get("File_Path") or item.get("url") or item.get("filePath") or ""
        if raw:
            print("financial official file=", json.dumps(_download_probe(_official_url(raw)), ensure_ascii=False))

    ann = _zapi("company-announcements", {"code": "BBCA", "length": 20, "start": 0, "locale": "id"}, required=False)
    ann_rows = ann.get("data") or ann.get("items") or []
    print("announcement keys=", sorted(ann.keys()))
    print("announcement rows=", len(ann_rows) if isinstance(ann_rows, list) else -1)
    if isinstance(ann_rows, list) and ann_rows:
        print("announcement sample=", json.dumps(ann_rows[0], ensure_ascii=False, default=str)[:7000])
        for item in _attachments(ann_rows[:3])[:3]:
            raw = item.get("url") or item.get("File_Path") or item.get("filePath") or ""
            if raw:
                print("announcement official file=", json.dumps(_download_probe(_official_url(raw)), ensure_ascii=False))


if __name__ == "__main__":
    main()
