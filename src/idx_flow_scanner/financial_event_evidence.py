from __future__ import annotations

import re
from datetime import date, timedelta
from pathlib import Path
from typing import Any, Callable, Iterable

import numpy as np
import pandas as pd

from .config import ZapiFlowConfig
from .data import canonical_ticker

ROOT = Path(__file__).resolve().parents[2]
DEFAULT_FINANCIAL_CACHE = ROOT / "data" / "cache" / "idx_official_financial_metrics_latest.csv.gz"
FINANCIAL_SOURCE = "IDX_OFFICIAL_XBRL_INSTANCE"
FINANCIAL_PROVENANCE = "VERIFIED_OFFICIAL_IDX_XBRL_STANDARDIZED_METRICS"
ANNOUNCEMENT_SOURCE = "IDX_OFFICIAL_ANNOUNCEMENT"
ANNOUNCEMENT_PROVENANCE = "VERIFIED_OFFICIAL_IDX_ANNOUNCEMENT_METADATA"

_FINANCIAL_CONTEXT: pd.DataFrame | None = None
_ANNOUNCEMENT_CONTEXT: pd.DataFrame | None = None

_DISTRESS = re.compile(
    r"\b(pailit|kepailitan|pkpu|penundaan kewajiban pembayaran utang|gagal bayar|default)\b",
    flags=re.IGNORECASE,
)
_MANAGEMENT = re.compile(r"\b(direksi|direktur|dewan komisaris|komisaris)\b", flags=re.IGNORECASE)
_PUBLIC_EXPOSE = re.compile(r"\bpublic\s+expose\b", flags=re.IGNORECASE)


def _bool_series(series: pd.Series) -> pd.Series:
    if pd.api.types.is_bool_dtype(series):
        return series.fillna(False)
    return series.fillna(False).astype(str).str.strip().str.lower().isin({"1", "true", "yes"})


def _universe_set(universe: Iterable[str] | None) -> set[str]:
    return {canonical_ticker(v) for v in (universe or []) if canonical_ticker(v)}


def _normalize_metrics(frame: pd.DataFrame | None, universe: Iterable[str] | None = None) -> pd.DataFrame:
    if frame is None or frame.empty:
        return pd.DataFrame()
    out = frame.copy()
    out.columns = [str(c).strip().lower() for c in out.columns]
    required = {"ticker", "report_year", "report_period", "source_file_sha256", "metric_validation_state"}
    if not required.issubset(out.columns):
        return pd.DataFrame()
    out["ticker"] = out["ticker"].map(canonical_ticker)
    allowed = _universe_set(universe)
    if allowed:
        out = out[out["ticker"].isin(allowed)].copy()
    out["report_year"] = pd.to_numeric(out["report_year"], errors="coerce")
    out["report_period"] = out["report_period"].fillna("").astype(str).str.upper().str.strip()
    out["report_end_date"] = pd.to_datetime(out.get("report_end_date"), errors="coerce").dt.normalize()
    for col in ("assets", "liabilities", "equity", "revenue", "profit_loss", "operating_cash_flow", "cash_and_equivalents", "source_file_size_bytes"):
        if col not in out.columns:
            out[col] = None
        out[col] = pd.to_numeric(out[col], errors="coerce")
    if "source" not in out.columns:
        out["source"] = FINANCIAL_SOURCE
    if "source_verified" not in out.columns:
        out["source_verified"] = True
    if "provenance_state" not in out.columns:
        out["provenance_state"] = FINANCIAL_PROVENANCE
    if "source_url" not in out.columns:
        out["source_url"] = None
    valid = (
        out["ticker"].ne("")
        & out["report_year"].notna()
        & out["report_period"].isin({"AUDIT", "TW1", "TW2", "TW3"})
        & out["source_file_sha256"].fillna("").astype(str).str.fullmatch(r"[0-9a-f]{64}", na=False)
        & out["metric_validation_state"].fillna("").astype(str).str.startswith("VALIDATED")
        & out["source"].astype(str).eq(FINANCIAL_SOURCE)
        & _bool_series(out["source_verified"])
        & out["provenance_state"].astype(str).eq(FINANCIAL_PROVENANCE)
    )
    return out[valid].copy().reset_index(drop=True)


def load_financial_metrics(store: Any, universe: Iterable[str] | None = None, path: Path | None = None) -> pd.DataFrame:
    frames: list[pd.DataFrame] = []
    cache_path = path or DEFAULT_FINANCIAL_CACHE
    if cache_path.exists():
        try:
            frames.append(_normalize_metrics(pd.read_csv(cache_path), universe))
        except Exception:
            pass
    allowed = list(_universe_set(universe))
    if store is not None:
        rows: list[dict[str, object]] = []
        try:
            if allowed:
                for start in range(0, len(allowed), 40):
                    response = (
                        store.client.table("flow_financial_metrics")
                        .select("*")
                        .in_("ticker", allowed[start:start + 40])
                        .eq("source", FINANCIAL_SOURCE)
                        .eq("source_verified", True)
                        .execute()
                    )
                    rows.extend(response.data or [])
            else:
                response = store.client.table("flow_financial_metrics").select("*").eq("source", FINANCIAL_SOURCE).eq("source_verified", True).limit(2000).execute()
                rows.extend(response.data or [])
        except Exception:
            rows = []
        if rows:
            frames.append(_normalize_metrics(pd.DataFrame(rows), universe))
    frames = [f for f in frames if f is not None and not f.empty]
    if not frames:
        return pd.DataFrame()
    out = pd.concat(frames, ignore_index=True)
    return out.drop_duplicates(["ticker", "report_year", "report_period"], keep="last").reset_index(drop=True)


def upsert_financial_metrics(store: Any, frame: pd.DataFrame | None) -> int:
    clean = _normalize_metrics(frame)
    if store is None or clean.empty:
        return 0
    columns = [
        "ticker", "report_year", "report_period", "report_end_date", "assets", "liabilities", "equity",
        "revenue", "profit_loss", "operating_cash_flow", "cash_and_equivalents", "source_file_sha256",
        "source_file_size_bytes", "metric_validation_state", "source", "source_url", "source_verified", "provenance_state",
    ]
    rows = []
    for item in clean[columns].where(pd.notna(clean[columns]), None).to_dict("records"):
        if isinstance(item.get("report_end_date"), pd.Timestamp):
            item["report_end_date"] = item["report_end_date"].date().isoformat()
        item["report_year"] = int(item["report_year"])
        rows.append(item)
    for start in range(0, len(rows), 250):
        store.client.table("flow_financial_metrics").upsert(rows[start:start + 250], on_conflict="ticker,report_year,report_period").execute()
    return len(rows)


def load_official_announcements(store: Any, universe: Iterable[str] | None = None, *, lookback_calendar_days: int = 120) -> pd.DataFrame | None:
    if store is None:
        return None
    since = (date.today() - timedelta(days=max(30, int(lookback_calendar_days)))).isoformat()
    allowed = list(_universe_set(universe))
    rows: list[dict[str, object]] = []
    try:
        if allowed:
            for start in range(0, len(allowed), 40):
                response = (
                    store.client.table("flow_official_announcements")
                    .select("announcement_id,ticker,announcement_number,announced_at,title,announcement_type,subject,form_id,source,source_verified,provenance_state")
                    .in_("ticker", allowed[start:start + 40])
                    .gte("announced_at", since)
                    .eq("source", ANNOUNCEMENT_SOURCE)
                    .eq("source_verified", True)
                    .execute()
                )
                rows.extend(response.data or [])
        else:
            response = store.client.table("flow_official_announcements").select("*").gte("announced_at", since).eq("source", ANNOUNCEMENT_SOURCE).eq("source_verified", True).limit(5000).execute()
            rows.extend(response.data or [])
    except Exception:
        return None
    if not rows:
        return pd.DataFrame()
    out = pd.DataFrame(rows)
    out["ticker"] = out["ticker"].map(canonical_ticker)
    out["announced_at"] = pd.to_datetime(out["announced_at"], errors="coerce", utc=True).dt.tz_convert(None)
    verified = _bool_series(out["source_verified"])
    out = out[
        out["ticker"].ne("")
        & out["announced_at"].notna()
        & verified
        & out["source"].astype(str).eq(ANNOUNCEMENT_SOURCE)
        & out["provenance_state"].astype(str).eq(ANNOUNCEMENT_PROVENANCE)
    ].copy()
    return out.sort_values(["ticker", "announced_at"], kind="stable").reset_index(drop=True)


def set_financial_event_context(financial: pd.DataFrame | None, announcements: pd.DataFrame | None) -> None:
    global _FINANCIAL_CONTEXT, _ANNOUNCEMENT_CONTEXT
    _FINANCIAL_CONTEXT = None if financial is None else financial.copy()
    _ANNOUNCEMENT_CONTEXT = None if announcements is None else announcements.copy()


def _as_of(price: pd.DataFrame) -> pd.Timestamp | None:
    if price is None or price.empty or "date" not in price.columns:
        return None
    value = pd.to_datetime(price["date"], errors="coerce").max()
    return pd.Timestamp(value).normalize() if pd.notna(value) else None


def _latest_financial(ticker: str, price: pd.DataFrame, frame: pd.DataFrame | None) -> dict[str, object]:
    default = {
        "financial_evidence_available": False,
        "financial_metric_validation_state": None,
        "financial_report_year": None,
        "financial_report_period": None,
        "financial_report_end_date": None,
        "financial_assets": None,
        "financial_liabilities": None,
        "financial_equity": None,
        "financial_revenue": None,
        "financial_profit_loss": None,
        "financial_operating_cash_flow": None,
        "financial_cash_and_equivalents": None,
        "financial_source_file_sha256": None,
    }
    if frame is None or frame.empty:
        return default
    symbol = canonical_ticker(ticker)
    work = frame[frame["ticker"].map(canonical_ticker).eq(symbol)].copy()
    as_of = _as_of(price)
    if work.empty or as_of is None:
        return default
    work["report_end_date"] = pd.to_datetime(work["report_end_date"], errors="coerce").dt.normalize()
    work = work[work["report_end_date"].notna() & work["report_end_date"].le(as_of)].copy()
    if work.empty:
        return default
    rank = {"AUDIT": 0, "TW1": 1, "TW2": 2, "TW3": 3}
    work["_rank"] = work["report_period"].astype(str).str.upper().map(rank).fillna(-1)
    work = work.sort_values(["report_year", "_rank", "report_end_date"], kind="stable")
    row = work.iloc[-1]
    def val(name: str):
        value = pd.to_numeric(row.get(name), errors="coerce")
        return float(value) if pd.notna(value) and np.isfinite(float(value)) else None
    return {
        **default,
        "financial_evidence_available": True,
        "financial_metric_validation_state": str(row.get("metric_validation_state") or ""),
        "financial_report_year": int(row["report_year"]),
        "financial_report_period": str(row["report_period"]),
        "financial_report_end_date": pd.Timestamp(row["report_end_date"]).date().isoformat(),
        "financial_assets": val("assets"),
        "financial_liabilities": val("liabilities"),
        "financial_equity": val("equity"),
        "financial_revenue": val("revenue"),
        "financial_profit_loss": val("profit_loss"),
        "financial_operating_cash_flow": val("operating_cash_flow"),
        "financial_cash_and_equivalents": val("cash_and_equivalents"),
        "financial_source_file_sha256": str(row.get("source_file_sha256") or ""),
    }


def _announcement_features(ticker: str, price: pd.DataFrame, frame: pd.DataFrame | None) -> dict[str, object]:
    default = {
        "official_announcement_feed_available": frame is not None,
        "official_announcement_recent_count": 0,
        "official_announcement_latest_date": None,
        "official_announcement_distress_count": 0,
        "official_announcement_management_change_count": 0,
        "official_announcement_public_expose_count": 0,
        "official_announcement_penalty_points": 0.0,
        "official_announcement_recent_titles": [],
    }
    if frame is None or frame.empty:
        return default
    symbol = canonical_ticker(ticker)
    work = frame[frame["ticker"].map(canonical_ticker).eq(symbol)].copy()
    as_of = _as_of(price)
    if work.empty or as_of is None:
        return default
    work["announced_at"] = pd.to_datetime(work["announced_at"], errors="coerce")
    work = work[work["announced_at"].notna() & work["announced_at"].dt.normalize().le(as_of)].copy()
    recent = work[work["announced_at"].dt.normalize().ge(as_of - timedelta(days=30))].copy()
    if recent.empty:
        return default
    text = (recent["title"].fillna("").astype(str) + " " + recent["subject"].fillna("").astype(str))
    distress = text.str.contains(_DISTRESS, regex=True)
    management = text.str.contains(_MANAGEMENT, regex=True)
    public_expose = text.str.contains(_PUBLIC_EXPOSE, regex=True)
    penalty = 5.0 if bool(distress.any()) else 0.0
    recent = recent.sort_values("announced_at")
    return {
        **default,
        "official_announcement_feed_available": True,
        "official_announcement_recent_count": int(len(recent)),
        "official_announcement_latest_date": pd.Timestamp(recent["announced_at"].max()).date().isoformat(),
        "official_announcement_distress_count": int(distress.sum()),
        "official_announcement_management_change_count": int(management.sum()),
        "official_announcement_public_expose_count": int(public_expose.sum()),
        "official_announcement_penalty_points": penalty,
        "official_announcement_recent_titles": recent["title"].fillna("").astype(str).tail(8).tolist(),
    }


def apply_financial_event_overlay(scan_one: Callable[..., Any], ticker: str, price: pd.DataFrame, **kwargs: object):
    result = scan_one(ticker, price, **kwargs)
    financial = _latest_financial(ticker, price, _FINANCIAL_CONTEXT)
    events = _announcement_features(ticker, price, _ANNOUNCEMENT_CONTEXT)
    diagnostics = dict(getattr(result, "diagnostics", {}) or {})
    diagnostics.update(financial)
    diagnostics.update(events)
    diagnostics["financial_evidence_score_policy"] = "DIAGNOSTIC_ONLY_NO_POSITIVE_ALPHA"
    diagnostics["announcement_score_policy"] = "NO_POSITIVE_ALPHA_DISTRESS_DERATE_ONLY"
    result.diagnostics = diagnostics

    penalty = float(events.get("official_announcement_penalty_points", 0.0) or 0.0)
    if penalty > 0:
        result.final_score = round(float(np.clip(float(result.final_score) - penalty, 0.0, 100.0)), 2)
        reason = "recent official IDX distress announcement"
        existing = str(getattr(result, "guardrail_reason", "") or "").strip()
        result.guardrail_reason = "; ".join(dict.fromkeys([v for v in (existing, reason) if v]))

    config = kwargs.get("config")
    config = config if isinstance(config, ZapiFlowConfig) else ZapiFlowConfig()
    if bool(getattr(result, "production_authorized", False)) and float(result.final_score) < float(config.decision_score_floor):
        result.production_authorized = False
        result.real_money_state = "GUARDED"
        if result.action not in {"REDUCE_AVOID", "RESEARCH_ONLY"}:
            result.action = "WATCHLIST"
        reason = f"event-adjusted score {result.final_score:.1f} below {config.decision_score_floor:.0f}"
        result.guardrail_reason = "; ".join(dict.fromkeys([v for v in (result.guardrail_reason, reason) if v]))
    return result


__all__ = [
    "DEFAULT_FINANCIAL_CACHE",
    "load_financial_metrics",
    "upsert_financial_metrics",
    "load_official_announcements",
    "set_financial_event_context",
    "apply_financial_event_overlay",
]
