from __future__ import annotations

import json
import re
from urllib.parse import urljoin

from bs4 import BeautifulSoup
from curl_cffi import requests

BASE = "https://block.idx.id"
PAGE = f"{BASE}/id/berita/pengumuman"
PROFILE = f"{BASE}/id/perusahaan-tercatat/profil-perusahaan-tercatat/AADI"


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


def collect_js(soup: BeautifulSoup, base: str) -> list[str]:
    urls: list[str] = []
    for tag in soup.find_all("script", src=True):
        url = urljoin(base, tag.get("src"))
        if url.endswith(".js") and url not in urls:
            urls.append(url)
    for tag in soup.find_all("link", href=True):
        href = urljoin(base, tag.get("href"))
        if href.endswith(".js") and href not in urls:
            urls.append(href)
    return urls


def scan_scripts(session, urls: list[str], referer: str, needles: tuple[str, ...]) -> list[dict[str, object]]:
    matches = []
    for src in urls[:180]:
        try:
            r = session.get(src, headers={"Referer": referer, "User-Agent": "Mozilla/5.0"}, timeout=40)
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
                snippets.append({"needle": needle, "snippet": text[max(0, idx - 900): idx + 2200]})
        matches.append({"src": src, "bytes": len(text), "snippets": snippets[:10]})
    return matches


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
        {"dateFrom": "2026-09-05", "dateTo": "2026-09-06"},
    ]
    base_html = ""
    for params in probes:
        r = s.get(PAGE, params=params, headers=headers, timeout=40)
        if not base_html and not params and r.status_code == 200:
            base_html = r.text
        print(json.dumps({"kind": "page_probe", "status": r.status_code, "url": r.url,
                          "summary": page_summary(r.text) if r.status_code == 200 else compact_text(r.text)}, ensure_ascii=False))

    if not base_html:
        return 1
    ann_soup = BeautifulSoup(base_html, "html.parser")
    ann_scripts = collect_js(ann_soup, PAGE)
    ann_matches = scan_scripts(s, ann_scripts, PAGE, (
        "GetAllAnnouncement", "pageNumber", "dateFrom", "dateTo", "NewsAnnouncement"
    ))
    print(json.dumps({"kind": "announcement_script_matches", "matches": ann_matches}, ensure_ascii=False))

    pr = s.get(PROFILE, headers=headers, timeout=40)
    print(json.dumps({"kind": "profile_probe", "status": pr.status_code, "url": pr.url,
                      "bytes": len(pr.content)}, ensure_ascii=False))
    if pr.status_code == 200:
        profile_soup = BeautifulSoup(pr.text, "html.parser")
        profile_scripts = collect_js(profile_soup, PROFILE)
        print(json.dumps({"kind": "profile_js_assets", "count": len(profile_scripts)}, ensure_ascii=False))
        profile_matches = scan_scripts(s, profile_scripts, PROFILE, (
            "GetFinancial", "FinancialReport", "FinancialStatement", "ListedCompanyFinancial",
            "Financial Report", "Laporan Keuangan", "/primary/ListedCompany"
        ))
        print(json.dumps({"kind": "financial_script_matches", "matches": profile_matches}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
