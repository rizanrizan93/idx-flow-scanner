from __future__ import annotations

import hashlib
import re
from html import unescape
from urllib.parse import urljoin, urlparse

from curl_cffi import requests

MIRROR = "https://idx.sahamidx.com/lk/?k=tw2&y=2026"
IDX = "https://www.idx.co.id"


def _official_url(raw: str) -> str:
    value = unescape(str(raw or "").strip())
    url = value if value.startswith(("http://", "https://")) else urljoin(IDX + "/", value.lstrip("/"))
    host = (urlparse(url).hostname or "").lower()
    if not (host == "idx.co.id" or host.endswith(".idx.co.id")):
        raise ValueError(f"non-IDX attachment host: {host}")
    return url


def _download_probe(url: str) -> dict[str, object]:
    response = requests.get(
        url,
        impersonate="chrome",
        timeout=25,
        allow_redirects=False,
        headers={
            "accept": "application/zip,application/vnd.openxmlformats-officedocument.spreadsheetml.sheet,application/pdf,application/octet-stream,*/*",
            "referer": "https://www.idx.co.id/",
        },
    )
    content = bytes(response.content)
    return {
        "status": response.status_code,
        "content_type": response.headers.get("content-type"),
        "bytes": len(content),
        "sha256": hashlib.sha256(content).hexdigest() if response.status_code == 200 else None,
        "magic": content[:8].hex(),
    }


def main() -> None:
    response = requests.get(MIRROR, impersonate="chrome", timeout=30)
    print("mirror status=", response.status_code, "bytes=", len(response.content))
    if response.status_code != 200:
        raise SystemExit(f"mirror HTTP {response.status_code}")
    html = response.text
    print("contains 2026=", "2026" in html, "contains inlineXBRL=", "inlineXBRL" in html, "contains instance.zip=", "instance.zip" in html)

    rows = re.findall(r"<tr\b[^>]*>(.*?)</tr>", html, flags=re.I | re.S)
    candidates: list[tuple[str, str, str]] = []
    for row in rows:
        text = re.sub(r"<[^>]+>", " ", row)
        text = re.sub(r"\s+", " ", unescape(text)).strip()
        if "2026" not in text:
            continue
        ticker_match = re.search(r"\b([A-Z]{4})\b", text)
        ticker = ticker_match.group(1) if ticker_match else ""
        for href, label in re.findall(r'<a\b[^>]*href=["\']([^"\']+)["\'][^>]*>(.*?)</a>', row, flags=re.I | re.S):
            label_text = re.sub(r"<[^>]+>", " ", label)
            label_text = re.sub(r"\s+", " ", unescape(label_text)).strip()
            if "idx.co.id" not in href.lower():
                continue
            if not any(token in label_text.lower() for token in ("instance.zip", "inlinexbrl.zip", "financialstatement")):
                continue
            candidates.append((ticker, label_text, _official_url(href)))
    print("candidate official files=", len(candidates), "tickers=", len({c[0] for c in candidates if c[0]}))
    if not candidates:
        raise SystemExit("no 2026 official filing links discovered")

    tested = 0
    xbrl_success = 0
    for ticker, label, url in candidates:
        if tested >= 8:
            break
        if "zip" not in label.lower() and tested < 4:
            continue
        result = _download_probe(url)
        print("file", ticker, label, url, result)
        tested += 1
        if result["status"] == 200 and result["magic"].startswith("504b") and "zip" in label.lower():
            xbrl_success += 1
    print("tested=", tested, "verified_xbrl_zip=", xbrl_success)
    if xbrl_success <= 0:
        raise SystemExit("no official IDX XBRL zip could be verified")


if __name__ == "__main__":
    main()
