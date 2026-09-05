from __future__ import annotations

from pathlib import Path
from typing import Iterable

import pandas as pd

from .data import canonical_ticker
from .providers.zapi import ZAPI_STOCK_SUMMARY_URL, ZapiUnavailable, _get_json

TARGET_UNIVERSE_SIZE = 700
ZAPI_COMPANIES_URL = "https://api.zpi.web.id/v1/finance:idx/companies"

_SECTOR_MAP = {
    "energi": "Energy",
    "energy": "Energy",
    "barang baku": "Basic Materials",
    "basic materials": "Basic Materials",
    "perindustrian": "Industrials",
    "industrials": "Industrials",
    "barang konsumen primer": "Consumer Non-Cyclicals",
    "consumer non-cyclicals": "Consumer Non-Cyclicals",
    "barang konsumen non-primer": "Consumer Cyclicals",
    "consumer cyclicals": "Consumer Cyclicals",
    "kesehatan": "Healthcare",
    "healthcare": "Healthcare",
    "keuangan": "Financials",
    "financials": "Financials",
    "properti & real estat": "Properties & Real Estate",
    "properti dan real estat": "Properties & Real Estate",
    "properties & real estate": "Properties & Real Estate",
    "teknologi": "Technology",
    "technology": "Technology",
    "infrastruktur": "Infrastructures",
    "infrastructures": "Infrastructures",
    "transportasi & logistik": "Transportation & Logistic",
    "transportasi dan logistik": "Transportation & Logistic",
    "transportation & logistic": "Transportation & Logistic",
}


def normalize_sector(value: object) -> str:
    text = str(value or "").strip()
    if not text or text.lower() in {"nan", "none", "null"}:
        return "UNKNOWN"
    return _SECTOR_MAP.get(text.lower(), text)


def _numeric(value: object) -> float:
    out = pd.to_numeric(value, errors="coerce")
    return float(out) if pd.notna(out) else 0.0


def fetch_zapi_listed_companies(
    *,
    api_key: str,
    timeout: float = 30.0,
) -> pd.DataFrame:
    """Fetch current IDX listed-stock master from ZAPI's IDX companies endpoint."""
    key = str(api_key or "").strip()
    if not key:
        return pd.DataFrame()
    payload = _get_json(
        ZAPI_COMPANIES_URL,
        {"length": 1000, "start": 0},
        key,
        timeout,
    )
    rows = payload.get("data") if isinstance(payload, dict) else None
    if not isinstance(rows, list):
        return pd.DataFrame()

    normalized: list[dict[str, object]] = []
    for item in rows:
        if not isinstance(item, dict):
            continue
        if item.get("EfekEmiten_Saham") is False:
            continue
        ticker = canonical_ticker(item.get("KodeEmiten") or item.get("Code"))
        if not ticker:
            continue
        normalized.append(
            {
                "ticker": ticker,
                "sector": normalize_sector(item.get("Sektor") or item.get("Sector")),
                "board": str(item.get("PapanPencatatan") or item.get("ListingBoard") or "").strip(),
                "listing_date": item.get("TanggalPencatatan") or item.get("ListingDate"),
            }
        )
    if not normalized:
        return pd.DataFrame()
    return (
        pd.DataFrame(normalized)
        .drop_duplicates("ticker", keep="last")
        .sort_values("ticker", kind="stable")
        .reset_index(drop=True)
    )


def fetch_zapi_latest_stock_activity(
    *,
    api_key: str,
    timeout: float = 30.0,
) -> pd.DataFrame:
    """Fetch the latest full IDX stock-summary page for liquidity ranking."""
    key = str(api_key or "").strip()
    if not key:
        return pd.DataFrame()
    payload = _get_json(
        ZAPI_STOCK_SUMMARY_URL,
        {"length": 1000, "start": 0},
        key,
        timeout,
    )
    rows = payload.get("data") if isinstance(payload, dict) else None
    if not isinstance(rows, list):
        return pd.DataFrame()

    normalized: list[dict[str, object]] = []
    for item in rows:
        if not isinstance(item, dict):
            continue
        ticker = canonical_ticker(item.get("StockCode") or item.get("code"))
        if not ticker:
            continue
        delisting = str(item.get("DelistingDate") or "").strip()
        if delisting and delisting.lower() not in {"nan", "none", "null"}:
            continue
        normalized.append(
            {
                "ticker": ticker,
                "traded_value": _numeric(item.get("Value")),
                "frequency": _numeric(item.get("Frequency")),
                "volume": _numeric(item.get("Volume")),
                "close": _numeric(item.get("Close")),
                "trade_date": item.get("Date"),
            }
        )
    if not normalized:
        return pd.DataFrame()
    return pd.DataFrame(normalized).drop_duplicates("ticker", keep="last").reset_index(drop=True)


def _normalize_base(base_frame: pd.DataFrame) -> pd.DataFrame:
    if base_frame is None or base_frame.empty:
        return pd.DataFrame(columns=["ticker", "sector"])
    out = base_frame.copy()
    out.columns = [str(c).strip().lower() for c in out.columns]
    if "ticker" not in out.columns:
        raise ValueError("Base universe requires ticker column")
    if "sector" not in out.columns:
        out["sector"] = "UNKNOWN"
    out["ticker"] = out["ticker"].map(canonical_ticker)
    out["sector"] = out["sector"].map(normalize_sector)
    return out[out["ticker"].ne("")][["ticker", "sector"]].drop_duplicates("ticker", keep="first")


def build_universe_700_frame(
    base_frame: pd.DataFrame,
    companies_frame: pd.DataFrame,
    activity_frame: pd.DataFrame,
    *,
    target_size: int = TARGET_UNIVERSE_SIZE,
) -> pd.DataFrame:
    """Keep the legacy universe, then add the best current listed stocks to target.

    Additions are ranked by the latest traded value, then frequency and volume.
    This makes the expansion useful for a flow scanner instead of selecting 300
    arbitrary alphabetical names. Listed stocks without an activity row are used
    only as deterministic fill after liquid candidates.
    """
    target = max(1, int(target_size))
    base = _normalize_base(base_frame)
    if len(base) >= target:
        out = base.head(target).copy()
        out["universe_source"] = "BASE"
        return out.reset_index(drop=True)

    companies = companies_frame.copy() if companies_frame is not None else pd.DataFrame()
    if companies.empty or "ticker" not in companies.columns:
        return base.assign(universe_source="BASE").reset_index(drop=True)
    companies.columns = [str(c).strip().lower() for c in companies.columns]
    companies["ticker"] = companies["ticker"].map(canonical_ticker)
    if "sector" not in companies.columns:
        companies["sector"] = "UNKNOWN"
    companies["sector"] = companies["sector"].map(normalize_sector)
    companies = companies[companies["ticker"].ne("")].drop_duplicates("ticker", keep="last")

    activity = activity_frame.copy() if activity_frame is not None else pd.DataFrame()
    if activity.empty or "ticker" not in activity.columns:
        activity = pd.DataFrame(columns=["ticker", "traded_value", "frequency", "volume"])
    else:
        activity.columns = [str(c).strip().lower() for c in activity.columns]
        activity["ticker"] = activity["ticker"].map(canonical_ticker)
        for col in ("traded_value", "frequency", "volume"):
            if col not in activity.columns:
                activity[col] = 0.0
            activity[col] = pd.to_numeric(activity[col], errors="coerce").fillna(0.0)
        activity = activity.drop_duplicates("ticker", keep="last")

    base_names = set(base["ticker"])
    ranked = companies.merge(
        activity[["ticker", "traded_value", "frequency", "volume"]],
        on="ticker",
        how="left",
    )
    for col in ("traded_value", "frequency", "volume"):
        ranked[col] = pd.to_numeric(ranked[col], errors="coerce").fillna(0.0)
    ranked = ranked[~ranked["ticker"].isin(base_names)].copy()
    ranked = ranked.sort_values(
        ["traded_value", "frequency", "volume", "ticker"],
        ascending=[False, False, False, True],
        kind="stable",
    )

    need = target - len(base)
    additions = ranked.head(need)[["ticker", "sector"]].copy()
    if len(additions) < need:
        selected = base_names | set(additions["ticker"])
        fill = (
            companies[~companies["ticker"].isin(selected)]
            .sort_values("ticker", kind="stable")
            .head(need - len(additions))[["ticker", "sector"]]
        )
        additions = pd.concat([additions, fill], ignore_index=True)

    base_out = base.copy()
    base_out["universe_source"] = "LEGACY_400"
    additions["universe_source"] = "IDX_ACTIVE_LIQUIDITY_ADD"
    out = pd.concat([base_out, additions], ignore_index=True)
    return out.drop_duplicates("ticker", keep="first").head(target).reset_index(drop=True)


def materialize_universe_700(
    base_path: Path,
    *,
    api_key: str | None,
    output_path: Path,
    target_size: int = TARGET_UNIVERSE_SIZE,
    strict: bool = False,
) -> Path:
    """Materialize a current expanded universe; fall back to base unless strict."""
    base_path = Path(base_path)
    output_path = Path(output_path)
    key = str(api_key or "").strip()
    if not key:
        if strict:
            raise ZapiUnavailable("ZAPI_KEY is required to build the 700-ticker universe")
        return base_path

    try:
        companies = fetch_zapi_listed_companies(api_key=key)
        activity = fetch_zapi_latest_stock_activity(api_key=key)
        expanded = build_universe_700_frame(
            pd.read_csv(base_path),
            companies,
            activity,
            target_size=target_size,
        )
    except Exception:
        if strict:
            raise
        return base_path

    if len(expanded) != int(target_size):
        if strict:
            raise RuntimeError(
                f"Universe expansion incomplete: expected {target_size}, got {len(expanded)}"
            )
        return base_path

    output_path.parent.mkdir(parents=True, exist_ok=True)
    expanded.to_csv(output_path, index=False)
    return output_path
