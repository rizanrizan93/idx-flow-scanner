from __future__ import annotations

from pathlib import Path
from typing import Any, Callable

import pandas as pd

from .broker_evidence import select_broker_evidence
from .providers.idx_official import load_bundled_idx_official_broker_flows


def _root() -> Path:
    return Path(__file__).resolve().parents[2]


def load_universe_idx_broker(universe: list[str]) -> pd.DataFrame:
    path = _root() / "data" / "cache" / "idx_official_broker_60d.csv.gz"
    return load_bundled_idx_official_broker_flows(universe, path, lookback_calendar_days=180)


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
