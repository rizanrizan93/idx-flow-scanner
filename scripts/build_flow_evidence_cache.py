from __future__ import annotations

import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path

import pandas as pd

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "src"
if str(SRC) not in sys.path:
    sys.path.insert(0, str(SRC))

from idx_flow_scanner.managed import load_bundled_universe
from idx_flow_scanner.providers.zapi import (
    ZapiQuotaExhausted,
    ZapiUnavailable,
    fetch_zapi_foreign_flow_history,
    fetch_zapi_stock_summary_day,
    load_bundled_zapi_foreign_flows,
    load_bundled_zapi_stock_summary,
    write_zapi_foreign_cache,
    write_zapi_stock_summary_cache,
)
from idx_flow_scanner.providers.zapi_slow import (
    fetch_latest_zapi_ownership,
    fetch_zapi_capital_actions,
)
from idx_flow_scanner.slow_evidence import (
    load_bundled_zapi_capital_actions,
    load_bundled_zapi_ownership,
)

UNIVERSE_PATH = ROOT / "data" / "universe" / "idx_400_syariah.csv"
CACHE_DIR = ROOT / "data" / "cache"
ZAPI_FOREIGN_CACHE = CACHE_DIR / "zapi_idx_foreign_60d.csv.gz"
ZAPI_FOREIGN_JSON = CACHE_DIR / "zapi_idx_foreign_60d.json"
ZAPI_STOCK_SUMMARY_CACHE = CACHE_DIR / "zapi_stock_summary_latest.csv.gz"
ZAPI_OWNERSHIP_CACHE = CACHE_DIR / "zapi_ownership_latest.csv.gz"
ZAPI_CAPITAL_ACTION_CACHE = CACHE_DIR / "zapi_capital_actions.csv.gz"
META_PATH = CACHE_DIR / "flow_evidence_meta.json"


def _latest_completed_idx_weekday() -> pd.Timestamp:
    now = pd.Timestamp.now(tz="Asia/Jakarta")
    day = now.normalize().tz_localize(None)
    # Do not request today's daily snapshot before the IDX session is safely complete.
    if now.weekday() < 5 and now.hour < 17:
        day -= pd.Timedelta(days=1)
    while day.weekday() >= 5:
        day -= pd.Timedelta(days=1)
    return day


def _stats(frame: pd.DataFrame | None, date_col: str = "trade_date") -> dict[str, object]:
    if frame is None or frame.empty:
        return {"rows": 0, "tickers": 0, "days": 0, "freshest": None}
    dates = (
        pd.to_datetime(frame[date_col], errors="coerce")
        if date_col in frame.columns
        else pd.Series(dtype="datetime64[ns]")
    )
    return {
        "rows": int(len(frame)),
        "tickers": int(frame["ticker"].nunique()) if "ticker" in frame.columns else 0,
        "days": int(dates.dt.normalize().nunique()) if not dates.empty else 0,
        "freshest": (
            str(pd.Timestamp(dates.max()).date())
            if not dates.empty and pd.notna(dates.max())
            else None
        ),
    }


def _merge_foreign(existing: pd.DataFrame, fresh: pd.DataFrame) -> pd.DataFrame:
    parts = [frame.copy() for frame in (existing, fresh) if frame is not None and not frame.empty]
    if not parts:
        return pd.DataFrame()
    out = pd.concat(parts, ignore_index=True)
    out["trade_date"] = pd.to_datetime(out["trade_date"], errors="coerce").dt.normalize()
    out = out.dropna(subset=["ticker", "trade_date"])
    source = out.get("source", pd.Series("", index=out.index)).fillna("").astype(str)
    out["source"] = source
    return out.drop_duplicates(["ticker", "trade_date", "source"], keep="last").sort_values(
        ["ticker", "trade_date", "source"], kind="stable"
    ).reset_index(drop=True)


def _merge_ownership(existing: pd.DataFrame, fresh: pd.DataFrame) -> pd.DataFrame:
    parts = [frame.copy() for frame in (existing, fresh) if frame is not None and not frame.empty]
    if not parts:
        return pd.DataFrame()
    out = pd.concat(parts, ignore_index=True)
    out["report_date"] = pd.to_datetime(out.get("report_date"), errors="coerce").dt.normalize()
    out = out.dropna(subset=["ticker", "report_date"])
    keys = ["category", "report_date", "ticker", "holder_identity_hash"]
    out = out.drop_duplicates([key for key in keys if key in out.columns], keep="last")
    # Keep three reporting periods per category so ownership changes are measurable
    # without allowing this slow evidence cache to grow without bound.
    kept: list[pd.DataFrame] = []
    if "category" in out.columns:
        for _, group in out.groupby("category", observed=True):
            dates = sorted(group["report_date"].dropna().unique(), reverse=True)[:3]
            kept.append(group[group["report_date"].isin(dates)].copy())
    else:
        dates = sorted(out["report_date"].dropna().unique(), reverse=True)[:3]
        kept.append(out[out["report_date"].isin(dates)].copy())
    merged = pd.concat(kept, ignore_index=True) if kept else pd.DataFrame()
    if not merged.empty:
        merged["report_date"] = pd.to_datetime(merged["report_date"]).dt.strftime("%Y-%m-%d")
    return merged.sort_values(["category", "report_date", "ticker"], kind="stable").reset_index(drop=True)


def _merge_capital_actions(existing: pd.DataFrame, fresh: pd.DataFrame, *, as_of: pd.Timestamp) -> pd.DataFrame:
    parts = [frame.copy() for frame in (existing, fresh) if frame is not None and not frame.empty]
    if not parts:
        return pd.DataFrame()
    out = pd.concat(parts, ignore_index=True)
    out["event_date"] = pd.to_datetime(out.get("event_date"), errors="coerce").dt.normalize()
    out = out.dropna(subset=["ticker", "event_date"])
    keys = ["ticker", "event_type", "event_date", "source_feed"]
    out = out.drop_duplicates([key for key in keys if key in out.columns], keep="last")
    lower = as_of.normalize() - pd.Timedelta(days=370)
    upper = as_of.normalize() + pd.Timedelta(days=95)
    out = out[out["event_date"].between(lower, upper)].copy()
    out["event_date"] = pd.to_datetime(out["event_date"]).dt.strftime("%Y-%m-%d")
    return out.sort_values(["event_date", "ticker", "event_type"], kind="stable").reset_index(drop=True)


def _write_json_foreign(frame: pd.DataFrame) -> None:
    if frame is None or frame.empty:
        return
    mirror = frame.copy()
    mirror["trade_date"] = pd.to_datetime(mirror["trade_date"], errors="raise").dt.strftime("%Y-%m-%d")
    mirror["source_verified"] = True
    mirror["flow_unit"] = "SHARES"
    mirror["market_type"] = "ALL"
    mirror["source_url"] = mirror["source"].map(
        {
            "ZAPI_IDX_FOREIGN_FLOW": "https://api.zpi.web.id/v1/finance:idx/foreign-flow",
            "ZAPI_IDX_STOCK_SUMMARY": "https://api.zpi.web.id/v1/finance:idx/stock-summary",
        }
    ).fillna("")
    mirror["provenance_state"] = "VERIFIED_ZAPI_IDX_SHARE_FLOW_NOT_BROKER_IDENTITY"
    for column in ("volume", "traded_value"):
        if column not in mirror.columns:
            mirror[column] = 0.0
    cols = [
        "ticker", "trade_date", "foreign_buy", "foreign_sell", "foreign_net",
        "volume", "traded_value", "flow_unit", "market_type", "source",
        "source_verified", "source_url", "provenance_state",
    ]
    ZAPI_FOREIGN_JSON.write_text(
        mirror[cols].sort_values(["ticker", "trade_date", "source"], kind="stable")
        .to_json(orient="records", double_precision=15)
        + "\n",
        encoding="utf-8",
    )


def _fetch_stock_snapshot(universe: list[str], target: pd.Timestamp) -> tuple[pd.DataFrame, str]:
    # A holiday can fall on a weekday. Walk backward only until a real ZAPI stock
    # summary session is found; do not synthesize a date.
    for offset in range(8):
        day = target - pd.Timedelta(days=offset)
        if day.weekday() >= 5:
            continue
        frame = fetch_zapi_stock_summary_day(universe, day.date())
        if frame is not None and not frame.empty:
            return frame, str(day.date())
    return pd.DataFrame(), "NO_DATA"


def main() -> int:
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    universe = load_bundled_universe(UNIVERSE_PATH)
    target = _latest_completed_idx_weekday()
    key_present = bool(str(os.getenv("ZAPI_KEY") or "").strip())

    meta: dict[str, object] = {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "universe_count": len(universe),
        "target_trade_date": str(target.date()),
        "architecture": "ZAPI_ONLY_NO_BROKER_DIRECT",
        "broker_direct": {
            "enabled": False,
            "status": "RETIRED",
            "providers": [],
        },
        "zapi_idx_foreign": {},
        "zapi_stock_summary": {},
        "zapi_ownership": {},
        "zapi_capital_actions": {},
    }

    existing_foreign = load_bundled_zapi_foreign_flows(
        universe, ZAPI_FOREIGN_CACHE, lookback_calendar_days=120
    )
    foreign_target_days = max(20, int(os.getenv("ZAPI_FOREIGN_TARGET_DAYS", "20") or "20"))
    foreign_status = "NO_TOKEN" if not key_present else "UNCHANGED"
    merged_foreign = existing_foreign
    if key_present:
        try:
            cached_dates = (
                pd.to_datetime(existing_foreign["trade_date"], errors="coerce").dropna()
                if not existing_foreign.empty
                else pd.Series(dtype="datetime64[ns]")
            )
            cached_days = int(cached_dates.dt.normalize().nunique()) if not cached_dates.empty else 0
            freshest = cached_dates.max().normalize() if not cached_dates.empty else pd.NaT
            if cached_days >= foreign_target_days and pd.notna(freshest) and freshest >= target.normalize():
                fresh_foreign = pd.DataFrame()
                foreign_status = "PRESERVED"
            else:
                incremental = cached_days >= foreign_target_days
                fresh_foreign = fetch_zapi_foreign_flow_history(
                    universe,
                    end_date=target.date(),
                    target_trading_days=1 if incremental else foreign_target_days,
                    max_calendar_days=8 if incremental else 50,
                )
                foreign_status = "UPDATED" if not fresh_foreign.empty else "NO_DATA"
            merged_foreign = _merge_foreign(existing_foreign, fresh_foreign)
            if not merged_foreign.empty:
                write_zapi_foreign_cache(merged_foreign, ZAPI_FOREIGN_CACHE)
                _write_json_foreign(merged_foreign)
        except ZapiQuotaExhausted as exc:
            foreign_status = f"QUOTA_EXHAUSTED: {exc}"
        except ZapiUnavailable as exc:
            foreign_status = f"UNAVAILABLE: {exc}"
        except Exception as exc:
            foreign_status = f"ERROR: {type(exc).__name__}: {exc}"
    meta["zapi_idx_foreign"] = {
        "status": foreign_status,
        "token_present": key_present,
        "flow_unit": "SHARES",
        "target_history_days": foreign_target_days,
        "refresh_mode": "INCREMENTAL_AFTER_BOOTSTRAP",
        **_stats(merged_foreign),
    }

    existing_stock = load_bundled_zapi_stock_summary(universe, ZAPI_STOCK_SUMMARY_CACHE)
    stock_status = "NO_TOKEN" if not key_present else "UNCHANGED"
    stock_snapshot = existing_stock
    stock_trade_date = None
    if key_present:
        try:
            fresh_stock, stock_trade_date = _fetch_stock_snapshot(universe, target)
            if not fresh_stock.empty:
                stock_snapshot = fresh_stock
                write_zapi_stock_summary_cache(stock_snapshot, ZAPI_STOCK_SUMMARY_CACHE)
                stock_status = "UPDATED"
            else:
                stock_status = "NO_DATA"
        except ZapiQuotaExhausted as exc:
            stock_status = f"QUOTA_EXHAUSTED: {exc}"
        except ZapiUnavailable as exc:
            stock_status = f"UNAVAILABLE: {exc}"
        except Exception as exc:
            stock_status = f"ERROR: {type(exc).__name__}: {exc}"
    free_float_available = 0
    if not stock_snapshot.empty:
        listed = pd.to_numeric(stock_snapshot.get("listed_shares"), errors="coerce")
        tradable = pd.to_numeric(stock_snapshot.get("tradable_shares"), errors="coerce")
        free_float_available = int((listed.gt(0) & tradable.gt(0) & tradable.le(listed * 1.05)).sum())
    meta["zapi_stock_summary"] = {
        "status": stock_status,
        "token_present": key_present,
        "selected_trade_date": stock_trade_date,
        "free_float_structure_rows": free_float_available,
        **_stats(stock_snapshot),
    }

    existing_ownership = load_bundled_zapi_ownership(universe, ZAPI_OWNERSHIP_CACHE)
    slow_weekday = int(os.getenv("ZAPI_OWNERSHIP_REFRESH_WEEKDAY", "0") or "0")
    force_slow = str(os.getenv("ZAPI_FORCE_SLOW_REFRESH", "0")).strip().lower() in {"1", "true", "yes"}
    refresh_ownership = bool(
        key_present
        and (
            existing_ownership.empty
            or force_slow
            or pd.Timestamp.now(tz="Asia/Jakarta").weekday() == slow_weekday
        )
    )
    ownership_status = "NO_TOKEN" if not key_present else "PRESERVED"
    ownership = existing_ownership
    ownership_details: dict[str, object] = {}
    if refresh_ownership:
        try:
            fresh_ownership, ownership_details = fetch_latest_zapi_ownership()
            ownership = _merge_ownership(existing_ownership, fresh_ownership)
            if not ownership.empty:
                ownership.to_csv(ZAPI_OWNERSHIP_CACHE, index=False, compression="gzip")
            ownership_status = str(ownership_details.get("status") or "UPDATED")
        except ZapiQuotaExhausted as exc:
            ownership_status = f"QUOTA_EXHAUSTED: {exc}"
        except ZapiUnavailable as exc:
            ownership_status = f"UNAVAILABLE: {exc}"
        except Exception as exc:
            ownership_status = f"ERROR: {type(exc).__name__}: {exc}"
    report_dates = (
        pd.to_datetime(ownership.get("report_date"), errors="coerce")
        if not ownership.empty
        else pd.Series(dtype="datetime64[ns]")
    )
    meta["zapi_ownership"] = {
        "status": ownership_status,
        "token_present": key_present,
        "refresh_policy": f"WEEKLY_WEEKDAY_{slow_weekday}_OR_MISSING",
        "report_periods": int(report_dates.dt.normalize().nunique()) if not report_dates.empty else 0,
        "latest_report_date": (
            str(pd.Timestamp(report_dates.max()).date())
            if not report_dates.empty and pd.notna(report_dates.max())
            else None
        ),
        "details": ownership_details,
        **_stats(ownership, date_col="report_date"),
    }

    existing_actions = load_bundled_zapi_capital_actions(universe, ZAPI_CAPITAL_ACTION_CACHE)
    action_status = "NO_TOKEN" if not key_present else "PRESERVED"
    actions = existing_actions
    action_details: dict[str, object] = {}
    if key_present:
        try:
            fresh_actions, action_details = fetch_zapi_capital_actions(
                as_of=target.date(),
                months_back=3,
                months_forward=1,
            )
            actions = _merge_capital_actions(existing_actions, fresh_actions, as_of=target)
            if not actions.empty:
                actions.to_csv(ZAPI_CAPITAL_ACTION_CACHE, index=False, compression="gzip")
            action_status = str(action_details.get("status") or "UPDATED")
        except ZapiQuotaExhausted as exc:
            action_status = f"QUOTA_EXHAUSTED: {exc}"
        except ZapiUnavailable as exc:
            action_status = f"UNAVAILABLE: {exc}"
        except Exception as exc:
            action_status = f"ERROR: {type(exc).__name__}: {exc}"
    upcoming = 0
    if not actions.empty and "event_date" in actions.columns:
        dates = pd.to_datetime(actions["event_date"], errors="coerce")
        upcoming = int(dates.ge(target.normalize()).sum())
    meta["zapi_capital_actions"] = {
        "status": action_status,
        "token_present": key_present,
        "upcoming_events": upcoming,
        "details": action_details,
        **_stats(actions, date_col="event_date"),
    }

    META_PATH.write_text(json.dumps(meta, indent=2, sort_keys=True, default=str) + "\n", encoding="utf-8")
    print(json.dumps(meta, indent=2, sort_keys=True, default=str))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
