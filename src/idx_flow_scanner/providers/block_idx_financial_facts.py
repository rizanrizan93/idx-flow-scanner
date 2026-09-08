from __future__ import annotations

import hashlib
import json
from datetime import date, datetime
from decimal import Decimal, InvalidOperation
from io import BytesIO
from typing import Any
from zipfile import BadZipFile, ZipFile
import xml.etree.ElementTree as ET

from idx_flow_scanner.providers.block_idx_evidence import is_official_idx_url

XBRLI = "http://www.xbrl.org/2003/instance"
XBRLDI = "http://xbrl.org/2006/xbrldi"
XSI = "http://www.w3.org/2001/XMLSchema-instance"

# Real 2026 IDX instance files currently bind the core taxonomy with http while
# IDX's published 2020 taxonomy documentation lists https. Treat these two URIs
# as the exact canonical namespace variants; extension namespaces are rejected.
IDX_CORE_NAMESPACES = frozenset(
    {
        "http://www.idx.co.id/xbrl/taxonomy/2020-01-01/cor",
        "https://www.idx.co.id/xbrl/taxonomy/2020-01-01/cor",
    }
)
MAX_XBRL_INSTANCE_BYTES = 64 * 1024 * 1024

# Exact core concepts observed in official IDX 2020-taxonomy instance files.
# The catalog deliberately maps only semantically equivalent concepts. Sector-
# specific top lines stay separate (e.g. bank interest/sharia income is never
# aliased to SalesAndRevenue). Missing evidence is preferable to false mapping.
METRIC_CATALOG: dict[str, dict[str, object]] = {
    "total_assets": {
        "label": "Total assets",
        "statement_type": "BALANCE_SHEET",
        "period_kind": "instant",
        "concepts": ("Assets",),
    },
    "current_assets": {
        "label": "Current assets",
        "statement_type": "BALANCE_SHEET",
        "period_kind": "instant",
        "concepts": ("CurrentAssets",),
    },
    "non_current_assets": {
        "label": "Non-current assets",
        "statement_type": "BALANCE_SHEET",
        "period_kind": "instant",
        "concepts": ("NonCurrentAssets",),
    },
    "total_liabilities": {
        "label": "Total liabilities",
        "statement_type": "BALANCE_SHEET",
        "period_kind": "instant",
        "concepts": ("Liabilities",),
    },
    "current_liabilities": {
        "label": "Current liabilities",
        "statement_type": "BALANCE_SHEET",
        "period_kind": "instant",
        "concepts": ("CurrentLiabilities",),
    },
    "non_current_liabilities": {
        "label": "Non-current liabilities",
        "statement_type": "BALANCE_SHEET",
        "period_kind": "instant",
        "concepts": ("NonCurrentLiabilities",),
    },
    "total_equity": {
        "label": "Total equity",
        "statement_type": "BALANCE_SHEET",
        "period_kind": "instant",
        "concepts": ("Equity",),
    },
    "equity_attributable_to_parent": {
        "label": "Equity attributable to owners of parent",
        "statement_type": "BALANCE_SHEET",
        "period_kind": "instant",
        "concepts": ("EquityAttributableToEquityOwnersOfParentEntity",),
    },
    "cash_and_cash_equivalents": {
        "label": "Cash and cash equivalents",
        "statement_type": "BALANCE_SHEET",
        "period_kind": "instant",
        "concepts": ("CashAndCashEquivalents", "CashAndCashEquivalentsCashFlows"),
    },
    "sales_and_revenue": {
        "label": "Sales and revenue",
        "statement_type": "INCOME_STATEMENT",
        "period_kind": "duration",
        "concepts": ("SalesAndRevenue",),
    },
    "interest_and_sharia_income": {
        "label": "Interest and sharia income",
        "statement_type": "INCOME_STATEMENT",
        "period_kind": "duration",
        "concepts": ("TotalInterestAndShariaIncome", "InterestIncome"),
    },
    "cost_of_sales_and_revenue": {
        "label": "Cost of sales and revenue",
        "statement_type": "INCOME_STATEMENT",
        "period_kind": "duration",
        "concepts": ("CostOfSalesAndRevenue",),
    },
    "gross_profit": {
        "label": "Gross profit",
        "statement_type": "INCOME_STATEMENT",
        "period_kind": "duration",
        "concepts": ("GrossProfit",),
    },
    "profit_before_income_tax": {
        "label": "Profit before income tax",
        "statement_type": "INCOME_STATEMENT",
        "period_kind": "duration",
        "concepts": ("ProfitLossBeforeIncomeTax",),
    },
    "profit_loss": {
        "label": "Profit or loss",
        "statement_type": "INCOME_STATEMENT",
        "period_kind": "duration",
        "concepts": ("ProfitLoss",),
    },
    "profit_attributable_to_parent": {
        "label": "Profit attributable to owners of parent",
        "statement_type": "INCOME_STATEMENT",
        "period_kind": "duration",
        "concepts": ("ProfitLossAttributableToParentEntity",),
    },
    "operating_cash_flow": {
        "label": "Net cash flow from operating activities",
        "statement_type": "CASH_FLOW_STATEMENT",
        "period_kind": "duration",
        "concepts": ("NetCashFlowsReceivedFromUsedInOperatingActivities",),
    },
    "investing_cash_flow": {
        "label": "Net cash flow from investing activities",
        "statement_type": "CASH_FLOW_STATEMENT",
        "period_kind": "duration",
        "concepts": ("NetCashFlowsReceivedFromUsedInInvestingActivities",),
    },
    "financing_cash_flow": {
        "label": "Net cash flow from financing activities",
        "statement_type": "CASH_FLOW_STATEMENT",
        "period_kind": "duration",
        "concepts": ("NetCashFlowsReceivedFromUsedInFinancingActivities",),
    },
}


def _catalog_json() -> str:
    return json.dumps(METRIC_CATALOG, sort_keys=True, separators=(",", ":"), ensure_ascii=True)


METRIC_CATALOG_SHA256 = hashlib.sha256(_catalog_json().encode("utf-8")).hexdigest()


def _local_name(tag: str) -> str:
    return tag.rsplit("}", 1)[-1] if "}" in tag else tag


def _namespace_uri(tag: str) -> str | None:
    if tag.startswith("{") and "}" in tag:
        return tag[1:].split("}", 1)[0]
    return None


def _parse_date(value: object) -> date:
    if isinstance(value, date) and not isinstance(value, datetime):
        return value
    return date.fromisoformat(str(value or "").strip()[:10])


def _parse_datetime(value: object) -> datetime:
    parsed = datetime.fromisoformat(str(value or "").strip())
    if parsed.tzinfo is None:
        raise ValueError("published_at must be timezone-aware")
    return parsed


def _instance_root(data: bytes) -> tuple[ET.Element, str]:
    try:
        with ZipFile(BytesIO(data)) as archive:
            candidates = [
                name
                for name in archive.namelist()
                if name.lower().endswith((".xml", ".xbrl"))
                and not name.lower().endswith(("_cal.xml", "_def.xml", "_lab.xml", "_pre.xml"))
            ]
            if not candidates:
                raise ValueError("NO_XBRL_INSTANCE")
            preferred = [
                name for name in candidates
                if name.rsplit("/", 1)[-1].lower() in {"instance.xbrl", "instance.xml"}
            ]
            if len(preferred) == 1:
                member = preferred[0]
            elif len(candidates) == 1:
                member = candidates[0]
            else:
                raise ValueError("AMBIGUOUS_XBRL_INSTANCE")
            info = archive.getinfo(member)
            if info.file_size <= 0 or info.file_size > MAX_XBRL_INSTANCE_BYTES:
                raise ValueError("XBRL_INSTANCE_SIZE_OUT_OF_BOUNDS")
            return ET.fromstring(archive.read(member)), member
    except BadZipFile as exc:
        raise ValueError("INVALID_XBRL_ZIP") from exc
    except ET.ParseError as exc:
        raise ValueError("INVALID_XBRL_XML") from exc


def _contexts(root: ET.Element) -> dict[str, dict[str, object]]:
    out: dict[str, dict[str, object]] = {}
    for ctx in root.findall(f"{{{XBRLI}}}context"):
        context_id = str(ctx.attrib.get("id") or "").strip()
        if not context_id:
            continue
        identifier = ctx.find(f"./{{{XBRLI}}}entity/{{{XBRLI}}}identifier")
        entity_identifier = str(identifier.text or "").strip() if identifier is not None else ""
        if not entity_identifier:
            continue
        dimensions = list(ctx.findall(f".//{{{XBRLDI}}}explicitMember")) + list(
            ctx.findall(f".//{{{XBRLDI}}}typedMember")
        )
        if dimensions:
            continue
        period = ctx.find(f"{{{XBRLI}}}period")
        if period is None:
            continue
        instant = period.findtext(f"{{{XBRLI}}}instant")
        start = period.findtext(f"{{{XBRLI}}}startDate")
        end = period.findtext(f"{{{XBRLI}}}endDate")
        base: dict[str, object] = {
            "entity_identifier": entity_identifier,
            "entity_scheme": str(identifier.attrib.get("scheme") or "").strip() if identifier is not None else "",
        }
        if instant:
            out[context_id] = {**base, "kind": "instant", "instant": _parse_date(instant)}
        elif start and end:
            out[context_id] = {
                **base,
                "kind": "duration",
                "start": _parse_date(start),
                "end": _parse_date(end),
            }
    return out


def _units(root: ET.Element) -> dict[str, tuple[str, ...]]:
    out: dict[str, tuple[str, ...]] = {}
    for unit in root.findall(f"{{{XBRLI}}}unit"):
        unit_id = str(unit.attrib.get("id") or "").strip()
        if not unit_id:
            continue
        measures = tuple(
            str(node.text or "").strip()
            for node in unit.findall(f".//{{{XBRLI}}}measure")
            if str(node.text or "").strip()
        )
        out[unit_id] = measures
    return out


def _currency_from_measures(measures: tuple[str, ...]) -> str | None:
    if len(measures) != 1:
        return None
    measure = measures[0]
    if ":" not in measure:
        return None
    prefix, currency = measure.split(":", 1)
    if prefix.lower() != "iso4217" or len(currency) != 3 or not currency.isalpha():
        return None
    return currency.upper()


def _decimal_text(node: ET.Element) -> str | None:
    if str(node.attrib.get(f"{{{XSI}}}nil") or "").strip().lower() in {"true", "1"}:
        return None
    raw = str(node.text or "").strip().replace(",", "")
    if not raw:
        return None
    try:
        value = Decimal(raw)
        scale = int(str(node.attrib.get("scale") or "0"))
        if scale:
            value *= Decimal(10) ** scale
        if str(node.attrib.get("sign") or "").strip() == "-":
            value = -value
    except (InvalidOperation, ValueError, OverflowError):
        return None
    if not value.is_finite():
        return None
    return format(value, "f")


def _validate_filing(filing: dict[str, object]) -> tuple[str, str, int, date]:
    filing_id = str(filing.get("filing_id") or "").strip()
    ticker = str(filing.get("ticker") or "").strip().upper()
    if not filing_id or not ticker:
        raise ValueError("filing_id and ticker are required")
    if filing.get("source_verified") is not True or filing.get("publication_time_verified") is not True:
        raise ValueError("filing source/publication time is not verified")
    if filing.get("point_in_time_eligible") is not True:
        raise ValueError("filing is not point-in-time eligible")
    file_url = str(filing.get("file_url") or "").strip()
    if not is_official_idx_url(file_url):
        raise ValueError("filing URL is not an official IDX URL")
    if str(filing.get("file_name") or "").strip().lower() != "instance.zip":
        raise ValueError("filing is not an instance.zip attachment")
    report_year = int(filing.get("report_year"))
    period_end = _parse_date(filing.get("report_period_end"))
    if period_end.year != report_year:
        raise ValueError("report year and period end disagree")
    published_at = _parse_datetime(filing.get("published_at"))
    if published_at.date() < period_end:
        raise ValueError("publication precedes report period end")
    return filing_id, ticker, report_year, period_end


def extract_financial_facts_from_xbrl_zip(
    data: bytes,
    filing: dict[str, object],
) -> tuple[list[dict[str, object]], dict[str, object]]:
    filing_id, ticker, report_year, report_period_end = _validate_filing(filing)
    root, member = _instance_root(data)
    contexts = _contexts(root)
    units = _units(root)
    expected_start = date(report_year, 1, 1)

    # row tuple: node, context_ref, context, value, currency, namespace
    concept_index: dict[str, list[tuple[ET.Element, str, dict[str, object], str, str, str]]] = {}
    accepted_nodes = 0
    rejected_nonmonetary = 0
    rejected_wrong_period = 0
    rejected_wrong_namespace = 0
    rejected_invalid_value = 0

    wanted = {
        str(concept)
        for config in METRIC_CATALOG.values()
        for concept in config["concepts"]
    }
    for node in root.iter():
        concept = _local_name(node.tag)
        if concept not in wanted:
            continue
        namespace = _namespace_uri(node.tag)
        if namespace not in IDX_CORE_NAMESPACES:
            rejected_wrong_namespace += 1
            continue
        context_ref = str(node.attrib.get("contextRef") or "").strip()
        context = contexts.get(context_ref)
        if context is None:
            rejected_wrong_period += 1
            continue
        if context["kind"] == "instant":
            if context.get("instant") != report_period_end:
                rejected_wrong_period += 1
                continue
        else:
            if context.get("start") != expected_start or context.get("end") != report_period_end:
                rejected_wrong_period += 1
                continue
        unit_ref = str(node.attrib.get("unitRef") or "").strip()
        measures = units.get(unit_ref, ())
        currency = _currency_from_measures(measures)
        if currency is None:
            rejected_nonmonetary += 1
            continue
        value = _decimal_text(node)
        if value is None:
            rejected_invalid_value += 1
            continue
        accepted_nodes += 1
        concept_index.setdefault(concept, []).append(
            (node, context_ref, context, value, currency, str(namespace))
        )

    pending: list[dict[str, object]] = []
    ambiguous_metrics: list[str] = []
    missing_metrics: list[str] = []
    equivalent_duplicate_nodes = 0

    for metric_key, config in METRIC_CATALOG.items():
        selected_concept: str | None = None
        selected: list[tuple[ET.Element, str, dict[str, object], str, str, str]] = []
        for concept in config["concepts"]:
            rows = concept_index.get(str(concept), [])
            kind_rows = [row for row in rows if row[2].get("kind") == config["period_kind"]]
            if kind_rows:
                selected_concept = str(concept)
                selected = kind_rows
                break
        if selected_concept is None:
            missing_metrics.append(metric_key)
            continue

        signatures = {
            (
                row[3],
                row[4],
                row[5],
                row[2].get("entity_identifier"),
                row[2].get("instant"),
                row[2].get("start"),
                row[2].get("end"),
            )
            for row in selected
        }
        if len(signatures) != 1:
            ambiguous_metrics.append(metric_key)
            continue
        if len(selected) > 1:
            equivalent_duplicate_nodes += len(selected) - 1
        _node, context_ref, context, value, currency, namespace = selected[0]
        pending.append(
            {
                "metric_key": metric_key,
                "config": config,
                "taxonomy_concept": selected_concept,
                "taxonomy_namespace": namespace,
                "context_ref": context_ref,
                "context": context,
                "metric_value": value,
                "currency": currency,
            }
        )

    currencies = sorted({str(row["currency"]) for row in pending})
    if len(currencies) > 1:
        raise ValueError(f"MIXED_REPORTING_CURRENCY:{','.join(currencies)}")
    entities = sorted({str(row["context"].get("entity_identifier") or "") for row in pending})
    if len(entities) > 1:
        raise ValueError("MIXED_CONTEXT_ENTITY")

    facts: list[dict[str, object]] = []
    content_hash = hashlib.sha256(data).hexdigest()
    for row in pending:
        metric_key = str(row["metric_key"])
        config = row["config"]
        context = row["context"]
        selected_concept = str(row["taxonomy_concept"])
        namespace = str(row["taxonomy_namespace"])
        currency = str(row["currency"])
        material = "|".join(
            (
                filing_id,
                metric_key,
                namespace,
                selected_concept,
                str(row["context_ref"]),
                currency,
                str(context.get("entity_identifier") or ""),
                str(context.get("instant") or ""),
                str(context.get("start") or ""),
                str(context.get("end") or ""),
            )
        )
        facts.append(
            {
                "fact_id": f"BLOCKIDX-FACT-{hashlib.sha256(material.encode('utf-8')).hexdigest()[:32]}",
                "filing_id": filing_id,
                "ticker": ticker,
                "metric_key": metric_key,
                "metric_label": config["label"],
                "taxonomy_concept": selected_concept,
                "taxonomy_namespace": namespace,
                "statement_type": config["statement_type"],
                "metric_value": str(row["metric_value"]),
                "unit": f"iso4217:{currency}",
                "currency": currency,
                "period_start": context.get("start").isoformat() if context.get("start") else None,
                "period_end": context.get("end").isoformat() if context.get("end") else None,
                "instant_date": context.get("instant").isoformat() if context.get("instant") else None,
                "fact_state": "PARSED_VALIDATED_EXACT_TAXONOMY",
                "source_verified": True,
                "point_in_time_eligible": True,
                "provenance_state": "OFFICIAL_IDX_XBRL_INSTANCE_POINT_IN_TIME_VERIFIED_V5",
            }
        )

    facts.sort(key=lambda item: str(item["metric_key"]))
    telemetry: dict[str, object] = {
        "filing_id": filing_id,
        "ticker": ticker,
        "instance_member": member,
        "content_hash": content_hash,
        "metric_catalog_sha256": METRIC_CATALOG_SHA256,
        "catalog_metrics": len(METRIC_CATALOG),
        "fact_rows": len(facts),
        "reporting_currency": currencies[0] if len(currencies) == 1 else None,
        "context_entity_identifier": entities[0] if len(entities) == 1 else None,
        "missing_metrics": missing_metrics,
        "ambiguous_metrics": ambiguous_metrics,
        "equivalent_duplicate_nodes": equivalent_duplicate_nodes,
        "accepted_candidate_nodes": accepted_nodes,
        "rejected_wrong_period": rejected_wrong_period,
        "rejected_wrong_namespace": rejected_wrong_namespace,
        "rejected_nonmonetary": rejected_nonmonetary,
        "rejected_invalid_value": rejected_invalid_value,
        "production_scoring_changed": False,
    }
    return facts, telemetry


__all__ = [
    "IDX_CORE_NAMESPACES",
    "METRIC_CATALOG",
    "METRIC_CATALOG_SHA256",
    "extract_financial_facts_from_xbrl_zip",
]
