from __future__ import annotations

import io
import zipfile
from pathlib import PurePosixPath
from urllib.parse import quote, urlencode, urljoin, urlsplit, urlunsplit
from xml.etree import ElementTree as ET

from curl_cffi import requests

BASE = "https://block.idx.id"
API = f"{BASE}/primary/ListedCompany"
TARGETS = ("Assets", "Liabilities", "Equity", "ProfitLoss", "ProfitLossAttributableToOwnersOfParent", "Revenue", "SalesAndRevenue", "NetSales", "CashAndCashEquivalents", "CashFlowsFromUsedInOperatingActivities")


def _url(path: str) -> str:
    parts = urlsplit(urljoin(BASE + "/", path.lstrip("/")))
    return urlunsplit((parts.scheme, parts.netloc, quote(parts.path, safe="/%:@-._~!$&'()*+,;="), parts.query, ""))


def _json(session, path, params):
    r = session.get(f"{API}/{path}?{urlencode(params)}", headers={"Accept":"application/json","Referer":BASE+"/"}, timeout=45)
    print(path, params.get("kodeEmiten"), r.status_code)
    r.raise_for_status()
    return r.json()


def _context_map(root):
    out = {}
    for e in root:
        if e.tag.rsplit("}",1)[-1] != "context" or not e.get("id"):
            continue
        instant = start = end = None
        dims = []
        for c in e.iter():
            local = c.tag.rsplit("}",1)[-1]
            if local == "instant": instant = (c.text or "").strip()
            elif local == "startDate": start = (c.text or "").strip()
            elif local == "endDate": end = (c.text or "").strip()
            elif local in {"explicitMember","typedMember"}: dims.append(local)
        out[e.get("id")] = {"instant":instant,"start":start,"end":end,"dims":dims}
    return out


def inspect_ticker(session, ticker):
    payload = _json(session,"GetFinancialReport",{"periode":"TW2","year":2026,"indexFrom":0,"pageSize":20,"reportType":"rdf","kodeEmiten":ticker})
    rows = payload.get("Results") or []
    if not rows:
        print(ticker,"NO REPORT"); return
    att = next((a for a in rows[0].get("Attachments",[]) if str(a.get("File_Name","")).lower()=="instance.zip"),None)
    if not att:
        print(ticker,"NO INSTANCE"); return
    r = session.get(_url(att["File_Path"]), headers={"Accept":"application/zip,*/*","Referer":BASE+"/"}, timeout=60)
    print(ticker,"zip",r.status_code,len(r.content),att.get("File_Size"))
    r.raise_for_status()
    with zipfile.ZipFile(io.BytesIO(bytes(r.content))) as z:
        name = next(n for n in z.namelist() if PurePosixPath(n).name.lower()=="instance.xbrl")
        xml = z.read(name)
    root = ET.fromstring(xml)
    contexts = _context_map(root)
    print("--",ticker,"--")
    for e in root:
        if e.get("contextRef") is None: continue
        local = e.tag.rsplit("}",1)[-1]
        if local in TARGETS or any(k in local for k in ("ProfitLoss","OperatingActivities","CashAndCashEquivalents","SalesAndRevenue")):
            print("FACT",local,e.get("contextRef"),e.get("unitRef"),(e.text or "").strip(),contexts.get(e.get("contextRef")))


def main():
    session = requests.Session(impersonate="chrome")
    for ticker in ("BBCA","ADRO","ICBP"):
        inspect_ticker(session,ticker)

if __name__ == "__main__":
    main()
