from __future__ import annotations

from io import BytesIO
from zipfile import ZIP_DEFLATED, ZipFile

import pytest

from idx_flow_scanner.providers.block_idx_financial_facts import (
    IDX_CORE_NAMESPACES,
    METRIC_CATALOG,
    METRIC_CATALOG_SHA256,
    extract_financial_facts_from_xbrl_zip,
)

CORE_NS = "http://www.idx.co.id/xbrl/taxonomy/2020-01-01/cor"


def _filing(**overrides: object) -> dict[str, object]:
    row: dict[str, object] = {
        "filing_id": "BLOCKIDX-FILING-test000000000000000000000001",
        "ticker": "TEST",
        "report_year": 2026,
        "report_period": "TW2",
        "report_period_end": "2026-06-30",
        "published_at": "2026-07-31T17:00:00+07:00",
        "file_url": "https://www.idx.co.id/StaticData/NewsAndAnnouncement/test/instance.zip",
        "file_name": "instance.zip",
        "source_verified": True,
        "publication_time_verified": True,
        "point_in_time_eligible": True,
    }
    row.update(overrides)
    return row


def _zip(xml: str, *, extra_instance: bool = False) -> bytes:
    output = BytesIO()
    with ZipFile(output, "w", ZIP_DEFLATED) as archive:
        archive.writestr("instance.xbrl", xml)
        if extra_instance:
            archive.writestr("instance.xml", xml)
        archive.writestr("instance_cal.xml", "<ignored/>")
    return output.getvalue()


def _instance_xml(
    *,
    cash_concept: str = "CashAndCashEquivalents",
    conflicting_assets: bool = False,
    namespace: str = CORE_NS,
    mixed_currency: bool = False,
    scale_profit: bool = False,
) -> str:
    second_assets = '<id:Assets contextRef="CurrentYearInstant" unitRef="IDR">101</id:Assets>' if conflicting_assets else ""
    gross_unit = "USD" if mixed_currency else "IDR"
    profit_attrs = ' scale="3" sign="-"' if scale_profit else ""
    return f'''<?xml version="1.0" encoding="UTF-8"?>
<xbrli:xbrl
    xmlns:xbrli="http://www.xbrl.org/2003/instance"
    xmlns:xbrldi="http://xbrl.org/2006/xbrldi"
    xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
    xmlns:id="{namespace}"
    xmlns:iso4217="http://www.xbrl.org/2003/iso4217">
  <xbrli:context id="CurrentYearInstant">
    <xbrli:entity><xbrli:identifier scheme="IDX">TEST</xbrli:identifier></xbrli:entity>
    <xbrli:period><xbrli:instant>2026-06-30</xbrli:instant></xbrli:period>
  </xbrli:context>
  <xbrli:context id="PriorYearInstant">
    <xbrli:entity><xbrli:identifier scheme="IDX">TEST</xbrli:identifier></xbrli:entity>
    <xbrli:period><xbrli:instant>2025-12-31</xbrli:instant></xbrli:period>
  </xbrli:context>
  <xbrli:context id="CurrentYearDuration">
    <xbrli:entity><xbrli:identifier scheme="IDX">TEST</xbrli:identifier></xbrli:entity>
    <xbrli:period><xbrli:startDate>2026-01-01</xbrli:startDate><xbrli:endDate>2026-06-30</xbrli:endDate></xbrli:period>
  </xbrli:context>
  <xbrli:context id="CurrentPeriodDuration">
    <xbrli:entity><xbrli:identifier scheme="IDX">TEST</xbrli:identifier></xbrli:entity>
    <xbrli:period><xbrli:startDate>2026-04-01</xbrli:startDate><xbrli:endDate>2026-06-30</xbrli:endDate></xbrli:period>
  </xbrli:context>
  <xbrli:context id="SegmentCurrent">
    <xbrli:entity>
      <xbrli:identifier scheme="IDX">TEST</xbrli:identifier>
      <xbrli:segment><xbrldi:explicitMember dimension="id:SegmentAxis">id:RetailMember</xbrldi:explicitMember></xbrli:segment>
    </xbrli:entity>
    <xbrli:period><xbrli:startDate>2026-01-01</xbrli:startDate><xbrli:endDate>2026-06-30</xbrli:endDate></xbrli:period>
  </xbrli:context>
  <xbrli:unit id="IDR"><xbrli:measure>iso4217:IDR</xbrli:measure></xbrli:unit>
  <xbrli:unit id="USD"><xbrli:measure>iso4217:USD</xbrli:measure></xbrli:unit>
  <xbrli:unit id="shares"><xbrli:measure>xbrli:shares</xbrli:measure></xbrli:unit>

  <id:Assets contextRef="CurrentYearInstant" unitRef="IDR">100</id:Assets>
  {second_assets}
  <id:Assets contextRef="PriorYearInstant" unitRef="IDR">90</id:Assets>
  <id:CurrentAssets contextRef="CurrentYearInstant" unitRef="IDR">70</id:CurrentAssets>
  <id:NonCurrentAssets contextRef="CurrentYearInstant" unitRef="IDR">30</id:NonCurrentAssets>
  <id:Liabilities contextRef="CurrentYearInstant" unitRef="IDR">40</id:Liabilities>
  <id:CurrentLiabilities contextRef="CurrentYearInstant" unitRef="IDR">25</id:CurrentLiabilities>
  <id:NonCurrentLiabilities contextRef="CurrentYearInstant" unitRef="IDR">15</id:NonCurrentLiabilities>
  <id:Equity contextRef="CurrentYearInstant" unitRef="IDR">60</id:Equity>
  <id:EquityAttributableToEquityOwnersOfParentEntity contextRef="CurrentYearInstant" unitRef="IDR">55</id:EquityAttributableToEquityOwnersOfParentEntity>
  <id:{cash_concept} contextRef="CurrentYearInstant" unitRef="IDR">10</id:{cash_concept}>

  <id:SalesAndRevenue contextRef="CurrentYearDuration" unitRef="IDR">80</id:SalesAndRevenue>
  <id:SalesAndRevenue contextRef="CurrentPeriodDuration" unitRef="IDR">45</id:SalesAndRevenue>
  <id:SalesAndRevenue contextRef="SegmentCurrent" unitRef="IDR">999</id:SalesAndRevenue>
  <id:CostOfSalesAndRevenue contextRef="CurrentYearDuration" unitRef="IDR">55</id:CostOfSalesAndRevenue>
  <id:GrossProfit contextRef="CurrentYearDuration" unitRef="{gross_unit}">25</id:GrossProfit>
  <id:ProfitLossBeforeIncomeTax contextRef="CurrentYearDuration" unitRef="IDR">11</id:ProfitLossBeforeIncomeTax>
  <id:ProfitLoss contextRef="CurrentYearDuration" unitRef="IDR"{profit_attrs}>8</id:ProfitLoss>
  <id:ProfitLossAttributableToParentEntity contextRef="CurrentYearDuration" unitRef="IDR">7</id:ProfitLossAttributableToParentEntity>
  <id:NetCashFlowsReceivedFromUsedInOperatingActivities contextRef="CurrentYearDuration" unitRef="IDR">13</id:NetCashFlowsReceivedFromUsedInOperatingActivities>
  <id:NetCashFlowsReceivedFromUsedInInvestingActivities contextRef="CurrentYearDuration" unitRef="IDR">-4</id:NetCashFlowsReceivedFromUsedInInvestingActivities>
  <id:NetCashFlowsReceivedFromUsedInFinancingActivities contextRef="CurrentYearDuration" unitRef="IDR">-3</id:NetCashFlowsReceivedFromUsedInFinancingActivities>
  <id:InterestIncome contextRef="CurrentYearDuration" unitRef="IDR" xsi:nil="true"/>
  <id:ProfitLoss contextRef="CurrentYearDuration" unitRef="shares">999</id:ProfitLoss>
</xbrli:xbrl>
'''


def test_exact_catalog_is_explicit_stable_and_namespaced() -> None:
    assert len(METRIC_CATALOG) == 19
    assert IDX_CORE_NAMESPACES == {
        "http://www.idx.co.id/xbrl/taxonomy/2020-01-01/cor",
        "https://www.idx.co.id/xbrl/taxonomy/2020-01-01/cor",
    }
    assert len(METRIC_CATALOG_SHA256) == 64
    assert METRIC_CATALOG["cash_and_cash_equivalents"]["concepts"] == (
        "CashAndCashEquivalents",
        "CashAndCashEquivalentsCashFlows",
    )
    assert METRIC_CATALOG["interest_and_sharia_income"]["concepts"] == (
        "TotalInterestAndShariaIncome",
        "InterestIncome",
    )


def test_parser_keeps_only_current_undimensioned_ytd_monetary_facts() -> None:
    facts, telemetry = extract_financial_facts_from_xbrl_zip(_zip(_instance_xml()), _filing())
    by_key = {row["metric_key"]: row for row in facts}

    assert by_key["total_assets"]["metric_value"] == "100"
    assert by_key["current_assets"]["metric_value"] == "70"
    assert by_key["current_liabilities"]["metric_value"] == "25"
    assert by_key["sales_and_revenue"]["metric_value"] == "80"
    assert by_key["cost_of_sales_and_revenue"]["metric_value"] == "55"
    assert by_key["profit_loss"]["metric_value"] == "8"
    assert by_key["operating_cash_flow"]["metric_value"] == "13"
    assert by_key["investing_cash_flow"]["metric_value"] == "-4"
    assert by_key["cash_and_cash_equivalents"]["instant_date"] == "2026-06-30"
    assert by_key["sales_and_revenue"]["period_start"] == "2026-01-01"
    assert by_key["sales_and_revenue"]["period_end"] == "2026-06-30"
    assert by_key["sales_and_revenue"]["unit"] == "iso4217:IDR"
    assert by_key["sales_and_revenue"]["currency"] == "IDR"
    assert by_key["sales_and_revenue"]["taxonomy_namespace"] == CORE_NS
    assert all(row["source_verified"] is True for row in facts)
    assert all(row["point_in_time_eligible"] is True for row in facts)
    assert telemetry["reporting_currency"] == "IDR"
    assert telemetry["context_entity_identifier"] == "TEST"
    assert telemetry["production_scoring_changed"] is False
    assert telemetry["ambiguous_metrics"] == []


def test_cash_alias_falls_back_to_cash_flow_taxonomy_for_bank_style_instance() -> None:
    facts, _ = extract_financial_facts_from_xbrl_zip(
        _zip(_instance_xml(cash_concept="CashAndCashEquivalentsCashFlows")),
        _filing(ticker="BANK"),
    )
    row = next(item for item in facts if item["metric_key"] == "cash_and_cash_equivalents")
    assert row["taxonomy_concept"] == "CashAndCashEquivalentsCashFlows"
    assert row["metric_value"] == "10"


def test_conflicting_same_priority_fact_fails_closed_for_metric() -> None:
    facts, telemetry = extract_financial_facts_from_xbrl_zip(
        _zip(_instance_xml(conflicting_assets=True)),
        _filing(),
    )
    assert "total_assets" not in {row["metric_key"] for row in facts}
    assert telemetry["ambiguous_metrics"] == ["total_assets"]


def test_extension_namespace_with_same_local_concept_is_rejected() -> None:
    facts, telemetry = extract_financial_facts_from_xbrl_zip(
        _zip(_instance_xml(namespace="https://issuer.example/extension/2026")),
        _filing(),
    )
    assert facts == []
    assert telemetry["rejected_wrong_namespace"] > 0


def test_mixed_reporting_currency_fails_closed_for_entire_filing() -> None:
    with pytest.raises(ValueError, match="MIXED_REPORTING_CURRENCY"):
        extract_financial_facts_from_xbrl_zip(
            _zip(_instance_xml(mixed_currency=True)),
            _filing(),
        )


def test_scale_and_sign_are_applied_before_persistence() -> None:
    facts, _ = extract_financial_facts_from_xbrl_zip(
        _zip(_instance_xml(scale_profit=True)),
        _filing(),
    )
    row = next(item for item in facts if item["metric_key"] == "profit_loss")
    assert row["metric_value"] == "-8000"


def test_ambiguous_primary_instance_members_fail_closed() -> None:
    with pytest.raises(ValueError, match="AMBIGUOUS_XBRL_INSTANCE"):
        extract_financial_facts_from_xbrl_zip(
            _zip(_instance_xml(), extra_instance=True),
            _filing(),
        )


def test_fact_ids_are_deterministic() -> None:
    data = _zip(_instance_xml())
    first, _ = extract_financial_facts_from_xbrl_zip(data, _filing())
    second, _ = extract_financial_facts_from_xbrl_zip(data, _filing())
    assert [row["fact_id"] for row in first] == [row["fact_id"] for row in second]


@pytest.mark.parametrize(
    "overrides",
    [
        {"source_verified": False},
        {"publication_time_verified": False},
        {"point_in_time_eligible": False},
        {"published_at": "2026-06-01T12:00:00+07:00"},
        {"published_at": "2026-07-31T17:00:00"},
        {"file_url": "https://example.com/instance.zip"},
        {"file_name": "inlineXBRL.zip"},
    ],
)
def test_parser_rejects_non_pit_nonofficial_or_wrong_attachment(overrides: dict[str, object]) -> None:
    with pytest.raises(ValueError):
        extract_financial_facts_from_xbrl_zip(_zip(_instance_xml()), _filing(**overrides))
