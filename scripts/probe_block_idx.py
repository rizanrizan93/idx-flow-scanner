from __future__ import annotations

import json
import re
from urllib.parse import urljoin, urlparse

from curl_cffi import requests

BASE = "https://block.idx.id"
PAGE = f"{BASE}/id/berita/pengumuman"
API = f"{BASE}/primary/NewsAnnouncement/GetAllAnnouncement"
HEADERS = {
    "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
    "Accept-Language": "id-ID,id;q=0.9,en;q=0.8",
    "User-Agent": "Mozilla/5.0",
    "Referer": PAGE,
}


def get(url: str, **kwargs):
    return requests.get(url, headers=HEADERS, impersonate="chrome", timeout=40, **kwargs)


def compact(value):
    if isinstance(value, dict):
        return {k: compact(v) for k, v in value.items() if k not in {"Content", "Description", "Body"}}
    if isinstance(value, list):
        return [compact(v) for v in value[:4]]
    if isinstance(value, str) and len(value) > 500:
        return value[:500] + "..."
    return value


def main() -> int:
    response = get(PAGE)
    print(json.dumps({"page_status": response.status_code, "page_url": response.url, "page_bytes": len(response.content)}))
    response.raise_for_status()
    html = response.text

    scripts = []
    for src in re.findall(r'<script[^>]+src=["\']([^"\']+)', html, flags=re.I):
        url = urljoin(PAGE, src)
        if url not in scripts:
            scripts.append(url)
    print(json.dumps({"script_count": len(scripts), "scripts": scripts[-20:]}, ensure_ascii=False))

    hrefs = [urljoin(PAGE, h) for h in re.findall(r'href=["\']([^"\']+)', html, flags=re.I)]
    idx_files = [h for h in hrefs if "StaticData" in h or "FinancialStatement" in h or "XBRL" in h]
    print(json.dumps({"official_attachment_examples": idx_files[:12]}, ensure_ascii=False))

    candidates: set[str] = set()
    needles = ("announcement", "pengumuman", "listedcompany", "financial", "disclosure", "api/", "umbraco", "pageNumber", "pageSize")
    for script_url in scripts[-30:]:
        parsed = urlparse(script_url)
        if parsed.netloc and parsed.netloc not in {"block.idx.id", "www.idx.co.id"}:
            continue
        try:
            r = get(script_url)
            if r.status_code != 200 or len(r.text) > 8_000_000:
                continue
            text = r.text
        except Exception as exc:
            print(json.dumps({"script_error": script_url, "error": type(exc).__name__}))
            continue
        lowered = text.lower()
        if not any(n.lower() in lowered for n in needles):
            continue
        for pat in (
            r'https?://[^"\'\s)]+',
            r'["\'](/[^"\']*(?:announcement|pengumuman|financial|disclosure|api)[^"\']*)["\']',
        ):
            for match in re.findall(pat, text, flags=re.I):
                value = match if isinstance(match, str) else match[0]
                if isinstance(value, str) and len(value) < 500:
                    candidates.add(value)
        for token in ("announcement", "pengumuman", "pageNumber", "pageSize"):
            pos = lowered.find(token.lower())
            if pos >= 0:
                snippet = re.sub(r"\s+", " ", text[max(0, pos-300):pos+700])
                print(json.dumps({"script": script_url, "token": token, "context": snippet[:1200]}, ensure_ascii=False))

    filtered = sorted(
        c for c in candidates
        if any(k in c.lower() for k in ("announcement", "pengumuman", "financial", "disclosure", "api", "listedcompany"))
    )
    print(json.dumps({"endpoint_candidates": filtered[:200]}, ensure_ascii=False, indent=2))

    probes = [
        {"keywords": "", "pageNumber": 1, "pageSize": 2, "dateFrom": "", "dateTo": "", "lang": "id"},
        {"keywords": "Penyampaian Laporan Keuangan", "pageNumber": 1, "pageSize": 3, "dateFrom": "2026-09-01", "dateTo": "2026-09-08", "lang": "id"},
        {"keywords": "Laporan Bulanan Registrasi Pemegang Efek", "pageNumber": 1, "pageSize": 2, "dateFrom": "2026-09-01", "dateTo": "2026-09-08", "lang": "id"},
        {"keywords": "", "pageNumber": 1, "pageSize": 1, "dateFrom": "2025-08-01", "dateTo": "2025-08-02", "lang": "id"},
    ]
    for params in probes:
        r = get(API, params=params)
        payload = None
        try:
            payload = r.json()
        except Exception:
            pass
        print(json.dumps({
            "api_status": r.status_code,
            "params": params,
            "content_type": r.headers.get("content-type"),
            "payload": compact(payload) if payload is not None else r.text[:1000],
        }, ensure_ascii=False, default=str))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
