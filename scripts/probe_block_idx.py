from __future__ import annotations

import json
import re
from urllib.parse import urljoin

from bs4 import BeautifulSoup
from curl_cffi import requests

BASE = "https://block.idx.id"
PAGE = f"{BASE}/id/berita/pengumuman"
API = f"{BASE}/primary/NewsAnnouncement/GetAllAnnouncement"


def compact(value):
    if isinstance(value, dict):
        return {k: compact(v) for k, v in value.items() if k not in {"Content", "Description", "Body"}}
    if isinstance(value, list):
        return [compact(v) for v in value[:4]]
    if isinstance(value, str) and len(value) > 800:
        return value[:800] + "..."
    return value


def main() -> int:
    session = requests.Session(impersonate="chrome")
    page_headers = {
        "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        "Accept-Language": "id-ID,id;q=0.9,en;q=0.8",
        "User-Agent": "Mozilla/5.0",
    }
    response = session.get(PAGE, headers=page_headers, timeout=40)
    print(json.dumps({
        "page_status": response.status_code,
        "page_url": response.url,
        "page_bytes": len(response.content),
        "cookie_names": sorted(session.cookies.get_dict().keys()),
    }))
    response.raise_for_status()
    html = response.text

    soup = BeautifulSoup(html, "html.parser")
    official = soup.find("a", href=re.compile(r"idx\.co\.id/StaticData", re.I))
    if official is not None:
        chain = []
        node = official
        for depth in range(7):
            node = node.parent
            if node is None:
                break
            chain.append({
                "depth": depth + 1,
                "name": node.name,
                "classes": node.get("class"),
                "text": " ".join(node.get_text(" ", strip=True).split())[:1500],
                "html": str(node)[:4500],
            })
        print(json.dumps({"first_official_anchor": official.get("href"), "ancestor_chain": chain}, ensure_ascii=False))

    # Locate Nuxt hydration payload candidates without dumping the entire page.
    for script in soup.find_all("script"):
        text = script.string or script.get_text() or ""
        if "announcement" in text.lower() or "pengumuman" in text.lower() or "ItemCount" in text:
            cleaned = " ".join(text.split())
            if cleaned:
                print(json.dumps({"inline_script_id": script.get("id"), "inline_context": cleaned[:5000]}, ensure_ascii=False))
                break

    api_headers = {
        "Accept": "application/json,text/plain,*/*",
        "Accept-Language": "id-ID,id;q=0.9,en;q=0.8",
        "Referer": PAGE,
        "Origin": BASE,
        "X-Requested-With": "XMLHttpRequest",
        "User-Agent": "Mozilla/5.0",
    }
    probes = [
        {"keywords": "", "pageNumber": 1, "pageSize": 2, "dateFrom": "", "dateTo": "", "lang": "id"},
        {"keywords": "Penyampaian Laporan Keuangan", "pageNumber": 1, "pageSize": 3, "dateFrom": "2026-09-01", "dateTo": "2026-09-08", "lang": "id"},
    ]
    for params in probes:
        r = session.get(API, params=params, headers=api_headers, timeout=40)
        try:
            payload = r.json()
        except Exception:
            payload = None
        print(json.dumps({
            "api_status": r.status_code,
            "params": params,
            "content_type": r.headers.get("content-type"),
            "payload": compact(payload) if payload is not None else r.text[:1200],
        }, ensure_ascii=False, default=str))

    # Print all first-page official attachment URLs and their closest stable row text.
    rows = []
    for a in soup.find_all("a", href=True):
        href = urljoin(PAGE, a["href"])
        if "idx.co.id/StaticData" not in href:
            continue
        parent = a
        for _ in range(5):
            if parent.parent is None:
                break
            parent = parent.parent
            text = " ".join(parent.get_text(" ", strip=True).split())
            if len(text) >= 40:
                break
        rows.append({"href": href, "anchor_text": a.get_text(" ", strip=True), "container_text": text[:1200]})
    print(json.dumps({"attachment_rows": rows[:25]}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
