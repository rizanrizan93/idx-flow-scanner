from __future__ import annotations

from io import BytesIO
import gzip
from pathlib import Path
from typing import Any, Callable

import pandas as pd
import requests

from .broker_evidence import select_broker_evidence
from .providers.idx_official import load_bundled_idx_official_broker_flows
from .providers.public_idx_participant import load_cache as load_public_participant_cache

CANONICAL_PUBLIC_PARTICIPANT_URL = "https://raw.githubusercontent.com/rizanrizan93/idx-flow-scanner/main/data/cache/idx_public_participant_30d.csv.gz"
LEGACY_PUBLIC_PARTICIPANT_URL = "https://raw.githubusercontent.com/rizanrizan93/pasticuan/main/data/public_broker_flow_30d.csv.gz"


def _root() -> Path:
    return Path(__file__).resolve().parents[2]


def _participant_to_broker(frame: pd.DataFrame) -> pd.DataFrame:
    if not isinstance(frame, pd.DataFrame) or frame.empty:
        return pd.DataFrame()
    required = {"ticker", "trade_date", "participant", "buy_value", "sell_value", "buy_volume", "sell_volume"}
    if not required.issubset(frame.columns):
        # Pasticuan's rolling cache already uses broker_code; normalize its shape
        # directly when that mirror is the available source.
        if not {"ticker", "trade_date", "broker_code"}.issubset(frame.columns):
            return pd.DataFrame()
        out = frame.copy()
    else:
        out = frame.copy()
        out["broker_code"] = out["participant"].astype(str).str.strip().str.upper()
    out["ticker"] = out["ticker"].astype(str).str.upper().str.removesuffix(".JK")
    out["trade_date"] = pd.to_datetime(out["trade_date"], errors="coerce").dt.normalize()
    if "buy_value" in out.columns:
        for column in ("buy_value", "sell_value", "buy_volume", "sell_volume"):
            out[column] = pd.to_numeric(out[column], errors="coerce").fillna(0.0)
        out["buy_avg"] = out["buy_value"].div(out["buy_volume"].replace(0.0, pd.NA))
        out["sell_avg"] = out["sell_value"].div(out["sell_volume"].replace(0.0, pd.NA))
    for column, default in (("buy_value", 0.0), ("sell_value", 0.0), ("buy_volume", 0.0), ("sell_volume", 0.0), ("buy_avg", None), ("sell_avg", None)):
        if column not in out.columns:
            out[column] = default
    out["market_type"] = out.get("market_type", "RG")
    out["source"] = "IDX_OFFICIAL_PUBLIC_TRADE_DETAIL_PARTICIPANT_FLOW"
    out["source_verified"] = True
    out["source_url"] = "https://www.idxdata3.co.id/IDX%20Reporting%20PSPP/Revitalisasi/Trade-Detail-Publik_{date}.csv"
    out["provenance_state"] = "VERIFIED_IDX_PUBLIC_TRADE_DETAIL_PARTICIPANT_FLOW_NOT_BENEFICIAL_OWNER"
    keep = [
        "ticker", "trade_date", "broker_code", "market_type", "buy_value", "sell_value",
        "buy_volume", "sell_volume", "buy_avg", "sell_avg", "source", "source_verified",
        "source_url", "provenance_state",
    ]
    return out[keep].dropna(subset=["ticker", "trade_date", "broker_code"]).drop_duplicates(
        ["ticker", "trade_date", "broker_code", "source"], keep="last"
    )


def _remote_public_participant(universe: list[str]) -> pd.DataFrame:
    for url in (CANONICAL_PUBLIC_PARTICIPANT_URL, LEGACY_PUBLIC_PARTICIPANT_URL):
        try:
            response = requests.get(url, timeout=12, headers={"User-Agent": "IDX-Flow-Scanner-Broker-Reader/1.1"})
            response.raise_for_status()
            raw = pd.read_csv(BytesIO(gzip.decompress(response.content)))
            converted = _participant_to_broker(raw)
            if not converted.empty:
                names = {str(t).upper().removesuffix(".JK") for t in universe}
                return converted[converted["ticker"].isin(names)].reset_index(drop=True)
        except Exception:
            continue
    return pd.DataFrame()


def load_universe_idx_broker(universe: list[str]) -> pd.DataFrame:
    path = _root() / "data" / "cache" / "idx_official_broker_60d.csv.gz"
    direct = load_bundled_idx_official_broker_flows(universe, path, lookback_calendar_days=180)
    # The official stock-level broker endpoint has intermittently returned only a
    # tiny subset of symbols. Use the audited public Trade Detail participant flow
    # to restore universe coverage without inventing broker identity or changing
    # evidence provenance. Direct stock-level summary still wins on duplicates.
    canonical_path = _root() / "data" / "cache" / "idx_public_participant_30d.csv.gz"
    try:
        participant = load_public_participant_cache(universe, canonical_path, lookback_calendar_days=120)
    except Exception:
        participant = pd.DataFrame()
    public = _participant_to_broker(participant)
    if public.empty:
        public = _remote_public_participant(universe)
    if direct.empty:
        return public
    if public.empty:
        return direct
    combined = pd.concat([direct, public], ignore_index=True, sort=False)
    priority = combined["source"].astype(str).str.contains("IDX_OFFICIAL_BROKER_SUMMARY", na=False).astype(int)
    combined["_priority"] = priority
    combined = combined.sort_values(["ticker", "trade_date", "broker_code", "_priority"], ascending=[True, True, True, False], kind="stable")
    return combined.drop_duplicates(["ticker", "trade_date", "broker_code"], keep="first").drop(columns=["_priority"], errors="ignore").reset_index(drop=True)


def install_universe_wide_idx_broker(streamlit_app: Any) -> None:
    """Inject official IDX broker evidence without changing the Top-5 provider budget.

    The first scan pass receives universe-wide IDX broker evidence from the bundled
    audited cache. Index Alpha remains a finalist-only enrichment source. For the
    second pass, provider selection is performed per ticker-day so identical direct
    evidence from multiple providers is never counted twice.
    """
    original_scan_universe: Callable[..., Any] = streamlit_app.scan_universe
    original_finalist_loader: Callable[..., Any] = streamlit_app._load_indexalpha_for_finalists

    def scan_with_universe_broker(
        universe,
        price_loader,
        broker_frame,
        config=None,
        progress=None,
        run_id=None,
        official_flow_frame=None,
    ):
        official_broker = load_universe_idx_broker(list(universe))
        incoming = broker_frame if broker_frame is not None and not broker_frame.empty else pd.DataFrame()
        if incoming.empty:
            combined = official_broker
        elif official_broker.empty:
            combined = incoming
        else:
            combined = pd.concat([official_broker, incoming], ignore_index=True)
            try:
                combined, _ = select_broker_evidence(combined)
            except Exception:
                pass
        return original_scan_universe(
            universe,
            price_loader,
            combined,
            config,
            progress,
            run_id=run_id,
            official_flow_frame=official_flow_frame,
        )

    def finalist_loader_with_idx(
        finalists,
        load_price,
        store,
        *,
        allow_live_pull,
    ):
        indexalpha_frame, stats = original_finalist_loader(
            finalists,
            load_price,
            store,
            allow_live_pull=allow_live_pull,
        )
        official = load_universe_idx_broker(list(finalists))
        if official.empty:
            stats["universe_idx_broker_rows"] = 0
            stats["universe_idx_broker_tickers"] = 0
            return indexalpha_frame, stats
        combined = pd.concat([official, indexalpha_frame], ignore_index=True) if indexalpha_frame is not None and not indexalpha_frame.empty else official
        try:
            combined, selector_stats = select_broker_evidence(combined)
            stats["universe_idx_broker_selector"] = selector_stats
        except Exception:
            pass
        stats["universe_idx_broker_rows"] = int(len(official))
        stats["universe_idx_broker_tickers"] = int(official["ticker"].nunique())
        return combined, stats

    streamlit_app.scan_universe = scan_with_universe_broker
    streamlit_app._load_indexalpha_for_finalists = finalist_loader_with_idx