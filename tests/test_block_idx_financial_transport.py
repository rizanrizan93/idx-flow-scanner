from __future__ import annotations

from io import BytesIO
from zipfile import ZipFile

import pytest

from idx_flow_scanner.providers import block_idx_financial_transport as transport


class _Response:
    def __init__(self, status: int, content: bytes = b"", content_type: str = "application/zip") -> None:
        self.status_code = status
        self.content = content
        self.headers = {"content-type": content_type}


class _QueueSession:
    def __init__(self, queue: list[object]) -> None:
        self.queue = queue

    def get(self, *_args: object, **_kwargs: object) -> _Response:
        item = self.queue.pop(0)
        if isinstance(item, BaseException):
            raise item
        assert isinstance(item, _Response)
        return item


def _zip_bytes() -> bytes:
    buffer = BytesIO()
    with ZipFile(buffer, "w") as archive:
        archive.writestr("instance.xbrl", "<xbrl />")
    return buffer.getvalue()


def _patch_sessions(monkeypatch: pytest.MonkeyPatch, queues: list[list[object]]) -> None:
    pending = list(queues)

    def factory() -> _QueueSession:
        return _QueueSession(pending.pop(0))

    monkeypatch.setattr(transport, "_new_session", factory)
    monkeypatch.setattr(transport.time, "sleep", lambda _seconds: None)


def test_mixed_403_then_404_is_transient_not_missing(monkeypatch: pytest.MonkeyPatch) -> None:
    _patch_sessions(monkeypatch, [[_Response(403)], [_Response(404)]])
    with pytest.raises(transport.OfficialIDXAttachmentDownloadError) as caught:
        transport.download_official_idx_xbrl_attachment(
            "https://www.idx.co.id/StaticData/a/instance.zip", retries=1
        )
    error = caught.value
    assert error.transient is True
    assert error.all_not_found is False
    assert error.code == "TRANSIENT_OFFICIAL_TRANSPORT_FAILURE"
    assert error.statuses == (403, 404)


def test_all_official_404_is_exact_locator_eligible(monkeypatch: pytest.MonkeyPatch) -> None:
    _patch_sessions(monkeypatch, [[_Response(404)], [_Response(404)]])
    with pytest.raises(transport.OfficialIDXAttachmentDownloadError) as caught:
        transport.download_official_idx_xbrl_attachment(
            "https://www.idx.co.id/StaticData/a/instance.zip", retries=1
        )
    error = caught.value
    assert error.all_not_found is True
    assert error.transient is False
    assert error.code == "ALL_OFFICIAL_TRANSPORTS_404"


def test_invalid_zip_body_is_retried_before_parser(monkeypatch: pytest.MonkeyPatch) -> None:
    good = _zip_bytes()
    _patch_sessions(monkeypatch, [[_Response(200, b"not a zip"), _Response(200, good)]])
    data, digest, content_type, attempts = transport.download_official_idx_xbrl_attachment(
        "https://block.idx.id/StaticData/a/instance.zip", retries=2
    )
    assert data == good
    assert len(digest) == 64
    assert content_type == "application/zip"
    assert attempts[0].error_kind == "INVALID_ZIP_BODY"
    assert attempts[-1].status == 200
    assert attempts[-1].error_kind is None


def test_network_failure_is_explicitly_transient(monkeypatch: pytest.MonkeyPatch) -> None:
    _patch_sessions(monkeypatch, [[TimeoutError("timeout")]])
    with pytest.raises(transport.OfficialIDXAttachmentDownloadError) as caught:
        transport.download_official_idx_xbrl_attachment(
            "https://block.idx.id/StaticData/a/instance.zip", retries=1
        )
    assert caught.value.transient is True
    assert caught.value.all_not_found is False
    assert caught.value.attempts[0].error_kind == "NETWORK_ERROR"
