from __future__ import annotations

import hashlib
import time
from dataclasses import dataclass
from io import BytesIO
from typing import Any
from zipfile import is_zipfile

from curl_cffi import requests as curl_requests

from idx_flow_scanner.providers.block_idx_evidence import (
    BLOCK_IDX_ANNOUNCEMENT_PAGE,
    official_idx_transport_candidates,
)


TRANSIENT_HTTP_STATUSES = frozenset({403, 408, 425, 429, 500, 502, 503, 504})


@dataclass(frozen=True)
class TransportAttempt:
    transport_url: str
    attempt: int
    status: int | None
    error_kind: str | None = None


class OfficialIDXAttachmentDownloadError(RuntimeError):
    def __init__(self, code: str, attempts: list[TransportAttempt]) -> None:
        self.code = str(code)
        self.attempts = tuple(attempts)
        statuses = [row.status for row in attempts if row.status is not None]
        self.statuses = tuple(int(value) for value in statuses)
        self.all_not_found = bool(self.statuses) and all(value == 404 for value in self.statuses) and all(
            row.error_kind is None for row in attempts
        )
        self.transient = any(
            row.status in TRANSIENT_HTTP_STATUSES
            or row.error_kind in {"NETWORK_ERROR", "EMPTY_BODY", "HTML_BODY", "INVALID_ZIP_BODY"}
            for row in attempts
        )
        trace = ",".join(
            f"{row.transport_url}:{row.attempt}:{row.status if row.status is not None else row.error_kind}"
            for row in attempts
        )
        super().__init__(f"{self.code}; attempts={trace}")


def _new_session() -> Any:
    return curl_requests.Session(impersonate="chrome")


def _headers() -> dict[str, str]:
    return {
        "Accept": "application/zip,application/octet-stream,*/*",
        "Accept-Language": "id-ID,id;q=0.9,en;q=0.8",
        "Referer": BLOCK_IDX_ANNOUNCEMENT_PAGE,
        "User-Agent": "Mozilla/5.0",
        "Cache-Control": "no-cache",
        "Pragma": "no-cache",
    }


def download_official_idx_xbrl_attachment(
    url: str,
    *,
    timeout: float = 60.0,
    retries: int = 3,
) -> tuple[bytes, str, str | None, tuple[TransportAttempt, ...]]:
    """Fetch an official IDX XBRL ZIP without masking transport failures.

    The original evidence URL is never rewritten. Alternative official hosts are
    transport-only candidates for identical path bytes. A 403/5xx/network error
    on one official host cannot be reclassified as a missing file just because a
    later fallback host returns 404.
    """

    candidates = official_idx_transport_candidates(url)
    if not candidates:
        raise ValueError("non-official IDX URL rejected")

    attempts: list[TransportAttempt] = []
    retry_count = max(1, int(retries))
    last_code = "OFFICIAL_TRANSPORT_FAILURE"

    for transport_url in candidates:
        session = _new_session()
        for attempt_number in range(1, retry_count + 1):
            try:
                response = session.get(
                    transport_url,
                    headers=_headers(),
                    timeout=max(1.0, float(timeout)),
                )
            except Exception:
                attempts.append(
                    TransportAttempt(
                        transport_url=transport_url,
                        attempt=attempt_number,
                        status=None,
                        error_kind="NETWORK_ERROR",
                    )
                )
                last_code = "TRANSIENT_OFFICIAL_TRANSPORT_FAILURE"
                if attempt_number < retry_count:
                    time.sleep(min(12.0, 1.5 * (2 ** (attempt_number - 1))))
                continue

            status = int(response.status_code)
            if status == 200:
                data = bytes(response.content or b"")
                if not data:
                    attempts.append(TransportAttempt(transport_url, attempt_number, status, "EMPTY_BODY"))
                    last_code = "TRANSIENT_OFFICIAL_TRANSPORT_FAILURE"
                else:
                    prefix = data[:64].lstrip().lower()
                    if prefix.startswith(b"<!doctype html") or prefix.startswith(b"<html"):
                        attempts.append(TransportAttempt(transport_url, attempt_number, status, "HTML_BODY"))
                        last_code = "TRANSIENT_OFFICIAL_TRANSPORT_FAILURE"
                    elif not is_zipfile(BytesIO(data)):
                        attempts.append(TransportAttempt(transport_url, attempt_number, status, "INVALID_ZIP_BODY"))
                        last_code = "INVALID_ZIP_BODY"
                    else:
                        attempts.append(TransportAttempt(transport_url, attempt_number, status, None))
                        digest = hashlib.sha256(data).hexdigest()
                        return data, digest, response.headers.get("content-type"), tuple(attempts)

                if attempt_number < retry_count:
                    time.sleep(min(12.0, 1.5 * (2 ** (attempt_number - 1))))
                continue

            attempts.append(TransportAttempt(transport_url, attempt_number, status, None))
            if status == 404:
                break
            if status in TRANSIENT_HTTP_STATUSES:
                last_code = "TRANSIENT_OFFICIAL_TRANSPORT_FAILURE"
                if attempt_number < retry_count:
                    time.sleep(min(12.0, 1.5 * (2 ** (attempt_number - 1))))
                continue
            last_code = "OFFICIAL_TRANSPORT_FAILURE"
            break

    error = OfficialIDXAttachmentDownloadError(last_code, attempts)
    if error.all_not_found:
        error = OfficialIDXAttachmentDownloadError("ALL_OFFICIAL_TRANSPORTS_404", attempts)
    elif any(row.error_kind == "INVALID_ZIP_BODY" for row in attempts):
        # Preserve invalid-body evidence unless another transport condition already
        # proves a broader transient access failure.
        if not any(row.status in TRANSIENT_HTTP_STATUSES or row.error_kind == "NETWORK_ERROR" for row in attempts):
            error = OfficialIDXAttachmentDownloadError("INVALID_ZIP_BODY", attempts)
    raise error


__all__ = [
    "TRANSIENT_HTTP_STATUSES",
    "TransportAttempt",
    "OfficialIDXAttachmentDownloadError",
    "download_official_idx_xbrl_attachment",
]
