from __future__ import annotations

import json
from typing import Any

import pandas as pd

VERIFIED_FLOW_TIERS = frozenset({"OFFICIAL_IDX_FLOW", "ZAPI_FLOW"})


def _diag(value: object) -> dict[str, object]:
    if isinstance(value, dict):
        return value
    if isinstance(value, str) and value.strip():
        try:
            parsed = json.loads(value)
            return parsed if isinstance(parsed, dict) else {}
        except Exception:
            return {}
    return {}


def _truthy(value: object) -> bool:
    if isinstance(value, bool):
        return value
    return str(value or "").strip().lower() in {"1", "true", "yes", "y", "verified"}


def summarize_effective_evidence(results: pd.DataFrame | None) -> dict[str, int]:
    """Summarize evidence actually attached to scored scan rows.

    This deliberately does not count pre-scan source frames. The UI truth contract
    is based on the final scored rows that users can act on.
    """
    if results is None or results.empty:
        return {
            "total": 0,
            "verified_flow": 0,
            "official_flow": 0,
            "fallback_flow": 0,
            "price_proxy": 0,
            "stock_structure": 0,
            "ownership": 0,
            "ownership_ksei_controller": 0,
            "ownership_controller_only": 0,
            "corporate_action_history": 0,
            "recent_corporate_actions": 0,
        }

    work = results.copy()
    tiers = work.get("evidence_tier", pd.Series("", index=work.index)).fillna("").astype(str)
    diagnostics = work.get("diagnostics", pd.Series([{} for _ in range(len(work))], index=work.index)).map(_diag)

    stock_structure = 0
    ownership = 0
    ownership_ksei_controller = 0
    ownership_controller_only = 0
    corporate_action_history = 0
    recent_corporate_actions = 0

    for diag in diagnostics:
        listed = pd.to_numeric(diag.get("listed_shares"), errors="coerce")
        tradable = pd.to_numeric(diag.get("tradable_shares"), errors="coerce")
        if pd.notna(listed) and pd.notna(tradable) and float(listed) > 0 and float(tradable) > 0:
            stock_structure += 1

        ownership_available = _truthy(diag.get("ownership_available")) or _truthy(
            diag.get("official_controller_profile_available")
        )
        if ownership_available:
            ownership += 1
            basis = str(diag.get("ownership_score_basis") or "").upper()
            if basis.startswith("KSEI_"):
                ownership_ksei_controller += 1
            elif _truthy(diag.get("official_controller_profile_available")):
                ownership_controller_only += 1

        if _truthy(diag.get("corporate_action_available")):
            corporate_action_history += 1
        recent = diag.get("recent_corporate_actions")
        if isinstance(recent, list) and len(recent) > 0:
            recent_corporate_actions += 1

    return {
        "total": int(len(work)),
        "verified_flow": int(tiers.isin(VERIFIED_FLOW_TIERS).sum()),
        "official_flow": int(tiers.eq("OFFICIAL_IDX_FLOW").sum()),
        "fallback_flow": int(tiers.eq("ZAPI_FLOW").sum()),
        "price_proxy": int(tiers.eq("PRICE_PROXY").sum()),
        "stock_structure": int(stock_structure),
        "ownership": int(ownership),
        "ownership_ksei_controller": int(ownership_ksei_controller),
        "ownership_controller_only": int(ownership_controller_only),
        "corporate_action_history": int(corporate_action_history),
        "recent_corporate_actions": int(recent_corporate_actions),
    }


def load_calibration_truth(
    store: Any,
    *,
    page_size: int = 1000,
    max_rows: int = 30000,
) -> dict[str, object]:
    """Read canonical OOS memory counts for display only.

    No signal generation or production weight is mutated. Pagination avoids the
    PostgREST response cap and keeps the UI numbers aligned with canonical DB.
    """
    empty = {
        "available": False,
        "total": 0,
        "mature_5d": 0,
        "mature_20d": 0,
        "mature_60d": 0,
        "pending": 0,
        "partial": 0,
        "complete": 0,
        "excluded": 0,
        "truncated": False,
    }
    if store is None:
        return empty

    size = max(1, min(int(page_size), 1000))
    limit = max(size, int(max_rows))
    rows: list[dict[str, object]] = []
    offset = 0
    try:
        while len(rows) < limit:
            end = min(offset + size - 1, limit - 1)
            response = (
                store.client.table("flow_signal_outcomes")
                .select("as_of_date,return_5d,return_20d,return_60d,evaluation_status")
                .order("as_of_date")
                .range(offset, end)
                .execute()
            )
            batch = list(response.data or [])
            rows.extend(batch)
            if len(batch) < (end - offset + 1):
                break
            offset = end + 1
    except Exception:
        return empty

    if not rows:
        return {**empty, "available": True}

    frame = pd.DataFrame(rows)
    status = frame.get("evaluation_status", pd.Series("", index=frame.index)).fillna("").astype(str).str.upper()
    mature_5d = pd.to_numeric(frame.get("return_5d"), errors="coerce").notna().sum()
    mature_20d = pd.to_numeric(frame.get("return_20d"), errors="coerce").notna().sum()
    mature_60d = pd.to_numeric(frame.get("return_60d"), errors="coerce").notna().sum()
    return {
        "available": True,
        "total": int(len(frame)),
        "mature_5d": int(mature_5d),
        "mature_20d": int(mature_20d),
        "mature_60d": int(mature_60d),
        "pending": int(status.eq("PENDING").sum()),
        "partial": int(status.eq("PARTIAL").sum()),
        "complete": int(status.eq("COMPLETE").sum()),
        "excluded": int(status.eq("EXCLUDED").sum()),
        "truncated": bool(len(rows) >= limit),
    }


__all__ = ["summarize_effective_evidence", "load_calibration_truth"]
