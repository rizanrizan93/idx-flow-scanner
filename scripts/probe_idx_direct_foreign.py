from __future__ import annotations

from curl_cffi import requests

DATE = "2026-09-04"
URLS = [
    "https://www.idx.co.id/primary/TradingSummary/GetStockSummary",
    "https://www.idx.co.id/umbraco/Surface/TradingSummary/GetStockSummary",
]
HEADERS = {
    "Accept": "application/json, text/javascript, */*; q=0.01",
    "Accept-Language": "en-US,en;q=0.9,id;q=0.8",
    "Referer": "https://www.idx.co.id/primary/TradingSummary",
    "Origin": "https://www.idx.co.id",
    "X-Requested-With": "XMLHttpRequest",
}

for url in URLS:
    try:
        r = requests.get(
            url,
            params={"length": 9999, "start": 0, "date": DATE},
            headers=HEADERS,
            impersonate="chrome",
            timeout=45,
        )
        print("URL", url)
        print("STATUS", r.status_code, "TYPE", r.headers.get("content-type"), "BYTES", len(r.content))
        if r.status_code != 200:
            print("BODY", r.text[:500].replace("\n", " "))
            continue
        payload = r.json()
        rows = payload.get("data") if isinstance(payload, dict) else None
        if rows is None and isinstance(payload, dict):
            rows = payload.get("Items")
        rows = rows if isinstance(rows, list) else []
        print("KEYS", sorted(payload.keys()) if isinstance(payload, dict) else type(payload).__name__)
        print("ROWS", len(rows))
        samples = [x for x in rows if isinstance(x, dict) and str(x.get("StockCode") or x.get("Code") or "").upper() in {"BBCA","BBRI","BMRI","TLKM","ANTM"}]
        for x in samples[:5]:
            print("SAMPLE", {
                "StockCode": x.get("StockCode") or x.get("Code"),
                "Date": x.get("Date"),
                "ForeignBuy": x.get("ForeignBuy"),
                "ForeignSell": x.get("ForeignSell"),
                "Volume": x.get("Volume"),
                "Value": x.get("Value"),
            })
    except Exception as exc:
        print("ERROR", url, type(exc).__name__, str(exc))
