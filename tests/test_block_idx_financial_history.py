from __future__ import annotations

from datetime import datetime
from zoneinfo import ZoneInfo

from idx_flow_scanner.providers.block_idx_financial_history import (
    match_point_in_time_financial_filings,
    parse_financial_report_payload,
    parse_profile_announcement_replies,
)

WIB = ZoneInfo("Asia/Jakarta")


def _financial_payload() -> dict:
    return {
        "ResultCount": 1,
        "Results": [
            {
                "KodeEmiten": "AADI",
                "File_Modified": "2026-08-28T16:13:53.237",
                "Report_Period": "TW2",
                "Report_Year": "2026",
                "NamaEmiten": "PT Adaro Andalan Indonesia Tbk",
                "Attachments": [
                    {
                        "File_ID": "xlsx-id",
                        "File_Name": "FinancialStatement-2026-II-AADI.xlsx",
                        "File_Path": "/Portals/0/StaticData/ListedCompanies/FinancialStatement-2026-II-AADI.xlsx",
                        "File_Size": 532176,
                        "File_Type": ".xlsx",
                    },
                    {
                        "File_ID": "zip-id",
                        "File_Name": "inlineXBRL.zip",
                        "File_Path": "/Portals/0/StaticData/ListedCompanies/inlineXBRL.zip",
                        "File_Size": 273269,
                        "File_Type": ".zip",
                    },
                    {
                        "File_ID": "pdf-id",
                        "File_Name": "FinancialStatement-2026-II-AADI.pdf",
                        "File_Path": "/Portals/0/StaticData/ListedCompanies/FinancialStatement-2026-II-AADI.pdf",
                        "File_Size": 874579,
                        "File_Type": ".pdf",
                    },
                ],
            }
        ],
    }


def _announcement_replies(timestamp: str = "2026-08-28T16:13:53") -> list[dict]:
    return [
        {
            "pengumuman": {
                "Id2": "20260828161353-AAI/153/VIII-26/corsec_id-id",
                "NoPengumuman": "AAI/153/VIII-26/corsec",
                "TglPengumuman": timestamp,
                "JudulPengumuman": "Penyampaian Laporan Keuangan Interim Yang Ditelaah Secara Terbatas",
                "Kode_Emiten": "AADI   ",
                "JMSXGroupID": "idxnet-xbrl-20260828162911-64185-0",
            },
            "attachments": [
                {
                    "PDFFilename": "FinancialStatement-2026-II-AADI.pdf",
                    "OriginalFilename": "FinancialStatement-2026-II-AADI.pdf",
                    "FullSavePath": "\\\\StaticData\\\\NewsAndAnnouncement\\\\FinancialStatement-2026-II-AADI.pdf",
                },
                {
                    "PDFFilename": "FinancialStatement-2026-II-AADI.xlsx",
                    "OriginalFilename": "FinancialStatement-2026-II-AADI.xlsx",
                    "FullSavePath": "\\\\StaticData\\\\NewsAndAnnouncement\\\\FinancialStatement-2026-II-AADI.xlsx",
                },
                {
                    "PDFFilename": "inlineXBRL.zip",
                    "OriginalFilename": "inlineXBRL.zip",
                    "FullSavePath": "\\\\StaticData\\\\NewsAndAnnouncement\\\\inlineXBRL.zip",
                },
            ],
        }
    ]


def test_market_financial_payload_preserves_report_period_and_official_files() -> None:
    reports = parse_financial_report_payload(_financial_payload())
    assert len(reports) == 1
    report = reports[0]
    assert report["ticker"] == "AADI"
    assert report["report_period"] == "TW2"
    assert report["report_period_end"] == "2026-06-30"
    assert report["file_modified_at"] == "2026-08-28T16:13:53.237000+07:00"
    assert len(report["attachments"]) == 3
    assert sum(bool(row["structured"]) for row in report["attachments"]) == 2
    assert all(str(row["file_url"]).startswith("https://www.idx.co.id/") for row in report["attachments"])


def test_pit_match_requires_exact_second_and_attachment_identity() -> None:
    reports = parse_financial_report_payload(_financial_payload())
    announcements = parse_profile_announcement_replies(_announcement_replies())
    filings, telemetry = match_point_in_time_financial_filings(
        reports,
        announcements,
        now=datetime(2026, 9, 8, 6, 45, tzinfo=WIB),
    )
    assert telemetry["matched_report_groups"] == 1
    assert telemetry["unmatched_report_groups"] == 0
    assert len(filings) == 2
    assert {row["file_name"] for row in filings} == {
        "FinancialStatement-2026-II-AADI.xlsx",
        "inlineXBRL.zip",
    }
    assert all(row["publication_time_verified"] is True for row in filings)
    assert all(row["point_in_time_eligible"] is True for row in filings)
    assert all(row["published_at"] == "2026-08-28T16:13:53+07:00" for row in filings)
    assert all(row["announcement_no"] == "AAI/153/VIII-26/corsec" for row in filings)


def test_timestamp_mismatch_fails_closed() -> None:
    reports = parse_financial_report_payload(_financial_payload())
    announcements = parse_profile_announcement_replies(_announcement_replies("2026-08-28T16:13:54"))
    filings, telemetry = match_point_in_time_financial_filings(
        reports,
        announcements,
        now=datetime(2026, 9, 8, 6, 45, tzinfo=WIB),
    )
    assert filings == []
    assert telemetry["matched_report_groups"] == 0
    assert telemetry["unmatched_report_groups"] == 1


def test_attachment_identity_mismatch_fails_closed() -> None:
    replies = _announcement_replies()
    replies[0]["attachments"] = [
        {
            "PDFFilename": "different-file.pdf",
            "OriginalFilename": "different-file.pdf",
            "FullSavePath": "\\\\StaticData\\\\NewsAndAnnouncement\\\\different-file.pdf",
        }
    ]
    reports = parse_financial_report_payload(_financial_payload())
    announcements = parse_profile_announcement_replies(replies)
    filings, telemetry = match_point_in_time_financial_filings(
        reports,
        announcements,
        now=datetime(2026, 9, 8, 6, 45, tzinfo=WIB),
    )
    assert filings == []
    assert telemetry["unmatched_report_groups"] == 1


def test_period_end_guard_rejects_impossible_publication() -> None:
    payload = _financial_payload()
    payload["Results"][0]["File_Modified"] = "2026-06-01T12:00:00"
    replies = _announcement_replies("2026-06-01T12:00:00")
    reports = parse_financial_report_payload(payload)
    announcements = parse_profile_announcement_replies(replies)
    filings, telemetry = match_point_in_time_financial_filings(
        reports,
        announcements,
        now=datetime(2026, 9, 8, 6, 45, tzinfo=WIB),
    )
    assert filings == []
    assert telemetry["skipped_non_pit_groups"] == 1
