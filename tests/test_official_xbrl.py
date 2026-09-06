from __future__ import annotations

import io
import zipfile
from decimal import Decimal

import pytest

from idx_flow_scanner.official_xbrl import (
    parse_instance_zip,
    raw_fact_rows,
    standardized_metric_rows,
    standardized_metrics,
)


def _zip(xml: str, name: str = "instance.xbrl") -> bytes:
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w", zipfile.ZIP_DEFLATED) as archive:
        archive.writestr(name, xml)
    return buffer.getvalue()


def _xml(
    *,
    ticker: str = "TEST",
    context_identifier: str = "test_user",
    end: str = "2026-06-30",
    conflicting_assets: bool = False,
    include_entity_code: bool = True,
) -> str:
    extra = '<id:Assets contextRef="CurrentYearInstant" unitRef="IDR" decimals="-6">999</id:Assets>' if conflicting_assets else ""
    entity_code = f'<id:EntityCode contextRef="CurrentYearInstant">{ticker}</id:EntityCode>' if include_entity_code else ""
    return f'''<?xml version="1.0" encoding="UTF-8"?>
<xbrli:xbrl xmlns:xbrli="http://www.xbrl.org/2003/instance"
 xmlns:xbrldi="http://xbrl.org/2006/xbrldi"
 xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
 xmlns:iso4217="http://www.xbrl.org/2003/iso4217"
 xmlns:id="http://example.com/idx-taxonomy/2026">
 <xbrli:context id="CurrentYearInstant">
  <xbrli:entity><xbrli:identifier scheme="https://idx.co.id/entity">{context_identifier}</xbrli:identifier></xbrli:entity>
  <xbrli:period><xbrli:instant>{end}</xbrli:instant></xbrli:period>
 </xbrli:context>
 <xbrli:context id="CurrentYearDuration">
  <xbrli:entity><xbrli:identifier scheme="https://idx.co.id/entity">{context_identifier}</xbrli:identifier></xbrli:entity>
  <xbrli:period><xbrli:startDate>2026-01-01</xbrli:startDate><xbrli:endDate>{end}</xbrli:endDate></xbrli:period>
 </xbrli:context>
 <xbrli:context id="SegmentDuration">
  <xbrli:entity><xbrli:identifier scheme="https://idx.co.id/entity">{context_identifier}</xbrli:identifier>
   <xbrli:segment><xbrldi:explicitMember dimension="id:SegmentAxis">id:SegmentA</xbrldi:explicitMember></xbrli:segment>
  </xbrli:entity>
  <xbrli:period><xbrli:startDate>2026-01-01</xbrli:startDate><xbrli:endDate>{end}</xbrli:endDate></xbrli:period>
 </xbrli:context>
 <xbrli:unit id="IDR"><xbrli:measure>iso4217:IDR</xbrli:measure></xbrli:unit>
 {entity_code}
 <id:Assets contextRef="CurrentYearInstant" unitRef="IDR" decimals="-6">1000</id:Assets>
 {extra}
 <id:Liabilities contextRef="CurrentYearInstant" unitRef="IDR" decimals="-6">400</id:Liabilities>
 <id:Equity contextRef="CurrentYearInstant" unitRef="IDR" decimals="-6">600</id:Equity>
 <id:Revenue contextRef="CurrentYearDuration" unitRef="IDR" decimals="-6">800</id:Revenue>
 <id:Revenue contextRef="SegmentDuration" unitRef="IDR" decimals="-6">100</id:Revenue>
 <id:ProfitLossAttributableToOwnersOfParent contextRef="CurrentYearDuration" unitRef="IDR" decimals="-6">120</id:ProfitLossAttributableToOwnersOfParent>
 <id:CashFlowsFromUsedInOperatingActivities contextRef="CurrentYearDuration" unitRef="IDR" decimals="-6">150</id:CashFlowsFromUsedInOperatingActivities>
</xbrli:xbrl>'''


def test_exact_context_unit_period_mapping_and_raw_provenance_fields():
    content = _zip(_xml())
    rows, metadata = standardized_metric_rows(content, expected_ticker="TEST", report_year=2026, report_period="TW2")
    mapped = {row["metric_name"]: row for row in rows}
    assert metadata["metric_validation_state"] == "VALIDATED_CONTEXT_UNIT_PERIOD_CONCEPT"
    assert metadata["entity_code"] == "TEST"
    assert metadata["entity_identifier"] == "test_user"
    assert mapped["assets"]["metric_value"] == Decimal("1000")
    assert mapped["revenue"]["metric_value"] == Decimal("800")
    assert mapped["net_income_attributable"]["metric_value"] == Decimal("120")
    assert mapped["revenue"]["source_concept_namespace"] == "http://example.com/idx-taxonomy/2026"
    assert mapped["revenue"]["source_context_id"] == "CurrentYearDuration"
    parsed = parse_instance_zip(content)
    raw = raw_fact_rows(parsed)
    assert any(row["decimals"] == "-6" and row["concept_local_name"] == "Assets" for row in raw)
    assert any(row["dimensions"] for row in raw if row["context_id"] == "SegmentDuration")
    assert all(row["is_consolidated"] is None for row in raw)


def test_cross_ticker_contamination_is_rejected_from_entity_code():
    with pytest.raises(ValueError, match="EntityCode mismatch"):
        standardized_metric_rows(
            _zip(_xml(ticker="OTHER", context_identifier="test_user")),
            expected_ticker="TEST",
            report_year=2026,
            report_period="TW2",
        )


def test_missing_entity_code_is_fail_closed_when_ticker_validation_requested():
    with pytest.raises(ValueError, match="EntityCode missing"):
        standardized_metric_rows(
            _zip(_xml(include_entity_code=False)),
            expected_ticker="TEST",
            report_year=2026,
            report_period="TW2",
        )


def test_wrong_period_fails_neutral_without_reusing_tw2_facts():
    rows, metadata = standardized_metric_rows(_zip(_xml()), expected_ticker="TEST", report_year=2026, report_period="TW1")
    assert rows == []
    assert metadata["metric_validation_state"] == "UNAVAILABLE_NO_HIGH_CONFIDENCE_MAPPING"


def test_conflicting_duplicate_fact_is_not_standardized():
    rows, _ = standardized_metric_rows(_zip(_xml(conflicting_assets=True)), expected_ticker="TEST", report_year=2026, report_period="TW2")
    assert "assets" not in {row["metric_name"] for row in rows}


def test_zip_integrity_and_path_traversal_guards():
    with pytest.raises(ValueError):
        parse_instance_zip(b"not-a-zip")
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w") as archive:
        archive.writestr("../instance.xbrl", _xml())
    with pytest.raises(ValueError, match="unsafe ZIP member"):
        parse_instance_zip(buffer.getvalue())


def test_backward_flat_metrics_remain_available_for_cache_runtime():
    metrics = standardized_metrics(_zip(_xml()), expected_ticker="TEST", report_year=2026, report_period="TW2")
    assert metrics["assets"] == 1000.0
    assert metrics["revenue"] == 800.0
    assert metrics["report_end_date"] == "2026-06-30"
