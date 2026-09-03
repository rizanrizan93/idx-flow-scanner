from __future__ import annotations

from datetime import date, datetime, timezone
from io import BytesIO
import hashlib
import math
import re
from typing import Any, Iterable, Mapping
from urllib.parse import urlparse

import pandas as pd

from ..data import canonical_ticker
from .zapi import ZapiQuotaExhausted, ZapiUnavailable, _key

OWNERSHIP_INDEX_URL = "https://api.zpi.web.id/v1/finance:idx/ownership-files"
OWNERSHIP_CATEGORIES = ("lima-persen", "satu-persen", "klasifikasi", "tipe")
OWNERSHIP_INDEX_PAGE_SIZE = 200
OWNERSHIP_MAX_INDEX_PAGES = 3
MAX_OWNERSHIP_FILE_BYTES = 50 * 1024 * 1024

CAPITAL_ACTION_FEEDS: dict[str, str] = {
    "issued-history": "https://api.zpi.web.id/v1/finance:idx/issued-history",
    "additional-listings": "https://api.zpi.web.id/v1/finance:idx/additional-listings",
    "rights-offerings": "https://api.zpi.web.id/v1/finance:idx/rights-offerings",
    "stock-splits": "https://api.zpi.web.id/v1/finance:idx/stock-splits",
}
MONTHLY_CAPITAL_ACTION_FEEDS = frozenset(
    {"additional-listings", "rights-offerings", "stock-splits"}
)


def _clean(value: Any) -> str:
    if value is None or (isinstance(value, float) and math.isnan(value)):
        return ""
    return str(value).strip()


def _parse_date(value: Any) -> date | None:
    if isinstance(value, datetime):
        return value.date()
    if isinstance(value, date):
        return value
    text = _clean(value)
    if not text:
        return None

    # ZAPI event/publication fields are frequently ISO YYYY-MM-DD. Parse ISO
    # deterministically before falling back to day-first workbook-style dates;
    # otherwise pandas dayfirst=True can reinterpret 2026-09-10 as 2026-10-09.
    iso = re.match(r"^(\d{4})-(\d{2})-(\d{2})(?:[T\s].*)?$", text)
    if iso:
        try:
            return date(int(iso.group(1)), int(iso.group(2)), int(iso.group(3)))
        except ValueError:
            return None

    parsed = pd.to_datetime(text, errors="coerce", dayfirst=True)
    return None if pd.isna(parsed) else pd.Timestamp(parsed).date()


def _number(value: Any, *, percentage: bool = False) -> float | None:
    if isinstance(value, bool) or not _clean(value):
        return None
    text = _clean(value).replace("\u00a0", "").replace(" ", "").replace("%", "")
    if "," in text and "." in text:
        text = text.replace(".", "").replace(",", ".") if text.rfind(",") > text.rfind(".") else text.replace(",", "")
    elif "," in text:
        tail = text.rsplit(",", 1)[-1]
        text = text.replace(",", ".") if percentage or len(tail) != 3 else text.replace(",", "")
    elif text.count(".") > 1:
        text = text.replace(".", "")
    try:
        value_float = float(text)
    except ValueError:
        return None
    return value_float if math.isfinite(value_float) else None


def _official_ownership_url(url: str) -> bool:
    parsed = urlparse(_clean(url))
    host = (parsed.hostname or "").lower()
    return parsed.scheme == "https" and any(
        host == domain or host.endswith(f".{domain}")
        for domain in ("idx.co.id", "ksei.co.id")
    )


def _request_json(
    url: str,
    params: Mapping[str, object],
    *,
    api_key: str,
    timeout: float = 30.0,
) -> dict[str, Any]:
    from curl_cffi import requests as curl_requests

    response = curl_requests.get(
        url,
        params=dict(params),
        headers={
            "Accept": "application/json",
            "User-Agent": "IDX-Flow-Scanner/zapi-slow-evidence",
            "x-api-key": api_key,
        },
        impersonate="chrome",
        timeout=timeout,
        allow_redirects=False,
    )
    if response.status_code == 401:
        raise ZapiUnavailable("Zapi API key invalid or missing")
    if response.status_code == 403:
        raise ZapiUnavailable("Zapi plan does not allow requested endpoint")
    if response.status_code == 429:
        raise ZapiQuotaExhausted("Zapi rate/monthly quota exhausted")
    if 300 <= response.status_code < 400:
        raise ZapiUnavailable(f"Zapi redirect rejected ({response.status_code})")
    if response.status_code != 200:
        raise ZapiUnavailable(f"Zapi HTTP {response.status_code}")
    payload = response.json()
    if not isinstance(payload, dict):
        raise ZapiUnavailable("Zapi returned non-object JSON")
    return payload


def _unwrap_object(payload: Mapping[str, Any]) -> Mapping[str, Any]:
    root: Mapping[str, Any] = payload
    for _ in range(3):
        nested = root.get("data")
        if isinstance(nested, Mapping):
            root = nested
        else:
            break
    return root


def _ownership_index_values(payload: Mapping[str, Any]) -> tuple[list[Mapping[str, Any]], int]:
    root = _unwrap_object(payload)
    values = root.get("data")
    if not isinstance(values, list):
        raise ZapiUnavailable("ownership-files response missing data list")
    rows = [item for item in values if isinstance(item, Mapping)]
    try:
        total = max(len(rows), int(root.get("total") or len(rows)))
    except (TypeError, ValueError):
        total = len(rows)
    return rows, total


def _ownership_field(header: Any) -> str:
    name = re.sub(r"[^a-z0-9%]+", " ", _clean(header).lower()).strip()
    aliases = {
        "ticker": ("kode emiten", "kode saham", "stock code", "ticker", "security code"),
        "holder_name": ("nama pemegang saham", "nama investor", "nama pihak", "shareholder name", "holder name"),
        "shares_held": ("jumlah saham", "total saham", "shares held", "number of shares"),
        "ownership_percentage": ("persentase kepemilikan", "% kepemilikan", "ownership percentage", "percentage"),
        "holder_classification": ("klasifikasi investor", "klasifikasi pemegang", "investor classification", "classification"),
        "holder_type": ("tipe investor", "tipe pemegang", "jenis investor", "investor type", "holder type"),
        "local_foreign_state": ("lokal asing", "domestik asing", "local foreign", "domestic foreign"),
        "report_date": ("tanggal posisi", "tanggal laporan", "report date", "position date"),
    }
    for field, candidates in aliases.items():
        if any(candidate in name for candidate in candidates):
            return field
    return ""


def _ownership_header(frame: pd.DataFrame) -> tuple[int, dict[int, str]] | None:
    for row_number in range(min(40, len(frame))):
        fields = {
            column: _ownership_field(value)
            for column, value in frame.iloc[row_number].items()
        }
        fields = {column: field for column, field in fields.items() if field}
        present = set(fields.values())
        if "ticker" in present and present.intersection(
            {"holder_name", "holder_classification", "holder_type"}
        ):
            return row_number, fields
    return None


def _holder_identity(
    category: str,
    ticker: str,
    holder: str,
    classification: str,
    holder_type: str,
    local_foreign: str,
) -> str:
    basis = "|".join(
        re.sub(r"[^a-z0-9]+", " ", value.lower()).strip()
        for value in (category, ticker, holder, classification, holder_type, local_foreign)
    )
    return hashlib.sha256(basis.encode("utf-8")).hexdigest()


def parse_ownership_workbook(
    content: bytes,
    *,
    category: str,
    publication_date: date,
    source_url: str,
) -> pd.DataFrame:
    if category not in OWNERSHIP_CATEGORIES:
        raise ZapiUnavailable(f"unsupported ownership category: {category}")
    if not _official_ownership_url(source_url):
        raise ZapiUnavailable("ownership file URL is not verified IDX/KSEI HTTPS")
    if not content.startswith(b"PK") or len(content) > MAX_OWNERSHIP_FILE_BYTES:
        raise ZapiUnavailable("ownership workbook content failed integrity gate")
    try:
        sheets = pd.read_excel(BytesIO(content), sheet_name=None, header=None, dtype=object)
    except Exception as exc:
        raise ZapiUnavailable(f"ownership workbook parse failed: {type(exc).__name__}") from exc

    source_hash = hashlib.sha256(content).hexdigest()
    rows: list[dict[str, object]] = []
    for frame in sheets.values():
        if not isinstance(frame, pd.DataFrame) or frame.empty:
            continue
        header = _ownership_header(frame)
        if header is None:
            continue
        row_number, columns = header
        for _, raw in frame.iloc[row_number + 1 :].iterrows():
            values = {field: raw.get(column) for column, field in columns.items()}
            ticker = canonical_ticker(values.get("ticker"))
            if not ticker:
                continue
            holder = _clean(values.get("holder_name"))
            classification = _clean(values.get("holder_classification"))
            holder_type = _clean(values.get("holder_type"))
            local_foreign = _clean(values.get("local_foreign_state")).upper()
            if category in {"lima-persen", "satu-persen"} and not holder:
                continue
            if category == "klasifikasi" and not classification:
                continue
            if category == "tipe" and not holder_type:
                continue

            shares = _number(values.get("shares_held"))
            percentage = _number(values.get("ownership_percentage"), percentage=True)
            if shares is None and percentage is None:
                continue
            if shares is not None and shares < 0:
                raise ZapiUnavailable("negative ownership share count")
            if percentage is not None and not 0 <= percentage <= 100:
                raise ZapiUnavailable("ownership percentage outside 0..100")
            report_date = _parse_date(values.get("report_date"))
            if report_date is None or report_date > publication_date:
                raise ZapiUnavailable("ownership report date missing or after publication")
            rows.append(
                {
                    "ticker": ticker,
                    "category": category,
                    "holder_identity_hash": _holder_identity(
                        category,
                        ticker,
                        holder,
                        classification,
                        holder_type,
                        local_foreign,
                    ),
                    "holder_name": holder or None,
                    "shares_held": shares,
                    "ownership_percentage": percentage,
                    "holder_classification": classification or None,
                    "holder_type": holder_type or None,
                    "local_foreign_state": local_foreign or None,
                    "report_date": report_date.isoformat(),
                    "publication_date": publication_date.isoformat(),
                    "source_url": source_url,
                    "source_file_hash": source_hash,
                    "source_verified": True,
                    "provenance_state": "VERIFIED_IDX_KSEI_FILE_VIA_ZAPI_INDEX",
                }
            )
    if not rows:
        raise ZapiUnavailable("ownership workbook contained no normalized evidence")
    report_dates = {row["report_date"] for row in rows}
    if len(report_dates) != 1:
        raise ZapiUnavailable("ownership workbook mixes report periods")
    return pd.DataFrame(rows)


def _download_ownership_file(url: str, *, timeout: float = 30.0) -> bytes:
    if not _official_ownership_url(url):
        raise ZapiUnavailable("ownership file URL is not verified IDX/KSEI HTTPS")
    from curl_cffi import requests as curl_requests

    response = curl_requests.get(
        url,
        headers={
            "Accept": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet,application/octet-stream",
            "User-Agent": "IDX-Flow-Scanner/ownership-file",
        },
        impersonate="chrome",
        timeout=timeout,
        allow_redirects=False,
    )
    if 300 <= response.status_code < 400:
        raise ZapiUnavailable("ownership file redirect rejected")
    if response.status_code != 200:
        raise ZapiUnavailable(f"ownership file HTTP {response.status_code}")
    content = bytes(response.content)
    if not content.startswith(b"PK") or len(content) > MAX_OWNERSHIP_FILE_BYTES:
        raise ZapiUnavailable("ownership file content failed integrity gate")
    return content


def fetch_latest_zapi_ownership(
    *,
    api_key: str | None = None,
    categories: Iterable[str] = OWNERSHIP_CATEGORIES,
    timeout: float = 30.0,
) -> tuple[pd.DataFrame, dict[str, object]]:
    key = _key(api_key)
    if not key:
        return pd.DataFrame(), {"status": "NO_TOKEN", "categories": {}}
    output: list[pd.DataFrame] = []
    category_meta: dict[str, object] = {}

    for raw_category in categories:
        category = _clean(raw_category).lower()
        if category not in OWNERSHIP_CATEGORIES:
            continue
        index_rows: list[Mapping[str, Any]] = []
        total = 0
        calls = 0
        for page in range(OWNERSHIP_MAX_INDEX_PAGES):
            start = page * OWNERSHIP_INDEX_PAGE_SIZE
            payload = _request_json(
                OWNERSHIP_INDEX_URL,
                {"category": category, "length": OWNERSHIP_INDEX_PAGE_SIZE, "start": start},
                api_key=key,
                timeout=timeout,
            )
            calls += 1
            page_rows, total = _ownership_index_values(payload)
            index_rows.extend(
                item for item in page_rows if _clean(item.get("category")).lower() == category
            )
            if start + OWNERSHIP_INDEX_PAGE_SIZE >= total:
                break
        candidates = []
        for item in index_rows:
            published = _parse_date(item.get("publishedAt"))
            url = _clean(item.get("url"))
            if published and _official_ownership_url(url):
                candidates.append((published, url, _clean(item.get("fileName"))))
        if not candidates:
            category_meta[category] = {"status": "NO_FILE", "api_calls": calls}
            continue
        latest_date = max(item[0] for item in candidates)
        latest = [item for item in candidates if item[0] == latest_date]
        if len(latest) != 1:
            raise ZapiUnavailable(f"ownership category {category} has ambiguous latest publication")
        published, url, file_name = latest[0]
        content = _download_ownership_file(url, timeout=timeout)
        frame = parse_ownership_workbook(
            content,
            category=category,
            publication_date=published,
            source_url=url,
        )
        output.append(frame)
        category_meta[category] = {
            "status": "UPDATED",
            "api_calls": calls,
            "file_calls": 1,
            "publication_date": published.isoformat(),
            "report_date": str(frame["report_date"].iloc[0]),
            "rows": int(len(frame)),
            "tickers": int(frame["ticker"].nunique()),
            "file_name": file_name or None,
        }
    merged = pd.concat(output, ignore_index=True) if output else pd.DataFrame()
    if not merged.empty:
        merged = merged.drop_duplicates(
            ["source_file_hash", "ticker", "holder_identity_hash"],
            keep="last",
        ).sort_values(["category", "report_date", "ticker"], kind="stable").reset_index(drop=True)
    return merged, {"status": "UPDATED" if output else "NO_DATA", "categories": category_meta}


def _capital_feed_rows(payload: Mapping[str, Any], *, feed: str) -> tuple[list[Mapping[str, Any]], bool]:
    root: Mapping[str, Any] = payload
    for _ in range(3):
        nested = root.get("data")
        if isinstance(nested, Mapping) and any(
            key in nested for key in ("dataset", "provider", "items")
        ):
            root = nested
        else:
            break
    if _clean(root.get("dataset")).lower() != feed or _clean(root.get("provider")).lower() != "idx":
        raise ZapiUnavailable(f"{feed} response provenance mismatch")
    values = root.get("items")
    if not isinstance(values, list) or any(not isinstance(item, Mapping) for item in values):
        raise ZapiUnavailable(f"{feed} response missing items list")
    rows = list(values)
    if "hasMore" in root:
        has_more = bool(root.get("hasMore"))
    elif feed == "issued-history":
        start = int(root.get("start") or 0)
        length = int(root.get("length") or 500)
        total = int(root.get("total") or len(rows))
        has_more = start + max(1, length) < total
    else:
        page = int(root.get("page") or 1)
        length = int(root.get("length") or 200)
        total = int(root.get("total") or len(rows))
        has_more = page * max(1, length) < total
    return rows, has_more


def _first(item: Mapping[str, Any], names: Iterable[str]) -> Any:
    for name in names:
        if name in item and item.get(name) not in (None, ""):
            return item.get(name)
    return None


def _capital_event_type(feed: str, raw_action: str) -> str:
    action = re.sub(r"[^a-z0-9]+", " ", raw_action.lower()).strip()
    explicit = {
        "reverse stock split": "REVERSE_STOCK_SPLIT",
        "stock consolidation": "REVERSE_STOCK_SPLIT",
        "stock split": "STOCK_SPLIT",
        "waran": "WARRANT_EXERCISE",
        "warrant": "WARRANT_EXERCISE",
        "warrant exercise": "WARRANT_EXERCISE",
        "rights issue": "RIGHTS_ISSUE",
        "right issue": "RIGHTS_ISSUE",
        "hmetd": "RIGHTS_ISSUE",
        "hm etd": "RIGHTS_ISSUE",
        "conversion": "CONVERSION",
        "konversi": "CONVERSION",
        "bonus shares": "BONUS_SHARES",
        "saham bonus": "BONUS_SHARES",
        "private placement": "PRIVATE_PLACEMENT",
        "non preemptive": "PRIVATE_PLACEMENT",
    }
    defaults = {
        "issued-history": "ISSUED_SHARES_OTHER",
        "additional-listings": "ADDITIONAL_LISTING",
        "rights-offerings": "RIGHTS_OFFERING",
        "stock-splits": "STOCK_SPLIT",
    }
    return explicit.get(action, defaults[feed])


def _capital_share_facts(item: Mapping[str, Any], *, feed: str) -> tuple[float | None, float | None, float | None, float | None]:
    pre = _number(_first(item, ("sharesBefore", "preShares", "beforeShares", "previousShares", "oldShares", "totalSharesBefore")))
    post = _number(_first(item, ("sharesAfter", "postShares", "afterShares", "totalSharesAfter")))
    if feed == "issued-history":
        delta_names = ("shares", "deltaShares", "sharesChange")
    elif feed == "additional-listings":
        delta_names = ("additionalShares", "deltaShares", "sharesChange", "shares", "numberOfShares")
    elif feed == "rights-offerings":
        delta_names = ("newSharesIssued", "offeredShares", "deltaShares", "sharesChange", "numberOfShares")
    else:
        delta_names = ("deltaShares", "sharesChange")
    delta = _number(_first(item, delta_names))
    explicit_percent = _number(_first(item, ("deltaPercent", "sharesChangePercent", "changePercent")), percentage=True)
    if pre is not None and post is not None:
        derived_delta = post - pre
        if delta is not None and not math.isclose(derived_delta, delta, rel_tol=1e-9, abs_tol=1e-6):
            raise ZapiUnavailable("capital-action share facts conflict")
        delta = derived_delta
    elif delta is not None and post is not None:
        pre = post - delta
    elif pre is not None and delta is not None:
        post = pre + delta

    delta_percent = explicit_percent
    if delta is not None and pre not in (None, 0):
        derived_pct = delta / pre * 100.0
        if explicit_percent is not None and not math.isclose(derived_pct, explicit_percent, rel_tol=1e-7, abs_tol=1e-5):
            raise ZapiUnavailable("capital-action percentage conflicts with share facts")
        delta_percent = derived_pct
    return pre, post, delta, delta_percent


def normalize_zapi_capital_actions(
    items: Iterable[Mapping[str, Any]],
    *,
    feed: str,
    source_period: date,
    observed_on: date,
) -> pd.DataFrame:
    if feed not in CAPITAL_ACTION_FEEDS:
        raise ZapiUnavailable(f"unsupported capital-action feed: {feed}")
    rows: list[dict[str, object]] = []
    for item in items:
        ticker = canonical_ticker(_first(item, ("code", "ticker", "stockCode", "KodeEmiten")))
        if not ticker:
            continue
        if feed == "additional-listings":
            start_date = _parse_date(item.get("startDate"))
            end_date = _parse_date(item.get("lastDate"))
            if not start_date or not end_date or start_date > end_date:
                raise ZapiUnavailable("additional-listings date span invalid")
            if (end_date.year, end_date.month) != (source_period.year, source_period.month):
                continue
            event_date = end_date
        else:
            event_date = _parse_date(_first(item, ("listingDate", "effectiveDate", "eventDate", "exDate", "date")))
            if not event_date:
                continue
            start_date = end_date = None
            if feed in MONTHLY_CAPITAL_ACTION_FEEDS and (event_date.year, event_date.month) != (source_period.year, source_period.month):
                continue

        raw_action = _clean(_first(item, ("action", "actionType", "eventType", "type")))
        event_type = _capital_event_type(feed, raw_action)
        pre, post, delta, delta_percent = _capital_share_facts(item, feed=feed)
        publication_date = _parse_date(_first(item, ("publicationDate", "publishedAt", "publishedDate")))
        if publication_date and publication_date > observed_on:
            raise ZapiUnavailable("capital-action publication date is in the future")
        rows.append(
            {
                "ticker": ticker,
                "event_type": event_type,
                "event_date": event_date.isoformat(),
                "event_start_date": start_date.isoformat() if start_date else None,
                "event_end_date": end_date.isoformat() if end_date else None,
                "publication_date": publication_date.isoformat() if publication_date else None,
                "pre_shares": pre,
                "post_shares": post,
                "delta_shares": delta,
                "delta_percent": delta_percent,
                "ratio_before": _number(_first(item, ("ratioBefore", "oldRatio", "ratioOld"))),
                "ratio_after": _number(_first(item, ("ratioAfter", "newRatio", "ratioNew"))),
                "raw_action": raw_action or None,
                "source_feed": feed,
                "source": f"IDX_{feed.upper().replace('-', '_')}_VIA_ZAPI",
                "source_url": CAPITAL_ACTION_FEEDS[feed],
                "source_verified": True,
                "observed_on": observed_on.isoformat(),
                "provenance_state": "VERIFIED_IDX_DATASET_VIA_ZAPI",
            }
        )
    return pd.DataFrame(rows)


def _month_shift(anchor: date, months_back: int) -> date:
    total = anchor.year * 12 + anchor.month - 1 - months_back
    return date(total // 12, total % 12 + 1, 1)


def fetch_zapi_capital_actions(
    *,
    as_of: date | str,
    api_key: str | None = None,
    months_back: int = 2,
    months_forward: int = 1,
    max_pages: int = 10,
    timeout: float = 30.0,
) -> tuple[pd.DataFrame, dict[str, object]]:
    key = _key(api_key)
    if not key:
        return pd.DataFrame(), {"status": "NO_TOKEN", "feeds": {}}
    observed_on = pd.Timestamp(as_of).date()
    parts: list[pd.DataFrame] = []
    feed_meta: dict[str, object] = {}

    for feed, url in CAPITAL_ACTION_FEEDS.items():
        periods = [observed_on] if feed == "issued-history" else [
            _month_shift(observed_on, offset)
            for offset in range(-max(0, int(months_forward)), max(1, int(months_back)))
        ]
        feed_rows = 0
        calls = 0
        for period in periods:
            items: list[Mapping[str, Any]] = []
            completed = False
            for page_index in range(max(1, int(max_pages))):
                if feed == "issued-history":
                    params = {"length": 500, "start": page_index * 500}
                else:
                    params = {
                        "year": period.year,
                        "month": period.month,
                        "page": page_index + 1,
                        "length": 200,
                    }
                payload = _request_json(url, params, api_key=key, timeout=timeout)
                calls += 1
                page_rows, has_more = _capital_feed_rows(payload, feed=feed)
                if has_more and not page_rows:
                    raise ZapiUnavailable(f"{feed} pagination says more but returned no rows")
                items.extend(page_rows)
                if not has_more:
                    completed = True
                    break
            if not completed:
                raise ZapiUnavailable(f"{feed} exceeded bounded page budget")
            frame = normalize_zapi_capital_actions(
                items,
                feed=feed,
                source_period=period,
                observed_on=observed_on,
            )
            if not frame.empty:
                parts.append(frame)
                feed_rows += len(frame)
            if feed == "issued-history":
                break
        feed_meta[feed] = {"status": "UPDATED", "api_calls": calls, "rows": int(feed_rows)}

    out = pd.concat(parts, ignore_index=True) if parts else pd.DataFrame()
    if not out.empty:
        out = out.drop_duplicates(
            ["ticker", "event_type", "event_date", "source_feed"],
            keep="last",
        ).sort_values(["event_date", "ticker", "event_type"], kind="stable").reset_index(drop=True)
    return out, {"status": "UPDATED", "feeds": feed_meta}
