from __future__ import annotations

import json
from io import BytesIO
from pathlib import Path
from zipfile import ZipFile
import xml.etree.ElementTree as ET

from idx_flow_scanner.providers.block_idx_evidence import download_official_idx_attachment
from idx_flow_scanner.providers.block_idx_financial_history import (
    fetch_financial_report_market,
    parse_financial_report_payload,
)

XBRLI = "http://www.xbrl.org/2003/instance"
XBRLDI = "http://xbrl.org/2006/xbrldi"
XSI = "http://www.w3.org/2001/XMLSchema-instance"
TICKERS = ("BSSR", "ICBP", "BBCA", "BSDE")
KEYWORDS = (
    "asset", "liabil", "equity", "revenue", "sales", "income", "profit", "loss",
    "cashandcash", "cashflow", "cashflows", "operatingactiv", "investingactiv",
    "financingactiv", "interestincome", "interestexpense", "deposit", "loan", "financing",
)
REPORT_PATH = Path("taxonomy_report.json")


def local_name(tag: str) -> str:
    return tag.rsplit("}", 1)[-1] if "}" in tag else tag


def namespace_uri(tag: str) -> str | None:
    if tag.startswith("{") and "}" in tag:
        return tag[1:].split("}", 1)[0]
    return None


def instance_root(data: bytes) -> tuple[ET.Element, str]:
    with ZipFile(BytesIO(data)) as archive:
        candidates = [
            name for name in archive.namelist()
            if name.lower().endswith((".xml", ".xbrl"))
            and not name.lower().endswith(("_cal.xml", "_def.xml", "_lab.xml", "_pre.xml"))
        ]
        if not candidates:
            raise ValueError("NO_XBRL_INSTANCE")
        member = min(candidates, key=lambda value: (len(value), value))
        return ET.fromstring(archive.read(member)), member


def context_map(root: ET.Element) -> dict[str, dict[str, object]]:
    out: dict[str, dict[str, object]] = {}
    for ctx in root.findall(f"{{{XBRLI}}}context"):
        period = ctx.find(f"{{{XBRLI}}}period")
        dims = list(ctx.findall(f".//{{{XBRLDI}}}explicitMember")) + list(
            ctx.findall(f".//{{{XBRLDI}}}typedMember")
        )
        out[str(ctx.attrib.get("id") or "")] = {
            "instant": period.findtext(f"{{{XBRLI}}}instant") if period is not None else None,
            "start": period.findtext(f"{{{XBRLI}}}startDate") if period is not None else None,
            "end": period.findtext(f"{{{XBRLI}}}endDate") if period is not None else None,
            "dimensions": len(dims),
        }
    return out


def unit_map(root: ET.Element) -> dict[str, list[str]]:
    out: dict[str, list[str]] = {}
    for unit in root.findall(f"{{{XBRLI}}}unit"):
        out[str(unit.attrib.get("id") or "")] = [
            str(node.text or "").strip()
            for node in unit.findall(f".//{{{XBRLI}}}measure")
            if str(node.text or "").strip()
        ]
    return out


def inspect_ticker(ticker: str) -> dict[str, object]:
    payload = fetch_financial_report_market(2026, "TW2", ticker=ticker)
    reports = parse_financial_report_payload(payload)
    report = next(r for r in reports if r["ticker"] == ticker)
    attachment = next(
        a for a in report["attachments"]
        if "instance" in str(a["file_name"]).lower()
        and str(a["file_name"]).lower().endswith(".zip")
    )
    data, digest, content_type = download_official_idx_attachment(str(attachment["file_url"]))
    root, member = instance_root(data)
    contexts = context_map(root)
    units = unit_map(root)

    current_contexts = {
        context_id: meta
        for context_id, meta in contexts.items()
        if int(meta["dimensions"] or 0) == 0
        and context_id in {"CurrentYearInstant", "CurrentYearDuration", "CurrentPeriodDuration"}
    }
    facts: list[dict[str, object]] = []
    seen: set[tuple[str, str, str | None]] = set()
    for node in list(root):
        context_ref = str(node.attrib.get("contextRef") or "")
        if context_ref not in current_contexts:
            continue
        concept = local_name(node.tag)
        if not any(keyword in concept.lower() for keyword in KEYWORDS):
            continue
        key = (concept, context_ref, node.attrib.get("unitRef"))
        if key in seen:
            continue
        seen.add(key)
        value = str(node.text or "").strip()
        facts.append(
            {
                "concept": concept,
                "namespace": namespace_uri(node.tag),
                "context": context_ref,
                "period": current_contexts[context_ref],
                "unitRef": node.attrib.get("unitRef"),
                "unit": units.get(str(node.attrib.get("unitRef") or ""), []),
                "decimals": node.attrib.get("decimals"),
                "scale": node.attrib.get("scale"),
                "nil": node.attrib.get(f"{{{XSI}}}nil"),
                "value": value[:100],
            }
        )
    facts.sort(key=lambda item: (str(item["context"]), str(item["concept"])))
    return {
        "ticker": ticker,
        "report_period_end": report["report_period_end"],
        "file_modified_at": report["file_modified_at"],
        "file_name": attachment["file_name"],
        "sha256": digest,
        "bytes": len(data),
        "content_type": content_type,
        "instance_member": member,
        "current_contexts": current_contexts,
        "units": units,
        "candidate_facts": facts,
    }


def main() -> None:
    output: list[dict[str, object]] = []
    for ticker in TICKERS:
        try:
            output.append(inspect_ticker(ticker))
        except Exception as exc:
            output.append({"ticker": ticker, "error": f"{type(exc).__name__}: {exc}"})
    rendered = json.dumps(output, ensure_ascii=False, indent=2, default=str)
    REPORT_PATH.write_text(rendered + "\n", encoding="utf-8")
    print(rendered)


if __name__ == "__main__":
    main()
