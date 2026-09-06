from __future__ import annotations

import io
import math
import zipfile
from dataclasses import dataclass
from decimal import Decimal, InvalidOperation
from pathlib import PurePosixPath
from typing import Any

from defusedxml import ElementTree as SafeET
from defusedxml.common import DefusedXmlException

XBRLI = "http://www.xbrl.org/2003/instance"
XBRLDI = "http://xbrl.org/2006/xbrldi"
XSI = "http://www.w3.org/2001/XMLSchema-instance"
MAX_ZIP_BYTES = 25 * 1024 * 1024
MAX_UNCOMPRESSED_BYTES = 50 * 1024 * 1024
MAX_MEMBERS = 10_000

BALANCE_ALIASES: dict[str, tuple[str, ...]] = {
    "assets": ("Assets",),
    "liabilities": ("Liabilities",),
    "equity": ("Equity",),
    "cash_and_equivalents": ("CashAndCashEquivalents",),
}
FLOW_ALIASES: dict[str, tuple[str, ...]] = {
    "revenue": ("Revenue", "SalesAndRevenue", "NetSales"),
    "profit_loss": ("ProfitLoss",),
    "operating_cash_flow": ("CashFlowsFromUsedInOperatingActivities",),
}


def _local(tag: str) -> str:
    return str(tag).rsplit("}", 1)[-1]


def _safe_zip(content: bytes) -> tuple[zipfile.ZipFile, list[zipfile.ZipInfo]]:
    if not isinstance(content, (bytes, bytearray)) or not bytes(content).startswith(b"PK"):
        raise ValueError("attachment is not a ZIP archive")
    if len(content) > MAX_ZIP_BYTES:
        raise ValueError("XBRL ZIP exceeds compressed-size limit")
    try:
        archive = zipfile.ZipFile(io.BytesIO(bytes(content)))
    except zipfile.BadZipFile as exc:
        raise ValueError("invalid XBRL ZIP") from exc
    members = archive.infolist()
    if len(members) > MAX_MEMBERS:
        archive.close()
        raise ValueError("XBRL ZIP contains too many members")
    total = 0
    for member in members:
        path = PurePosixPath(member.filename.replace("\\", "/"))
        if path.is_absolute() or ".." in path.parts:
            archive.close()
            raise ValueError(f"unsafe ZIP member: {member.filename}")
        total += int(member.file_size)
        if total > MAX_UNCOMPRESSED_BYTES:
            archive.close()
            raise ValueError("XBRL ZIP exceeds uncompressed-size limit")
    bad = archive.testzip()
    if bad:
        archive.close()
        raise ValueError(f"corrupt ZIP member: {bad}")
    return archive, members


def _contexts(root: Any) -> dict[str, dict[str, object]]:
    result: dict[str, dict[str, object]] = {}
    for context in root:
        if _local(context.tag) != "context" or not context.get("id"):
            continue
        instant = start = end = None
        dimensions: list[dict[str, str | None]] = []
        identifier = None
        for child in context.iter():
            local = _local(child.tag)
            text = (child.text or "").strip()
            if local == "instant":
                instant = text or None
            elif local == "startDate":
                start = text or None
            elif local == "endDate":
                end = text or None
            elif local == "identifier":
                identifier = text or None
            elif local == "explicitMember":
                dimensions.append({"axis": child.get("dimension"), "member": text or None})
            elif local == "typedMember":
                dimensions.append({"axis": child.get("dimension"), "member": "".join(child.itertext()).strip() or None})
        result[str(context.get("id"))] = {
            "instant": instant,
            "start_date": start,
            "end_date": end,
            "identifier": identifier,
            "dimensions": dimensions,
        }
    return result


def _units(root: Any) -> dict[str, tuple[str, ...]]:
    result: dict[str, tuple[str, ...]] = {}
    for unit in root:
        if _local(unit.tag) != "unit" or not unit.get("id"):
            continue
        measures = tuple(
            (child.text or "").strip()
            for child in unit.iter()
            if _local(child.tag) == "measure" and (child.text or "").strip()
        )
        result[str(unit.get("id"))] = measures
    return result


def _decimal(raw: str | None) -> Decimal | None:
    if raw is None:
        return None
    try:
        value = Decimal(raw.strip())
    except (InvalidOperation, AttributeError):
        return None
    return value if value.is_finite() else None


def _is_idr(unit: tuple[str, ...] | None) -> bool:
    if not unit or len(unit) != 1:
        return False
    token = unit[0].strip().upper()
    return token == "IDR" or token.endswith(":IDR")


@dataclass(frozen=True)
class XbrlFact:
    concept: str
    context_ref: str
    unit_ref: str | None
    unit: tuple[str, ...] | None
    value: Decimal | None
    raw_value: str | None
    context: dict[str, object] | None


def parse_instance_zip(content: bytes) -> dict[str, object]:
    archive, members = _safe_zip(content)
    try:
        instances = [m for m in members if PurePosixPath(m.filename.replace("\\", "/")).name.lower() == "instance.xbrl"]
        if len(instances) != 1:
            raise ValueError("XBRL ZIP must contain exactly one instance.xbrl")
        xml = archive.read(instances[0])
    finally:
        archive.close()
    try:
        root = SafeET.fromstring(xml)
    except (DefusedXmlException, SafeET.ParseError) as exc:
        raise ValueError(f"unsafe or invalid XBRL XML: {exc}") from exc

    contexts = _contexts(root)
    units = _units(root)
    facts: list[XbrlFact] = []
    for element in root:
        context_ref = element.get("contextRef")
        if not context_ref:
            continue
        nil = str(element.get(f"{{{XSI}}}nil", "")).lower() == "true"
        raw = None if nil else (element.text or "").strip()
        unit_ref = element.get("unitRef")
        facts.append(
            XbrlFact(
                concept=_local(element.tag),
                context_ref=str(context_ref),
                unit_ref=str(unit_ref) if unit_ref else None,
                unit=units.get(str(unit_ref)) if unit_ref else None,
                value=_decimal(raw) if unit_ref else None,
                raw_value=raw,
                context=contexts.get(str(context_ref)),
            )
        )
    return {"facts": facts, "contexts": contexts, "units": units}


def _choose_metric(
    facts: list[XbrlFact],
    aliases: tuple[str, ...],
    *,
    context_ref: str,
) -> Decimal | None:
    candidates = [
        fact for fact in facts
        if fact.concept in aliases
        and fact.context_ref == context_ref
        and fact.value is not None
        and _is_idr(fact.unit)
        and fact.context is not None
        and not list(fact.context.get("dimensions") or [])
    ]
    if not candidates:
        return None
    values = {fact.value for fact in candidates}
    if len(values) != 1:
        return None
    return next(iter(values))


def standardized_metrics(content: bytes) -> dict[str, object]:
    parsed = parse_instance_zip(content)
    facts = list(parsed["facts"])
    contexts = dict(parsed["contexts"])
    current_instant = contexts.get("CurrentYearInstant") or {}
    current_duration = contexts.get("CurrentYearDuration") or {}

    out: dict[str, object] = {
        "report_end_date": current_instant.get("instant") or current_duration.get("end_date"),
        "assets": None,
        "liabilities": None,
        "equity": None,
        "revenue": None,
        "profit_loss": None,
        "operating_cash_flow": None,
        "cash_and_equivalents": None,
        "metric_validation_state": "NO_VALIDATED_CORE_METRICS",
    }
    for key, aliases in BALANCE_ALIASES.items():
        value = _choose_metric(facts, aliases, context_ref="CurrentYearInstant")
        out[key] = float(value) if value is not None and math.isfinite(float(value)) else None
    for key, aliases in FLOW_ALIASES.items():
        value = _choose_metric(facts, aliases, context_ref="CurrentYearDuration")
        out[key] = float(value) if value is not None and math.isfinite(float(value)) else None

    core = (out["assets"], out["liabilities"], out["equity"])
    if all(value is not None for value in core):
        out["metric_validation_state"] = (
            "VALIDATED_CORE_AND_PROFIT"
            if out["profit_loss"] is not None
            else "VALIDATED_CORE_BALANCE"
        )
    return out


__all__ = [
    "MAX_ZIP_BYTES",
    "MAX_UNCOMPRESSED_BYTES",
    "MAX_MEMBERS",
    "XbrlFact",
    "parse_instance_zip",
    "standardized_metrics",
]
