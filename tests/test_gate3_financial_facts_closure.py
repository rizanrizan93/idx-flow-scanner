from __future__ import annotations

from io import BytesIO
from zipfile import ZipFile

from scripts import close_gate3_financial_facts as gate3


def _zip_bytes() -> bytes:
    buffer = BytesIO()
    with ZipFile(buffer, "w") as archive:
        archive.writestr("instance.xbrl", "<xbrl />")
    return buffer.getvalue()


def _failure() -> dict[str, object]:
    url = "https://www.idx.co.id/StaticData/a/instance.zip"
    return {
        "filing_id": "F1",
        "ticker": "TEST",
        "file_url": url,
        "failure_class": "TRANSIENT_OFFICIAL_TRANSPORT_FAILURE",
        "retryable": True,
        "transport_attempts": [
            {"transport_url": url, "status": 403},
            {"transport_url": url, "status": 403},
            {"transport_url": "https://block.idx.id/StaticData/a/instance.zip", "status": 404},
        ],
    }


def _filing() -> dict[str, object]:
    return {
        "filing_id": "F1",
        "ticker": "TEST",
        "file_url": "https://www.idx.co.id/StaticData/a/instance.zip",
        "report_year": 2026,
        "report_period": "TW2",
    }


def test_same_evidence_path_ignores_official_transport_host() -> None:
    assert gate3._same_evidence_path(
        "https://www.idx.co.id/StaticData/a/instance.zip",
        "https://block.idx.id/StaticData/a/instance.zip",
    )
    assert not gate3._same_evidence_path(
        "https://www.idx.co.id/StaticData/a/instance.zip",
        "https://block.idx.id/StaticData/b/instance.zip",
    )


def test_persistent_run4_pattern_requires_primary_403_and_block_404() -> None:
    assert gate3._persistent_run4_pattern(_failure())
    bad = _failure()
    bad["transport_attempts"] = [
        {"transport_url": "https://www.idx.co.id/StaticData/a/instance.zip", "status": 503},
        {"transport_url": "https://block.idx.id/StaticData/a/instance.zip", "status": 404},
    ]
    assert not gate3._persistent_run4_pattern(bad)


def test_permanent_unavailable_requires_exact_profile_and_all_mirror_404(monkeypatch) -> None:
    profile = {
        "point_in_time_identity_preserved": True,
        "resolution_state": "EXACT_PROFILE_ANNOUNCEMENT_TIMESTAMP_FILENAME",
        "announcement_id": "A1",
        "announcement_jmsx_group_id": "J1",
        "resolved_file_url": "https://www.idx.co.id/StaticData/a/instance.zip",
        "ticker": "TEST",
    }
    monkeypatch.setattr(gate3, "_profile_exact_identity", lambda _filing: profile)
    mirrors = [
        {"url": "https://block.idx.id/StaticData/a/instance.zip", "status": 404},
        {"url": "https://idx.id/StaticData/a/instance.zip", "status": 404},
        {"url": "https://www.idx.id/StaticData/a/instance.zip", "status": 404},
    ]
    monkeypatch.setattr(gate3, "_recover_from_same_path_mirror", lambda _filing, timeout: (None, mirrors))

    out = gate3._close_failure(_failure(), _filing(), timeout=1)
    assert out["action"] == "CLASSIFIED_PERMANENT"
    assert out["failure"]["failure_class"] == gate3.PERMANENT_UNAVAILABLE
    assert out["failure"]["retryable"] is False
    assert out["failure"]["point_in_time_identity_preserved"] is True


def test_transient_mirror_keeps_gate_fail_closed(monkeypatch) -> None:
    monkeypatch.setattr(
        gate3,
        "_profile_exact_identity",
        lambda _filing: {
            "point_in_time_identity_preserved": True,
            "resolved_file_url": "https://www.idx.co.id/StaticData/a/instance.zip",
            "ticker": "TEST",
        },
    )
    mirrors = [
        {"url": "https://block.idx.id/StaticData/a/instance.zip", "status": 404},
        {"url": "https://idx.id/StaticData/a/instance.zip", "status": 503},
        {"url": "https://www.idx.id/StaticData/a/instance.zip", "status": 404},
    ]
    monkeypatch.setattr(gate3, "_recover_from_same_path_mirror", lambda _filing, timeout: (None, mirrors))

    out = gate3._close_failure(_failure(), _filing(), timeout=1)
    assert out["action"] == "UNRESOLVED"
    assert out["failure"]["retryable"] is True
    assert out["failure"]["failure_class"] == "UNRESOLVED_OFFICIAL_ATTACHMENT_TRANSPORT"


def test_truncated_portal_recovery_requires_byte_prefix_identity(monkeypatch) -> None:
    full = _zip_bytes()
    truncated = full[: max(32, len(full) // 2)]
    calls = []

    def fake_fetch(url: str, *, timeout: float, retries: int = 1):
        calls.append(url)
        if "block.idx.id" in url:
            return {
                "url": url,
                "status": 200,
                "is_zip": False,
                "_data": truncated,
                "bytes": len(truncated),
                "sha256": "truncated",
            }
        return {
            "url": url,
            "status": 200,
            "is_zip": True,
            "_data": full,
            "bytes": len(full),
            "sha256": "full",
        }

    monkeypatch.setattr(gate3, "_fetch", fake_fetch)
    monkeypatch.setattr(
        gate3,
        "_parse_recovery",
        lambda filing, data, resolved_file_url, resolution_state, extra: (
            [{"filing_id": filing["filing_id"], "metric_key": "total_assets", "ticker": filing["ticker"]}],
            {
                "filing_id": filing["filing_id"],
                "ticker": filing["ticker"],
                "content_hash": "x",
                "url_resolution_state": resolution_state,
                **extra,
            },
        ),
    )

    out = gate3._recover_truncated_portal_archive(_filing(), timeout=1)
    assert out is not None
    facts, telemetry, proof = out
    assert len(facts) == 1
    assert telemetry["prefix_identity"] is True
    assert proof["prefix_identity"] is True
    assert len(calls) >= 2


def test_rebuild_payload_preserves_non_fake_100_percent_failure() -> None:
    cache = {
        "selected_filing_rows": 2,
        "rows": [{"ticker": "AAA", "filing_id": "A", "metric_key": "total_assets"}],
        "filing_telemetry": [
            {
                "ticker": "AAA",
                "filing_id": "A",
                "content_hash": "a" * 64,
                "reporting_currency": "IDR",
                "url_resolution_state": "ORIGINAL_OFFICIAL_URL",
            }
        ],
        "failures": [_failure()],
        "production_scoring_changed": False,
    }
    permanent = _failure()
    permanent["failure_class"] = gate3.PERMANENT_UNAVAILABLE
    permanent["retryable"] = False
    payload = gate3._rebuild_payload(
        cache,
        [
            {
                "filing_id": "F1",
                "ticker": "TEST",
                "action": "CLASSIFIED_PERMANENT",
                "failure": permanent,
            }
        ],
    )
    assert payload["parsed_filing_rows"] == 1
    assert payload["failed_filing_rows"] == 1
    assert payload["gate3_closure"]["retryable_failure_rows"] == 0
    assert payload["production_scoring_changed"] is False
