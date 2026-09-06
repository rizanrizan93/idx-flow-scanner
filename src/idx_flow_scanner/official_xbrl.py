from __future__ import annotations

import io
import zipfile
from dataclasses import dataclass
from decimal import Decimal, InvalidOperation
from pathlib import PurePosixPath
from typing import Any

from defusedxml import ElementTree as SafeET
from defusedxml.common import DefusedXmlException

from .data import canonical_ticker

XBRLI = "http://www.xbrl.org/2003/instance"
XBRLDI = "http://xbrl.org/2006/xbrldi"
XSI = "http://www.w3.org/2001/XMLSchema-instance"
MAX_ZIP_BYTES = 25 * 1024 * 1024
MAX_UNCOMPRESSED_BYTES = 50 * 1024 * 1024
MAX_MEMBERS = 10_000

# Only explicit taxonomy concepts are accepted. EBITDA and broad debt aliases are
# intentionally absent until exact IDX taxonomy semantics are validated.
METRIC_SPECS: dict[str, dict[str, object]] = {
    "assets": {"concepts": ("Assets",), "period": "instant", "unit": "idr"},
    "liabilities": {"concepts": ("Liabilities",), "period": "instant", "unit": "idr"},
    "equity": {"concepts": ("Equity",), "period": "instant", "unit": "idr"},
    "cash_and_equivalents": {"concepts": ("CashAndCashEquivalents",), "period": "instant", "unit": "idr"},
    "revenue": {"concepts": ("Revenue", "SalesAndRevenue", "NetSales"), "period": "duration", "unit": "idr"},
    "gross_profit": {"concepts": ("GrossProfit",), "period": "duration", "unit": "idr"},
    "operating_profit": {"concepts": ("ProfitLossFromOperatingActivities", "OperatingProfitLoss"), "period": "duration", "unit": "idr"},
    "net_income_attributable": {"concepts": ("ProfitLossAttributableToOwnersOfParent",), "period": "duration", "unit": "idr"},
    "profit_loss": {"concepts": ("ProfitLoss",), "period": "duration", "unit": "idr"},
    "operating_cash_flow": {"concepts": ("CashFlowsFromUsedInOperatingActivities",), "period": "duration", "unit": "idr"},
    "capex": {"concepts": ("PaymentsToAcquirePropertyPlantAndEquipment",), "period": "duration", "unit": "idr"},
    "shares_outstanding": {"concepts": ("NumberOfSharesOutstanding",), "period": "instant", "unit": "shares"},
    "eps": {"concepts": ("BasicEarningsLossPerShare",), "period": "duration", "unit": "idr_per_share"},
}


def _local(tag: str) -> str:
    return str(tag).rsplit("}", 1)[-1]


def _namespace(tag: str) -> str:
    text = str(tag)
    return text[1:].split("}", 1)[0] if text.startswith("{") and "}" in text else ""


def _safe_zip(content: bytes) -> tuple[zipfile.ZipFile, list[zipfile.ZipInfo]]:
    data = bytes(content)
    if not data.startswith(b"PK"):
        raise ValueError("attachment is not a ZIP archive")
    if len(data) > MAX_ZIP_BYTES:
        raise ValueError("XBRL ZIP exceeds compressed-size limit")
    try:
        archive = zipfile.ZipFile(io.BytesIO(data))
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
        instant = start = end = identifier = identifier_scheme = None
        dimensions: list[dict[str, str | None]] = []
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
                identifier_scheme = child.get("scheme")
            elif local == "explicitMember":
                dimensions.append({"axis": child.get("dimension"), "member": text or None})
            elif local == "typedMember":
                dimensions.append({"axis": child.get("dimension"), "member": "".join(child.itertext()).strip() or None})
        result[str(context.get("id"))] = {
            "instant": instant,
            "start_date": start,
            "end_date": end,
            "identifier": identifier,
            "identifier_scheme": identifier_scheme,
            "dimensions": dimensions,
            # Consolidated/separate state is not inferred from absence of dimensions.
            "is_consolidated": None,
        }
    return result


def _measure_text(element: Any) -> list[str]:
    return [(c.text or "").strip() for c in element.iter() if _local(c.tag) == "measure" and (c.text or "").strip()]


def _units(root: Any) -> dict[str, str]:
    result: dict[str, str] = {}
    for unit in root:
        if _local(unit.tag) != "unit" or not unit.get("id"):
            continue
        divide = next((c for c in unit if _local(c.tag) == "divide"), None)
        if divide is None:
            measures = _measure_text(unit)
            rendered = "*".join(measures)
        else:
            numerator = next((c for c in divide if _local(c.tag) == "unitNumerator"), None)
            denominator = next((c for c in divide if _local(c.tag) == "unitDenominator"), None)
            rendered = f"{'*'.join(_measure_text(numerator))}/{'*'.join(_measure_text(denominator))}" if numerator is not None and denominator is not None else ""
        if rendered:
            result[str(unit.get("id"))] = rendered
    return result


def _decimal(raw: str | None) -> Decimal | None:
    if raw is None:
        return None
    try:
        value = Decimal(raw.strip())
    except (InvalidOperation, AttributeError):
        return None
    return value if value.is_finite() else None


def _unit_token(value: str | None) -> str:
    return str(value or "").upper().replace(" ", "")


def _unit_matches(unit: str | None, expected: str) -> bool:
    token = _unit_token(unit)
    if expected == "idr":
        return token == "IDR" or token.endswith(":IDR")
    if expected == "shares":
        return token in {"SHARES", "XBRLI:SHARES"} or token.endswith(":SHARES")
    if expected == "idr_per_share":
        if "/" not in token:
            return False
        numerator, denominator = token.split("/", 1)
        return (numerator == "IDR" or numerator.endswith(":IDR")) and (denominator == "SHARES" or denominator.endswith(":SHARES"))
    return False


@dataclass(frozen=True)
class XbrlFact:
    concept_namespace: str
    concept: str
    context_ref: str
    unit_ref: str | None
    unit: str | None
    decimals: str | None
    scale: int | None
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
        scale_raw = element.get("scale")
        try:
            scale = int(scale_raw) if scale_raw not in (None, "") else None
        except ValueError:
            scale = None
        numeric = _decimal(raw) if unit_ref else None
        if numeric is not None and scale:
            numeric *= Decimal(10) ** scale
        facts.append(
            XbrlFact(
                concept_namespace=_namespace(element.tag),
                concept=_local(element.tag),
                context_ref=str(context_ref),
                unit_ref=str(unit_ref) if unit_ref else None,
                unit=units.get(str(unit_ref)) if unit_ref else None,
                decimals=element.get("decimals"),
                scale=scale,
                value=numeric,
                raw_value=raw,
                context=contexts.get(str(context_ref)),
            )
        )
    return {"facts": facts, "contexts": contexts, "units": units}


def expected_report_end(report_year: int, report_period: str) -> str:
    period = str(report_period or "").upper()
    suffix = {"TW1": "03-31", "TW2": "06-30", "TW3": "09-30", "AUDIT": "12-31"}.get(period)
    if suffix is None:
        raise ValueError(f"unsupported report period: {report_period}")
    return f"{int(report_year):04d}-{suffix}"


def expected_report_start(report_year: int) -> str:
    return f"{int(report_year):04d}-01-01"


def _entity_codes(parsed: dict[str, object]) -> set[str]:
    codes: set[str] = set()
    for fact in parsed.get("facts") or []:
        if not isinstance(fact, XbrlFact) or fact.concept != "EntityCode" or not fact.raw_value:
            continue
        code = canonical_ticker(fact.raw_value)
        if code:
            codes.add(code)
    return codes


def validate_instance_identity(parsed: dict[str, object], expected_ticker: str | None = None) -> str | None:
    contexts = parsed.get("contexts") or {}
    identifiers = {
        str(ctx.get("identifier") or "").strip()
        for ctx in contexts.values()
        if isinstance(ctx, dict) and str(ctx.get("identifier") or "").strip()
    }
    if len(identifiers) > 1:
        raise ValueError("XBRL contains multiple context entity identifiers")
    identifier = next(iter(identifiers), None)

    entity_codes = _entity_codes(parsed)
    if len(entity_codes) > 1:
        raise ValueError(f"XBRL contains multiple EntityCode values: {sorted(entity_codes)}")
    entity_code = next(iter(entity_codes), None)
    if expected_ticker:
        expected = canonical_ticker(expected_ticker)
        if not entity_code:
            raise ValueError("XBRL EntityCode missing; ticker identity cannot be verified")
        if entity_code != expected:
            raise ValueError(f"XBRL EntityCode mismatch: expected {expected}, got {entity_code}")
    return identifier


def _eligible_fact(fact: XbrlFact, *, period_kind: str, report_year: int, report_period: str, unit_kind: str) -> bool:
    ctx = fact.context or {}
    if ctx.get("dimensions"):
        return False
    if not fact.concept_namespace or not _unit_matches(fact.unit, unit_kind):
        return False
    report_end = expected_report_end(report_year, report_period)
    if period_kind == "instant":
        return ctx.get("instant") == report_end
    return ctx.get("start_date") == expected_report_start(report_year) and ctx.get("end_date") == report_end


def standardized_metric_rows(
    content: bytes,
    *,
    expected_ticker: str | None,
    report_year: int,
    report_period: str,
) -> tuple[list[dict[str, object]], dict[str, object]]:
    parsed = parse_instance_zip(content)
    entity_identifier = validate_instance_identity(parsed, expected_ticker)
    entity_code = next(iter(_entity_codes(parsed)), None)
    facts: list[XbrlFact] = list(parsed["facts"])
    rows: list[dict[str, object]] = []
    for metric_name, spec in METRIC_SPECS.items():
        concepts = tuple(spec["concepts"])
        candidates = [
            fact for fact in facts
            if fact.concept in concepts
            and fact.value is not None
            and _eligible_fact(
                fact,
                period_kind=str(spec["period"]),
                report_year=report_year,
                report_period=report_period,
                unit_kind=str(spec["unit"]),
            )
        ]
        if not candidates:
            continue
        selected: XbrlFact | None = None
        for concept in concepts:
            same = [f for f in candidates if f.concept == concept]
            values = {f.value for f in same}
            if len(values) == 1 and same:
                selected = same[0]
                break
            if len(values) > 1:
                selected = None
                break
        if selected is None:
            continue
        rows.append(
            {
                "metric_name": metric_name,
                "metric_value": selected.value,
                "unit": selected.unit or "",
                "source_concept_namespace": selected.concept_namespace,
                "source_concept_local_name": selected.concept,
                "source_context_id": selected.context_ref,
                "report_end_date": expected_report_end(report_year, report_period),
                "derivation_state": "DIRECT_EXACT_CONCEPT_CONTEXT_UNIT",
                "taxonomy_state": "IDX_XBRL_INSTANCE_TAXONOMY_OBSERVED",
            }
        )
    metadata = {
        "entity_identifier": entity_identifier,
        "entity_code": entity_code,
        "fact_count": len(facts),
        "context_count": len(parsed.get("contexts") or {}),
        "metric_validation_state": "VALIDATED_CONTEXT_UNIT_PERIOD_CONCEPT" if rows else "UNAVAILABLE_NO_HIGH_CONFIDENCE_MAPPING",
    }
    return rows, metadata


def standardized_metrics(
    content: bytes,
    *,
    expected_ticker: str | None = None,
    report_year: int | None = None,
    report_period: str | None = None,
) -> dict[str, object]:
    if report_year is None or report_period is None:
        parsed = parse_instance_zip(content)
        validate_instance_identity(parsed, expected_ticker)
        ends = sorted({
            str(ctx.get("instant") or ctx.get("end_date") or "")
            for ctx in (parsed.get("contexts") or {}).values()
            if isinstance(ctx, dict) and not ctx.get("dimensions") and (ctx.get("instant") or ctx.get("end_date"))
        })
        if not ends:
            return {"metric_validation_state": "UNAVAILABLE_NO_REPORT_PERIOD"}
        latest = ends[-1]
        year = int(latest[:4])
        month_day = latest[5:]
        period = {"03-31": "TW1", "06-30": "TW2", "09-30": "TW3", "12-31": "AUDIT"}.get(month_day)
        if period is None:
            return {"metric_validation_state": "UNAVAILABLE_NONSTANDARD_REPORT_PERIOD", "report_end_date": latest}
        report_year, report_period = year, period
    rows, metadata = standardized_metric_rows(
        content,
        expected_ticker=expected_ticker,
        report_year=int(report_year),
        report_period=str(report_period),
    )
    out: dict[str, object] = {
        "report_end_date": expected_report_end(int(report_year), str(report_period)),
        **metadata,
    }
    for row in rows:
        out[str(row["metric_name"])] = float(row["metric_value"])
    return out


def raw_fact_rows(parsed: dict[str, object]) -> list[dict[str, object]]:
    rows: list[dict[str, object]] = []
    for fact in parsed.get("facts") or []:
        if not isinstance(fact, XbrlFact):
            continue
        ctx = fact.context or {}
        rows.append(
            {
                "concept_namespace": fact.concept_namespace,
                "concept_local_name": fact.concept,
                "context_id": fact.context_ref,
                "entity_identifier": ctx.get("identifier"),
                "period_start": ctx.get("start_date"),
                "period_end": ctx.get("end_date"),
                "instant_date": ctx.get("instant"),
                "unit": fact.unit or "",
                "decimals": fact.decimals,
                "scale": fact.scale,
                "numeric_value": fact.value,
                "text_value": None if fact.value is not None else fact.raw_value,
                "is_consolidated": ctx.get("is_consolidated"),
                "dimensions": ctx.get("dimensions") or [],
            }
        )
    return rows


__all__ = [
    "XbrlFact",
    "METRIC_SPECS",
    "parse_instance_zip",
    "expected_report_end",
    "validate_instance_identity",
    "standardized_metric_rows",
    "standardized_metrics",
    "raw_fact_rows",
]
