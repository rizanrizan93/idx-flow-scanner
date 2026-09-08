from __future__ import annotations

import json
from io import BytesIO
from zipfile import ZipFile
import xml.etree.ElementTree as ET

from openpyxl import load_workbook

from idx_flow_scanner.providers.block_idx_evidence import download_official_idx_attachment
from idx_flow_scanner.providers.block_idx_financial_history import (
    fetch_financial_report_market,
    parse_financial_report_payload,
)

XBRLI = "http://www.xbrl.org/2003/instance"
XBRLDI = "http://xbrl.org/2006/xbrldi"


def clean(value: object) -> object:
    if value is None or isinstance(value, (int, float, bool)):
        return value
    text = str(value).replace("\n", " ").strip()
    return text[:220]


def local_name(tag: str) -> str:
    return tag.rsplit("}", 1)[-1] if "}" in tag else tag


def namespace_uri(tag: str) -> str | None:
    if tag.startswith("{") and "}" in tag:
        return tag[1:].split("}", 1)[0]
    return None


def inspect_xbrl_zip(data: bytes) -> dict[str, object]:
    with ZipFile(BytesIO(data)) as archive:
        members = archive.namelist()
        xml_members = [
            name for name in members
            if name.lower().endswith((".xml", ".xbrl"))
            and not name.lower().endswith(("_cal.xml", "_def.xml", "_lab.xml", "_pre.xml"))
        ]
        if not xml_members:
            xml_members = [name for name in members if name.lower().endswith((".xml", ".xbrl"))]
        if not xml_members:
            return {"members": members[:50], "error": "NO_XML_MEMBER"}
        member = min(xml_members, key=lambda value: (len(value), value))
        xml_bytes = archive.read(member)

    root = ET.fromstring(xml_bytes)
    contexts: list[dict[str, object]] = []
    for ctx in root.findall(f"{{{XBRLI}}}context")[:30]:
        period = ctx.find(f"{{{XBRLI}}}period")
        start = period.findtext(f"{{{XBRLI}}}startDate") if period is not None else None
        end = period.findtext(f"{{{XBRLI}}}endDate") if period is not None else None
        instant = period.findtext(f"{{{XBRLI}}}instant") if period is not None else None
        dims: list[dict[str, object]] = []
        for member_node in ctx.findall(f".//{{{XBRLDI}}}explicitMember"):
            dims.append({
                "dimension": member_node.attrib.get("dimension"),
                "member": clean(member_node.text),
            })
        for member_node in ctx.findall(f".//{{{XBRLDI}}}typedMember"):
            dims.append({
                "dimension": member_node.attrib.get("dimension"),
                "member": "TYPED",
            })
        contexts.append({
            "id": ctx.attrib.get("id"),
            "start": start,
            "end": end,
            "instant": instant,
            "dimensions": dims,
        })

    units: list[dict[str, object]] = []
    for unit in root.findall(f"{{{XBRLI}}}unit")[:30]:
        measures = [clean(node.text) for node in unit.findall(f".//{{{XBRLI}}}measure")]
        units.append({"id": unit.attrib.get("id"), "measures": measures})

    facts: list[dict[str, object]] = []
    concept_counts: dict[str, int] = {}
    for child in list(root):
        context_ref = child.attrib.get("contextRef")
        if not context_ref:
            continue
        concept = local_name(child.tag)
        uri = namespace_uri(child.tag)
        concept_counts[concept] = concept_counts.get(concept, 0) + 1
        if len(facts) < 80:
            facts.append({
                "concept": concept,
                "namespace": uri,
                "contextRef": context_ref,
                "unitRef": child.attrib.get("unitRef"),
                "decimals": child.attrib.get("decimals"),
                "precision": child.attrib.get("precision"),
                "scale": child.attrib.get("scale"),
                "nil": child.attrib.get("{http://www.w3.org/2001/XMLSchema-instance}nil"),
                "value": clean(child.text),
            })

    return {
        "members": members[:80],
        "instance_member": member,
        "instance_bytes": len(xml_bytes),
        "root_tag": root.tag,
        "contexts": contexts,
        "units": units,
        "fact_count": sum(concept_counts.values()),
        "distinct_concepts": len(concept_counts),
        "top_concepts": sorted(concept_counts.items(), key=lambda item: (-item[1], item[0]))[:50],
        "facts": facts,
    }


def main() -> None:
    payload = fetch_financial_report_market(2026, "TW2", ticker="BSSR")
    reports = parse_financial_report_payload(payload)
    report = next(r for r in reports if r["ticker"] == "BSSR")

    xlsx_attachment = next(
        a for a in report["attachments"]
        if str(a["file_name"]).lower().endswith(".xlsx")
    )
    xlsx_data, xlsx_digest, xlsx_content_type = download_official_idx_attachment(
        str(xlsx_attachment["file_url"])
    )
    wb = load_workbook(BytesIO(xlsx_data), read_only=True, data_only=False)
    telemetry: dict[str, object] = {
        "ticker": "BSSR",
        "report": {
            k: report[k]
            for k in ("report_year", "report_period", "report_period_end", "file_modified_at")
        },
        "xlsx": {
            "file_name": xlsx_attachment["file_name"],
            "sha256": xlsx_digest,
            "bytes": len(xlsx_data),
            "content_type": xlsx_content_type,
            "sheets": [],
        },
    }
    sheets: list[dict[str, object]] = []
    for ws in wb.worksheets:
        sample: list[list[object]] = []
        nonempty = 0
        for row in ws.iter_rows(
            min_row=1,
            max_row=min(ws.max_row, 24),
            min_col=1,
            max_col=min(ws.max_column, 10),
            values_only=True,
        ):
            values = [clean(v) for v in row]
            if any(v not in (None, "") for v in values):
                sample.append(values)
                nonempty += 1
            if nonempty >= 12:
                break
        sheets.append({
            "title": ws.title,
            "max_row": ws.max_row,
            "max_column": ws.max_column,
            "sample": sample,
        })
    telemetry["xlsx"]["sheets"] = sheets

    instance_attachment = next(
        a for a in report["attachments"]
        if "instance" in str(a["file_name"]).lower()
        and str(a["file_name"]).lower().endswith(".zip")
    )
    instance_data, instance_digest, instance_content_type = download_official_idx_attachment(
        str(instance_attachment["file_url"])
    )
    telemetry["xbrl_instance"] = {
        "file_name": instance_attachment["file_name"],
        "sha256": instance_digest,
        "bytes": len(instance_data),
        "content_type": instance_content_type,
        **inspect_xbrl_zip(instance_data),
    }
    print(json.dumps(telemetry, ensure_ascii=False, indent=2, default=str))


if __name__ == "__main__":
    main()
