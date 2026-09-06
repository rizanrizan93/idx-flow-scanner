from __future__ import annotations

from types import SimpleNamespace

import pytest

from idx_flow_scanner.official_filings import (
    classify_announcement,
    normalize_announcement_reply,
    sha256_bytes,
    validate_file_magic,
    validate_no_redirect,
    validate_official_url,
)


def test_official_url_validation_accepts_only_https_idx_hosts():
    assert validate_official_url("https://block.idx.id/primary/x") == "https://block.idx.id/primary/x"
    assert validate_official_url("https://www.idx.co.id/StaticData/a.pdf") == "https://www.idx.co.id/StaticData/a.pdf"
    for bad in (
        "http://block.idx.id/primary/x",
        "https://evil.example/instance.zip",
        "https://block.idx.id.evil.example/instance.zip",
        "https://user@block.idx.id/instance.zip",
    ):
        with pytest.raises(ValueError):
            validate_official_url(bad)


def test_redirects_and_changed_final_url_are_rejected():
    redirect = SimpleNamespace(status_code=302, history=[], url="https://block.idx.id/a")
    with pytest.raises(ValueError):
        validate_no_redirect(redirect, expected_url="https://block.idx.id/a")
    history = SimpleNamespace(status_code=200, history=[object()], url="https://block.idx.id/a")
    with pytest.raises(ValueError):
        validate_no_redirect(history, expected_url="https://block.idx.id/a")
    changed = SimpleNamespace(status_code=200, history=[], url="https://www.idx.co.id/a")
    with pytest.raises(ValueError):
        validate_no_redirect(changed, expected_url="https://block.idx.id/a")


def test_magic_and_hash_validation():
    assert len(sha256_bytes(b"abc")) == 64
    validate_file_magic(b"PK\x03\x04payload", "instance_xbrl_zip")
    validate_file_magic(b"%PDF-1.7 payload", "pdf")
    with pytest.raises(ValueError):
        validate_file_magic(b"<html>cloudflare</html>", "instance_xbrl_zip")


def test_official_announcement_normalization_and_event_categories():
    reply = {
        "pengumuman": {
            "Id2": "20260904173355-011_id-id",
            "TglPengumuman": "2026-09-04T17:33:55",
            "JudulPengumuman": "Rencana Pembelian Kembali Saham dan Dividen",
            "JenisPengumuman": "STOCK",
            "Kode_Emiten": "BBCA   ",
            "NoPengumuman": "011/2026",
            "PerihalPengumuman": "Buyback",
            "Form_Id": "11000",
        },
        "attachments": [
            {
                "FullSavePath": "https://www.idx.co.id/StaticData/NewsAndAnnouncement/a.pdf",
                "OriginalFilename": "BBCA.pdf",
                "PDFFilename": "a.pdf",
                "IsAttachment": False,
            },
            {"FullSavePath": "https://evil.example/fake.pdf", "OriginalFilename": "fake.pdf"},
        ],
    }
    metadata, attachments = normalize_announcement_reply(reply)
    assert metadata["ticker"] == "BBCA"
    assert metadata["source_verified"] is True
    assert set(metadata["categories"]) >= {"buyback", "dividend"}
    assert len(attachments) == 1
    assert attachments[0]["url"].startswith("https://www.idx.co.id/")
    assert classify_announcement("Penyampaian Materi Public Expose") == ["other_disclosure"]
