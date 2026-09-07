from __future__ import annotations

import argparse
import json
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

from idx_flow_scanner.providers.block_idx_evidence import (
    BLOCK_IDX_ANNOUNCEMENT_PAGE,
    download_official_idx_attachment,
    fetch_block_idx_current_announcements,
    financial_filings_from_announcements,
)

ROOT = Path(__file__).resolve().parents[1]
CACHE_DIR = ROOT / "data" / "cache" / "evidence_v5"
ANNOUNCEMENT_CACHE = CACHE_DIR / "block_idx_current_announcements.json"
FILING_CACHE = CACHE_DIR / "block_idx_current_financial_filings.json"
META_CACHE = CACHE_DIR / "block_idx_capture_meta.json"
WIB = ZoneInfo("Asia/Jakarta")


def _write(path: Path, payload: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, sort_keys=True, ensure_ascii=False, default=str) + "\n", encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description="Capture official Block IDX point-in-time evidence.")
    parser.add_argument("--download-smoke", type=int, default=2, help="Number of official attachments to download/hash without persisting binaries.")
    args = parser.parse_args()

    captured_at = datetime.now(WIB).isoformat()
    announcements = fetch_block_idx_current_announcements()
    filings = financial_filings_from_announcements(announcements)
    if not announcements:
        raise RuntimeError("Block IDX returned no server-rendered announcements")

    smoke: list[dict[str, object]] = []
    for row in announcements:
        for attachment in row.get("attachment_urls", []):
            if len(smoke) >= max(0, int(args.download_smoke)):
                break
            if not isinstance(attachment, dict) or not attachment.get("url"):
                continue
            data, digest, content_type = download_official_idx_attachment(str(attachment["url"]))
            smoke.append(
                {
                    "announcement_id": row["announcement_id"],
                    "ticker": row.get("ticker"),
                    "url": attachment["url"],
                    "bytes": len(data),
                    "sha256": digest,
                    "content_type": content_type,
                    "binary_persisted": False,
                }
            )
        if len(smoke) >= max(0, int(args.download_smoke)):
            break

    _write(
        ANNOUNCEMENT_CACHE,
        {
            "schema_version": "BLOCK_IDX_DISCLOSURE_CACHE_V5_1",
            "source_page": BLOCK_IDX_ANNOUNCEMENT_PAGE,
            "rows": announcements,
        },
    )
    _write(
        FILING_CACHE,
        {
            "schema_version": "BLOCK_IDX_FINANCIAL_FILING_CACHE_V5_1",
            "source_page": BLOCK_IDX_ANNOUNCEMENT_PAGE,
            "rows": filings,
        },
    )
    _write(
        META_CACHE,
        {
            "captured_at": captured_at,
            "source_page": BLOCK_IDX_ANNOUNCEMENT_PAGE,
            "announcement_rows": len(announcements),
            "financial_filing_rows": len(filings),
            "ownership_rows_on_current_page": sum(1 for row in announcements if row.get("disclosure_type") == "OWNERSHIP"),
            "point_in_time_eligible_rows": sum(1 for row in announcements if row.get("point_in_time_eligible")),
            "download_smoke": smoke,
            "no_fabricated_evidence": True,
            "production_scoring_changed": False,
        },
    )
    print(META_CACHE.read_text(encoding="utf-8"))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
