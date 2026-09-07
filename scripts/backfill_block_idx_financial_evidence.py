from __future__ import annotations

import argparse
import json
from datetime import date, datetime, timedelta
from pathlib import Path
from zoneinfo import ZoneInfo

from idx_flow_scanner.providers.block_idx_financial_history import (
    fetch_financial_report_market,
    fetch_profile_announcements_market,
    match_point_in_time_financial_filings,
    parse_financial_report_payload,
    parse_profile_announcement_replies,
    verify_attachment_hashes,
)
from idx_flow_scanner.providers.block_idx_financial_revisions import (
    financial_revision_filings_from_profile_replies,
)

WIB = ZoneInfo("Asia/Jakarta")
PERIODS = ("TW1", "TW2", "TW3", "AUDIT")
DEFAULT_OUT = Path("data/cache/evidence_v5/block_idx_historical_financial_filings.json")
DEFAULT_META = Path("data/cache/evidence_v5/block_idx_historical_financial_backfill_meta.json")


def parse_date(value: str) -> date:
    return date.fromisoformat(value)


def month_ranges(start: date, end: date):
    cursor = start
    while cursor <= end:
        if cursor.month == 12:
            next_month = date(cursor.year + 1, 1, 1)
        else:
            next_month = date(cursor.year, cursor.month + 1, 1)
        chunk_end = min(end, next_month - timedelta(days=1))
        yield cursor, chunk_end
        cursor = next_month


def main() -> int:
    now = datetime.now(WIB)
    today = now.date()
    default_start = date(today.year - 3, today.month, min(today.day, 28 if today.month == 2 else today.day))

    parser = argparse.ArgumentParser(description="Backfill point-in-time Block IDX financial filing evidence")
    parser.add_argument("--start", type=parse_date, default=default_start)
    parser.add_argument("--end", type=parse_date, default=today)
    parser.add_argument("--report-year-start", type=int, default=None)
    parser.add_argument("--report-year-end", type=int, default=None)
    parser.add_argument("--download-smoke", type=int, default=3)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUT)
    parser.add_argument("--meta-output", type=Path, default=DEFAULT_META)
    args = parser.parse_args()

    if args.end < args.start:
        raise SystemExit("--end must be >= --start")
    report_year_start = args.report_year_start if args.report_year_start is not None else args.start.year - 1
    report_year_end = args.report_year_end if args.report_year_end is not None else args.end.year
    if report_year_end < report_year_start:
        raise SystemExit("report year range is invalid")

    raw_announcements: list[dict] = []
    month_telemetry: list[dict[str, object]] = []
    for chunk_start, chunk_end in month_ranges(args.start, args.end):
        replies = fetch_profile_announcements_market(chunk_start, chunk_end, page_size=1000)
        raw_announcements.extend(replies)
        month_telemetry.append(
            {
                "date_from": chunk_start.isoformat(),
                "date_to": chunk_end.isoformat(),
                "reply_rows": len(replies),
            }
        )
        print(json.dumps(month_telemetry[-1], sort_keys=True))

    announcements = parse_profile_announcement_replies(raw_announcements)
    announcement_ids: set[str] = set()
    deduped_announcements: list[dict[str, object]] = []
    for row in announcements:
        key = str(row.get("announcement_id") or "")
        if not key or key in announcement_ids:
            continue
        announcement_ids.add(key)
        deduped_announcements.append(row)

    report_groups: list[dict[str, object]] = []
    financial_query_telemetry: list[dict[str, object]] = []
    for year in range(report_year_start, report_year_end + 1):
        for period in PERIODS:
            payload = fetch_financial_report_market(year, period)
            parsed = parse_financial_report_payload(payload)
            report_groups.extend(parsed)
            financial_query_telemetry.append(
                {
                    "report_year": year,
                    "report_period": period,
                    "result_count": int(payload.get("ResultCount") or 0),
                    "parsed_report_groups": len(parsed),
                }
            )
            print(json.dumps(financial_query_telemetry[-1], sort_keys=True))

    revision_filings, revision_telemetry = financial_revision_filings_from_profile_replies(
        raw_announcements,
        report_groups=report_groups,
        now=now,
    )
    latest_filings, match_telemetry = match_point_in_time_financial_filings(
        report_groups,
        deduped_announcements,
        now=now,
    )
    filings = revision_filings
    filings.sort(key=lambda row: (str(row["ticker"]), int(row["report_year"]), str(row["report_period"]), str(row["published_at"]), str(row["file_name"])))

    preferred = []
    used_ids: set[str] = set()
    for ticker in ("DOOH", "FLMC", "MKNT", "AADI"):
        for row in filings:
            if row["ticker"] == ticker and row["filing_id"] not in used_ids:
                preferred.append(row)
                used_ids.add(str(row["filing_id"]))
                break
    for row in filings:
        if len(preferred) >= max(0, int(args.download_smoke)):
            break
        if row["filing_id"] not in used_ids:
            preferred.append(row)
            used_ids.add(str(row["filing_id"]))

    download_telemetry = verify_attachment_hashes(preferred, limit=args.download_smoke) if args.download_smoke else []

    payload = {
        "schema_version": "BLOCK_IDX_HISTORICAL_FINANCIAL_FILING_CACHE_V5_2",
        "generated_at": now.isoformat(),
        "source_authority": "INDONESIA_STOCK_EXCHANGE",
        "financial_report_endpoint": "https://block.idx.id/primary/ListedCompany/GetFinancialReport",
        "publication_time_endpoint": "https://block.idx.id/primary/ListedCompany/GetProfileAnnouncement",
        "announcement_date_from": args.start.isoformat(),
        "announcement_date_to": args.end.isoformat(),
        "report_year_start": report_year_start,
        "report_year_end": report_year_end,
        "matching_contract": "PROFILE_ANNOUNCEMENT_PIT_ATTACHMENT_IDENTITY_WITH_LATEST_REPORT_CORROBORATION",
        "revision_semantics": "EVERY_FINANCIAL_ANNOUNCEMENT_REVISION_RETAINED_WHEN_PERIOD_IS_VERIFIABLE",
        "rows": filings,
    }
    meta = {
        "schema_version": "BLOCK_IDX_HISTORICAL_FINANCIAL_BACKFILL_META_V5_2",
        "generated_at": now.isoformat(),
        "announcement_months": month_telemetry,
        "financial_queries": financial_query_telemetry,
        "raw_announcement_replies": len(raw_announcements),
        "financial_announcement_rows": len(deduped_announcements),
        "report_groups": len(report_groups),
        "revision_backfill": revision_telemetry,
        "latest_report_corroboration": match_telemetry,
        "latest_report_corroborated_filing_rows": len(latest_filings),
        "download_smoke": download_telemetry,
        "production_scoring_changed": False,
    }

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.meta_output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    args.meta_output.write_text(json.dumps(meta, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps({
        "status": "OK",
        "revision_filing_rows": len(filings),
        "revision_inferred_announcements": revision_telemetry["inferred_announcements"],
        "revision_unresolved_period_announcements": revision_telemetry["unresolved_period_announcements"],
        "latest_matched_report_groups": match_telemetry["matched_report_groups"],
        "download_smoke_verified": len(download_telemetry),
        "production_scoring_changed": False,
    }, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
