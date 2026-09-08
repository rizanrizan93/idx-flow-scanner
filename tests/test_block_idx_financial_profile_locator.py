from __future__ import annotations

from idx_flow_scanner.providers import block_idx_financial_profile_locator as locator


def _filing() -> dict[str, object]:
    return {
        "filing_id": "BLOCKIDX-FILING-test",
        "ticker": "ABBA",
        "published_at": "2026-07-31T13:32:58+07:00",
        "file_name": "instance.zip",
        "file_url": "https://www.idx.co.id/StaticData/old/instance.zip",
        "announcement_id": "20260731133258-003/F-PTMM/VII/2026_id-id",
    }


def test_profile_locator_requires_same_announcement_second_filename_and_id(monkeypatch) -> None:
    replies = (
        {
            "pengumuman": {
                "Id2": "20260731133258-003/F-PTMM/VII/2026_id-id",
                "Kode_Emiten": "ABBA",
                "TglPengumuman": "2026-07-31T13:32:58",
                "JMSXGroupID": "idxnet-xbrl-20260731134409-63812-0",
            },
            "attachments": [
                {
                    "OriginalFilename": "instance.zip",
                    "FullSavePath": r"\\StaticData\\NewsAndAnnouncement\\ANNOUNCEMENTSTOCK\\From_EREP\\202607\\20260731134409-63812-0\\instance.zip",
                }
            ],
        },
    )
    monkeypatch.setattr(locator, "_announcement_replies", lambda _ticker, _date: replies)
    resolved = locator.resolve_exact_profile_announcement_attachment(_filing())
    assert resolved is not None
    assert resolved["resolved_file_url"].endswith(
        "/StaticData/NewsAndAnnouncement/ANNOUNCEMENTSTOCK/From_EREP/202607/20260731134409-63812-0/instance.zip"
    )
    assert resolved["announcement_id"] == "20260731133258-003/F-PTMM/VII/2026_id-id"
    assert resolved["point_in_time_identity_preserved"] is True


def test_profile_locator_does_not_substitute_later_revision(monkeypatch) -> None:
    replies = (
        {
            "pengumuman": {
                "Id2": "later-revision",
                "Kode_Emiten": "ABBA",
                "TglPengumuman": "2026-07-31T13:32:59",
                "JMSXGroupID": "later",
            },
            "attachments": [
                {"OriginalFilename": "instance.zip", "FullSavePath": r"\\StaticData\\later\\instance.zip"}
            ],
        },
    )
    monkeypatch.setattr(locator, "_announcement_replies", lambda _ticker, _date: replies)
    assert locator.resolve_exact_profile_announcement_attachment(_filing()) is None
