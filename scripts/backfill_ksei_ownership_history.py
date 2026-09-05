from __future__ import annotations

import csv
import hashlib
import io
import json
import sys
import zipfile
from pathlib import Path

import pandas as pd
from curl_cffi import requests

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "src"
if str(SRC) not in sys.path:
    sys.path.insert(0, str(SRC))

from idx_flow_scanner.data import canonical_ticker

UNIVERSE_PATH = ROOT / "data" / "universe" / "idx_700_all.csv"
OUT_CSV = ROOT / "data" / "cache" / "ksei_ownership_history_2026.csv.gz"
OUT_JSON = ROOT / "data" / "cache" / "ksei_ownership_history_2026.json"

REPORT_DATES = [
    "20260130",
    "20260227",
    "20260331",
    "20260430",
    "20260529",
    "20260630",
    "20260731",
    "20260831",
]
BASE_URL = "https://web.ksei.co.id/Download/BalanceposEfek{date}.zip"
REFERER = "https://web.ksei.co.id/archive_download/holding_composition"
PROVENANCE = "VERIFIED_KSEI_REGISTRATION_COMPOSITION"
CATEGORY = "ksei-komposisi"
HOLDER_TYPE = "KSEI_REGISTRATION_COMPOSITION"


def _holder_hash(ticker: str, classification: str) -> str:
    key = f"KSEI|{ticker}|{classification}".encode("utf-8")
    return hashlib.sha256(key).hexdigest()


def _download(date_token: str) -> tuple[bytes, str]:
    url = BASE_URL.format(date=date_token)
    response = requests.get(
        url,
        headers={
            "Accept": "application/zip,application/octet-stream,*/*",
            "Referer": REFERER,
            "User-Agent": "Mozilla/5.0",
        },
        impersonate="chrome",
        timeout=60,
    )
    response.raise_for_status()
    if not response.content.startswith(b"PK"):
        raise RuntimeError(f"{date_token}: KSEI response is not ZIP")
    return response.content, url


def _parse_archive(raw_zip: bytes, source_url: str, allowed: set[str]) -> tuple[list[dict[str, object]], dict[str, object]]:
    zip_hash = hashlib.sha256(raw_zip).hexdigest()
    with zipfile.ZipFile(io.BytesIO(raw_zip)) as archive:
        names = [name for name in archive.namelist() if name.lower().endswith(".txt")]
        if not names:
            raise RuntimeError(f"no txt file in {source_url}")
        raw_text = archive.read(names[0])
    text_hash = hashlib.sha256(raw_text).hexdigest()
    text = raw_text.decode("utf-8-sig")
    reader = csv.reader(io.StringIO(text), delimiter="|")
    header = next(reader, None)
    expected = [
        "Date", "Code", "Type", "Sec. Num", "Price",
        "Local IS", "Local CP", "Local PF", "Local IB", "Local ID", "Local MF", "Local SC", "Local FD", "Local OT", "Total",
        "Foreign IS", "Foreign CP", "Foreign PF", "Foreign IB", "Foreign ID", "Foreign MF", "Foreign SC", "Foreign FD", "Foreign OT", "Total",
    ]
    if header != expected:
        raise RuntimeError(f"unexpected KSEI header in {source_url}: {header}")

    rows: list[dict[str, object]] = []
    source_tickers: set[str] = set()
    accepted_tickers: set[str] = set()
    invalid = 0
    report_date: str | None = None

    for fields in reader:
        if len(fields) != 25:
            invalid += 1
            continue
        ticker = canonical_ticker(fields[1])
        if not ticker or str(fields[2]).strip().upper() != "EQUITY":
            continue
        source_tickers.add(ticker)
        if ticker not in allowed:
            continue
        try:
            sec_num = float(fields[3])
            local_total = float(fields[14])
            foreign_total = float(fields[24])
        except Exception:
            invalid += 1
            continue
        scripless = local_total + foreign_total
        if sec_num <= 0 or local_total < 0 or foreign_total < 0 or scripless <= 0:
            invalid += 1
            continue
        # KSEI's scripless balance should never materially exceed the issued/security reference.
        if scripless > sec_num * 1.05:
            invalid += 1
            continue
        parsed_date = pd.to_datetime(fields[0], format="%d-%b-%Y", errors="coerce")
        if pd.isna(parsed_date):
            invalid += 1
            continue
        date_iso = parsed_date.date().isoformat()
        report_date = report_date or date_iso
        local_pct = 100.0 * local_total / scripless
        foreign_pct = 100.0 * foreign_total / scripless
        if abs((local_pct + foreign_pct) - 100.0) > 1e-7:
            invalid += 1
            continue

        accepted_tickers.add(ticker)
        common = {
            "ticker": ticker,
            "category": CATEGORY,
            "holder_type": HOLDER_TYPE,
            "report_date": date_iso,
            "publication_date": date_iso,
            "source_url": source_url,
            "source_verified": True,
            "provenance_state": PROVENANCE,
            "source_file_hash": text_hash,
        }
        definitions = [
            ("KSEI_SECURITY_NUMBER", "KSEI security number / issued reference", sec_num, None, None),
            ("KSEI_SCRIPLESS_TOTAL", "KSEI scripless holdings", scripless, 100.0 * scripless / sec_num, None),
            ("KSEI_LOCAL_TOTAL", "KSEI local scripless holdings", local_total, local_pct, "LOCAL"),
            ("KSEI_FOREIGN_TOTAL", "KSEI foreign scripless holdings", foreign_total, foreign_pct, "FOREIGN"),
        ]
        for classification, holder_name, shares, pct, state in definitions:
            rows.append(
                {
                    **common,
                    "holder_identity_hash": _holder_hash(ticker, classification),
                    "holder_name": holder_name,
                    "shares_held": shares,
                    "ownership_percentage": pct,
                    "holder_classification": classification,
                    "local_foreign_state": state,
                }
            )

    meta = {
        "report_date": report_date,
        "source_url": source_url,
        "zip_sha256": zip_hash,
        "text_sha256": text_hash,
        "source_equity_tickers": len(source_tickers),
        "universe_tickers": len(accepted_tickers),
        "rows": len(rows),
        "invalid_source_rows": invalid,
    }
    return rows, meta


def main() -> int:
    universe = pd.read_csv(UNIVERSE_PATH)
    allowed = {canonical_ticker(v) for v in universe["ticker"] if canonical_ticker(v)}
    if len(allowed) != 700:
        raise RuntimeError(f"expected 700 universe tickers, got {len(allowed)}")

    all_rows: list[dict[str, object]] = []
    reports: list[dict[str, object]] = []
    for token in REPORT_DATES:
        raw, url = _download(token)
        rows, meta = _parse_archive(raw, url, allowed)
        all_rows.extend(rows)
        reports.append(meta)
        print(json.dumps(meta, sort_keys=True))

    frame = pd.DataFrame(all_rows)
    if frame.empty:
        raise RuntimeError("KSEI backfill produced no rows")
    frame = frame.drop_duplicates(
        ["ticker", "report_date", "category", "holder_identity_hash"], keep="last"
    ).sort_values(["report_date", "ticker", "holder_classification"], kind="stable")

    # Strong validation of the latest archive: every scanner ticker should have four canonical rows.
    latest = frame[frame["report_date"].eq("2026-08-31")]
    latest_counts = latest.groupby("ticker")["holder_classification"].nunique()
    latest_complete = int((latest_counts == 4).sum())
    if latest_complete < 690:
        raise RuntimeError(f"latest KSEI coverage unexpectedly low: {latest_complete}/700")

    OUT_CSV.parent.mkdir(parents=True, exist_ok=True)
    frame.to_csv(OUT_CSV, index=False, compression="gzip")
    records = frame.where(pd.notna(frame), None).to_dict("records")
    OUT_JSON.write_text(json.dumps(records, ensure_ascii=False, separators=(",", ":"), allow_nan=False), encoding="utf-8")

    foreign = frame[frame["holder_classification"].eq("KSEI_FOREIGN_TOTAL")].copy()
    history_counts = foreign.groupby("ticker")["report_date"].nunique()
    result = {
        "status": "SUCCESS",
        "rows": int(len(frame)),
        "tickers": int(frame["ticker"].nunique()),
        "report_dates": sorted(frame["report_date"].unique().tolist()),
        "latest_complete_tickers": latest_complete,
        "tickers_with_2plus_foreign_snapshots": int((history_counts >= 2).sum()),
        "tickers_with_8_foreign_snapshots": int((history_counts >= 8).sum()),
        "source": "KSEI_OFFICIAL_HOLDING_COMPOSITION_ARCHIVE",
        "provenance_state": PROVENANCE,
        "no_fabricated_evidence": True,
        "reports": reports,
    }
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
