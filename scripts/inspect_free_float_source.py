from __future__ import annotations

import re
from urllib.parse import urljoin

from curl_cffi import requests

BASE = "https://ff.klinikpenyesalan.com/"
HEADERS = {"User-Agent": "Mozilla/5.0", "Accept": "text/html,*/*"}

r = requests.get(BASE, headers=HEADERS, impersonate="chrome", timeout=40)
print("PAGE", r.status_code, len(r.content), r.headers.get("content-type"))
r.raise_for_status()
html = r.text
print(html[:2500])

assets = []
for match in re.findall(r'''(?:src|href)=["']([^"']+)["']''', html, flags=re.I):
    url = urljoin(BASE, match)
    if url not in assets:
        assets.append(url)

for url in assets:
    if not any(token in url.lower() for token in (".js", ".json", ".csv", "data", "asset", "static")):
        continue
    try:
        a = requests.get(url, headers=HEADERS, impersonate="chrome", timeout=40)
        print("ASSET", a.status_code, len(a.content), a.headers.get("content-type"), url)
        if a.status_code != 200:
            continue
        text = a.text
        needles = ["Peng-S-00011", "freeFloat", "free_float", "csv", "AADI", "956"]
        if any(n.lower() in text.lower() for n in needles):
            print("MATCH", url)
            for needle in needles:
                idx = text.lower().find(needle.lower())
                if idx >= 0:
                    print("NEEDLE", needle, text[max(0, idx-500):idx+1500])
    except Exception as exc:
        print("ERR", type(exc).__name__, url)
