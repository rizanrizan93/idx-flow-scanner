from __future__ import annotations

import io
import zipfile

from curl_cffi import requests

URL = "https://web.ksei.co.id/Download/BalanceposEfek20260731.zip"

r = requests.get(
    URL,
    headers={
        "Accept": "application/zip,application/octet-stream,*/*",
        "Referer": "https://web.ksei.co.id/archive_download/holding_composition",
        "User-Agent": "Mozilla/5.0",
    },
    impersonate="chrome",
    timeout=40,
)
print("status", r.status_code, "content-type", r.headers.get("content-type"), "bytes", len(r.content))
r.raise_for_status()
with zipfile.ZipFile(io.BytesIO(r.content)) as zf:
    print("files", zf.namelist())
    for info in zf.infolist():
        print("FILE", info.filename, "size", info.file_size)
        raw = zf.read(info.filename)[:4000]
        for enc in ("utf-8-sig", "utf-16", "latin-1"):
            try:
                text = raw.decode(enc)
                print("ENC", enc)
                print(text[:3000])
                break
            except Exception:
                pass
