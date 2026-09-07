from __future__ import annotations

from datetime import datetime
from zoneinfo import ZoneInfo

from idx_flow_scanner.providers.block_idx_financial_revisions import (
    financial_revision_filings_from_profile_replies,
    infer_profile_financial_period,
)

WIB = ZoneInfo("Asia/Jakarta")


def _reply(timestamp: str = "2026-09-06T14:36:53") -> dict:
    return {
        "pengumuman": {
            "Id2": "20260906143653-063/SK/CORP/DOOH-BEI/IX/2026_id-id",
            "NoPengumuman": "063/SK/CORP/DOOH-BEI/IX/2026",
            "TglPengumuman": timestamp,
            "JudulPengumuman": "Penyampaian Laporan Keuangan Interim (KOREKSI)",
            "Kode_Emiten": "DOOH   ",
            "JMSXGroupID": "idxnet-xbrl-20260906145112-64368-0",
        },
        "attachments": [
            {
                "PDFFilename": "FinancialStatement-2026-I-DOOH.pdf",
                "OriginalFilename": "FinancialStatement-2026-I-DOOH.pdf",
                "FullSavePath": "\\\\StaticData\\\\NewsAndAnnouncement\\\\202609\\\\FinancialStatement-2026-I-DOOH.pdf",
            },
            {
                "PDFFilename": "FinancialStatement-2026-I-DOOH.xlsx",
                "OriginalFilename": "FinancialStatement-2026-I-DOOH.xlsx",
                "FullSavePath": "\\\\StaticData\\\\NewsAndAnnouncement\\\\202609\\\\FinancialStatement-2026-I-DOOH.xlsx",
            },
            {
                "PDFFilename": "inlineXBRL.zip",
                "OriginalFilename": "inlineXBRL.zip",
                "FullSavePath": "\\\\StaticData\\\\NewsAndAnnouncement\\\\202609\\\\inlineXBRL.zip",
            },
        ],
    }


def test_standard_idx_filename_recognizes_roman_period() -> None:
    assert infer_profile_financial_period(
        "Penyampaian Laporan Keuangan Interim",
        ["FinancialStatement-2026-II-AADI.xlsx", "inlineXBRL.zip"],
    ) == (2026, "TW2")
    assert infer_profile_financial_period(
        "Penyampaian Laporan Keuangan Interim",
        ["FinancialStatement-2026-III-TEST.xlsx"],
    ) == (2026, "TW3")


def test_revision_rows_preserve_announcement_identity_and_structured_files() -> None:
    filings, telemetry = financial_revision_filings_from_profile_replies(
        [_reply()],
        now=datetime(2026, 9, 8, 6, 45, tzinfo=WIB),
    )
    assert telemetry["financial_announcements"] == 1
    assert telemetry["inferred_announcements"] == 1
    assert telemetry["unresolved_period_announcements"] == 0
    assert len(filings) == 2
    assert {row["file_name"] for row in filings} == {
        "FinancialStatement-2026-I-DOOH.xlsx",
        "inlineXBRL.zip",
    }
    assert all(row["report_period"] == "TW1" for row in filings)
    assert all(row["report_period_end"] == "2026-03-31" for row in filings)
    assert all(row["published_at"] == "2026-09-06T14:36:53+07:00" for row in filings)
    assert all(row["announcement_no"] == "063/SK/CORP/DOOH-BEI/IX/2026" for row in filings)
    assert all(row["point_in_time_eligible"] is True for row in filings)
    assert all(str(row["file_url"]).startswith("https://www.idx.co.id/StaticData/") for row in filings)


def test_two_corrections_are_retained_as_distinct_revisions() -> None:
    first = _reply("2026-08-31T21:38:57")
    first["pengumuman"]["Id2"] = "20260831213857-first_id-id"
    first["pengumuman"]["NoPengumuman"] = "062/SK/CORP/DOOH-BEI/VIII/2026"
    first["attachments"][1]["FullSavePath"] = "\\\\StaticData\\\\NewsAndAnnouncement\\\\202608\\\\FinancialStatement-2026-I-DOOH.xlsx"
    first["attachments"][2]["FullSavePath"] = "\\\\StaticData\\\\NewsAndAnnouncement\\\\202608\\\\inlineXBRL.zip"
    second = _reply()
    filings, telemetry = financial_revision_filings_from_profile_replies(
        [first, second],
        now=datetime(2026, 9, 8, 6, 45, tzinfo=WIB),
    )
    assert telemetry["financial_announcements"] == 2
    assert len(filings) == 4
    assert len({row["filing_id"] for row in filings}) == 4
    assert {str(row["published_at"]) for row in filings} == {
        "2026-08-31T21:38:57+07:00",
        "2026-09-06T14:36:53+07:00",
    }


def test_impossible_publication_before_period_end_is_rejected() -> None:
    filings, telemetry = financial_revision_filings_from_profile_replies(
        [_reply("2026-03-01T10:00:00")],
        now=datetime(2026, 9, 8, 6, 45, tzinfo=WIB),
    )
    assert filings == []
    assert telemetry["skipped_non_pit_announcements"] == 1
