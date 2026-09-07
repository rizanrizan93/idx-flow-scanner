from __future__ import annotations

import json
import re
from urllib.parse import urljoin

from bs4 import BeautifulSoup
from curl_cffi import requests

BASE = "https://block.idx.id"
PAGE = f"{BASE}/id/berita/pengumuman"


def compact_text(value: str, limit: int = 1200) -> str:
    return " ".join((value or "").split())[:limit]


def page_summary(html: str) -> dict[str, object]:
    soup = BeautifulSoup(html, "html.parser")
    cards = soup.select("div.attach-card")
    first = compact_text(cards[0].get_text(" ", strip=True), 240) if cards else None
    last = compact_text(cards[-1].get_text(" ", strip=True), 240) if cards else None
    body = soup.get_text(" ", strip=True)
    total = None
    m = re.search(r"dari\s+(\d+)", body, flags=re.I)
    if m:
        total = int(m.group(1))
    return {"cards": len(cards), "first": first, "last": last, "total": total}


def main() -> int:
    s = requests.Session(impersonate="chrome")
    headers = {
        "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        "Accept-Language": "id-ID,id;q=0.9,en;q=0.8",
        "User-Agent": "Mozilla/5.0",
    }
    probes = [
        {},
        {"page": "2"},
        {"pageNumber": "2"},
        {"PageNumber": "2"},
        {"page": "10"},
        {"dateFrom": "2026-09-05", "dateTo": "2026-09-06"},
        {"DateFrom": "2026-09-05", "DateTo": "2026-09-06"},
        {"from": "2026-09-05", "to": "2026-09-06"},
        {"startDate": "2026-09-05", "endDate": "2026-09-06"},
    ]
    base_html = ""
    for params in probes:
        r = s.get(PAGE, params=params, headers=headers, timeout=40)
        if not base_html and not params and r.status_code == 200:
            base_html = r.text
        print(json.dumps({
            "kind": "page_probe",
            "status": r.status_code,
            "url": r.url,
            "summary": page_summary(r.text) if r.status_code == 200 else compact_text(r.text),
        }, ensure_ascii=False))

    if not base_html:
        return 1
    soup = BeautifulSoup(base_html, "html.parser")
    scripts = []
    for tag in soup.find_all("script", src=True):
        src = urljoin(PAGE, tag.get("src"))
        if src not in scripts:
            scripts.append(src)
    print(json.dumps({"kind": "scripts", "count": len(scripts), "urls": scripts}, ensure_ascii=False))

    needles = (
        "GetAllAnnouncement",
        "pageNumber",
        "dateFrom",
        "dateTo",
        "announcement",
        "NewsAnnouncement",
    )
    matches = []
    for src in scripts:
        try:
            r = s.get(src, headers={"Referer": PAGE, "User-Agent": "Mozilla/5.0"}, timeout=40)
        except Exception:
            continue
        if r.status_code != 200:
            continue
        text = r.text
        low = text.lower()
        if not any(n.lower() in low for n in needles):
            continue
        snippets = []
        for needle in needles:
            idx = low.find(needle.lower())
            if idx >= 0:
                snippets.append({"needle": needle, "snippet": text[max(0, idx - 800): idx + 1800]})
        matches.append({"src": src, "bytes": len(text), "snippets": snippets[:8]})
    print(json.dumps({"kind": "script_matches", "matches": matches}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
