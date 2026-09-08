from __future__ import annotations

import idx_flow_scanner.providers.block_idx_financial_locator as locator


def _filing(**overrides: object) -> dict[str, object]:
    row: dict[str, object] = {
        "filing_id": "BLOCKIDX-FILING-test",
        "ticker": "BSSR",
        "report_year": 2026,
        "report_period": "TW2",
        "report_period_end": "2026-06-30",
        "published_at": "2026-09-04T17:08:40+07:00",
        "file_name": "instance.zip",
        "file_url": "https://www.idx.co.id/StaticData/NewsAndAnnouncement/old/instance.zip",
    }
    row.update(overrides)
    return row


def _report(**overrides: object) -> dict[str, object]:
    row: dict[str, object] = {
        "ticker": "BSSR",
        "report_year": 2026,
        "report_period": "TW2",
        "report_period_end": "2026-06-30",
        "file_modified_at": "2026-09-04T17:08:40.027000+07:00",
        "file_modified_second": "2026-09-04T17:08:40+07:00",
        "attachments": [
            {
                "file_name": "instance.zip",
                "file_url": "https://www.idx.co.id/StaticData/NewsAndAnnouncement/canonical/instance.zip",
            }
        ],
    }
    row.update(overrides)
    return row


def test_exact_timestamp_and_filename_resolves_official_url(monkeypatch) -> None:
    locator.clear_financial_locator_cache()
    monkeypatch.setattr(locator, "_current_report_rows", lambda ticker, year, period: (_report(),))
    resolved = locator.resolve_exact_current_report_attachment(_filing())
    assert resolved is not None
    assert resolved["resolved_file_url"].endswith("/canonical/instance.zip")
    assert resolved["resolution_state"] == "EXACT_CURRENT_REPORT_TIMESTAMP_FILENAME"
    assert resolved["point_in_time_identity_preserved"] is True


def test_later_revision_never_substitutes_for_older_filing(monkeypatch) -> None:
    locator.clear_financial_locator_cache()
    monkeypatch.setattr(
        locator,
        "_current_report_rows",
        lambda ticker, year, period: (
            _report(
                file_modified_at="2026-09-05T10:00:00+07:00",
                file_modified_second="2026-09-05T10:00:00+07:00",
            ),
        ),
    )
    assert locator.resolve_exact_current_report_attachment(_filing()) is None


def test_attachment_filename_must_match_exactly(monkeypatch) -> None:
    locator.clear_financial_locator_cache()
    monkeypatch.setattr(
        locator,
        "_current_report_rows",
        lambda ticker, year, period: (
            _report(
                attachments=[
                    {
                        "file_name": "inlineXBRL.zip",
                        "file_url": "https://www.idx.co.id/StaticData/NewsAndAnnouncement/canonical/inlineXBRL.zip",
                    }
                ]
            ),
        ),
    )
    assert locator.resolve_exact_current_report_attachment(_filing()) is None


def test_ambiguous_multiple_urls_fail_closed(monkeypatch) -> None:
    locator.clear_financial_locator_cache()
    report = _report(
        attachments=[
            {
                "file_name": "instance.zip",
                "file_url": "https://www.idx.co.id/StaticData/NewsAndAnnouncement/a/instance.zip",
            },
            {
                "file_name": "instance.zip",
                "file_url": "https://www.idx.co.id/StaticData/NewsAndAnnouncement/b/instance.zip",
            },
        ]
    )
    monkeypatch.setattr(locator, "_current_report_rows", lambda ticker, year, period: (report,))
    assert locator.resolve_exact_current_report_attachment(_filing()) is None
