from __future__ import annotations

import base64
import os
import zlib
from datetime import date, datetime, timedelta, timezone
from io import StringIO
from typing import Iterable

import numpy as np
import pandas as pd

from .data import canonical_ticker, normalize_broker_summary, normalize_price_frame


def _records(frame: pd.DataFrame) -> list[dict]:
    if frame is None or frame.empty:
        return []
    clean = frame.copy()
    clean = clean.replace({np.nan: None})
    out=[]
    for row in clean.to_dict("records"):
        item={}
        for k,v in row.items():
            if isinstance(v, pd.Timestamp):
                item[k]=v.date().isoformat() if v.tzinfo is None else v.isoformat()
            elif hasattr(v, "item"):
                try: item[k]=v.item()
                except Exception: item[k]=v
            else:
                item[k]=v
        out.append(item)
    return out


def decode_legacy_ohlcv_compact(payload_compact: str, codec: str, ticker: str | None = None) -> pd.DataFrame:
    """Decode the former Super Scanner compressed OHLCV cache when explicitly enabled."""
    if not payload_compact or str(codec or "").upper() != "ZLIB_CSV_V1":
        return pd.DataFrame()
    text = str(payload_compact).strip()
    if len(text) > 8_000_000:
        raise ValueError("Legacy OHLCV compact payload exceeds safety limit")
    try:
        compressed = base64.b64decode(text, validate=True)
        raw = zlib.decompress(compressed)
        if len(raw) > 32_000_000:
            raise ValueError("Legacy OHLCV decompressed payload exceeds safety limit")
        frame = pd.read_csv(StringIO(raw.decode("utf-8")))
        return normalize_price_frame(frame, ticker)
    except (ValueError, zlib.error, UnicodeDecodeError) as exc:
        raise ValueError(f"Invalid {codec} OHLCV payload") from exc


class SupabaseStore:
    """Server-side persistence only. Never place SUPABASE_SECRET_KEY in client code."""

    def __init__(self, url: str | None = None, secret_key: str | None = None):
        self.url = url or os.getenv("SUPABASE_URL")
        self.secret_key = secret_key or os.getenv("SUPABASE_SECRET_KEY")
        if not self.url or not self.secret_key:
            raise RuntimeError("SUPABASE_URL and SUPABASE_SECRET_KEY are required")
        if self.secret_key.startswith("sb_publishable_"):
            raise RuntimeError("Backend writes require a secret/service-role key, not a publishable key")
        self.enable_legacy_cache = str(os.getenv("FLOW_ENABLE_LEGACY_CACHE", "0")).strip().lower() in {"1", "true", "yes"}
        from supabase import create_client
        self.client = create_client(self.url, self.secret_key)

    def create_run(self, run_id: str, universe_count: int, config: dict) -> None:
        self.client.table("flow_scan_runs").upsert({
            "id": run_id, "status": "RUNNING", "universe_count": int(universe_count),
            "started_at": datetime.now(timezone.utc).isoformat(), "config": config,
        }).execute()

    def update_run_progress(self, run_id: str, attempted_count: int, current_ticker: str) -> None:
        """Best-effort heartbeat; compatible with databases before telemetry migration."""
        try:
            self.client.table("flow_scan_runs").update({
                "attempted_count": int(attempted_count),
                "current_ticker": canonical_ticker(current_ticker),
                "heartbeat_at": datetime.now(timezone.utc).isoformat(),
            }).eq("id", run_id).execute()
        except Exception:
            pass

    def save_results(self, run_id: str, frame: pd.DataFrame) -> None:
        if frame is None or frame.empty:
            return
        records=[]
        for row in frame.to_dict("records"):
            records.append({
                "run_id": run_id, "ticker": row["ticker"], "as_of_date": row["as_of_date"],
                "final_score": row["final_score"], "phase": row["phase"], "action": row["action"],
                "evidence_tier": row["evidence_tier"], "evidence_coverage_pct": row["evidence_coverage_pct"],
                "real_money_state": row["real_money_state"], "distribution_risk": row["distribution_risk"],
                "estimated_smart_money_cost": row.get("estimated_smart_money_cost"),
                "premium_to_cost_pct": row.get("premium_to_cost_pct"),
                "entry_low": row.get("entry_low"), "entry_high": row.get("entry_high"),
                "invalidation": row.get("invalidation"), "tp1": row.get("tp1"), "tp2": row.get("tp2"),
                "components": {k: row.get(k) for k in (
                    "accumulation_score", "operator_dominance_score", "cost_basis_score",
                    "retail_exhaustion_score", "supply_concentration_score",
                    "price_flow_divergence_score", "smc_execution_score", "risk_liquidity_score")},
                "diagnostics": row.get("diagnostics", {}), "guardrail_reason": row.get("guardrail_reason"),
            })
        for i in range(0, len(records), 500):
            self.client.table("flow_scan_results").upsert(records[i:i+500], on_conflict="run_id,ticker").execute()

    def finish_run(
        self,
        run_id: str,
        processed_count: int,
        error_count: int,
        *,
        status: str = "COMPLETED",
        attempted_count: int | None = None,
        telemetry: dict[str, int] | None = None,
    ) -> None:
        base = {
            "status": status,
            "processed_count": int(processed_count),
            "error_count": int(error_count),
            "completed_at": datetime.now(timezone.utc).isoformat(),
        }
        extended = dict(base)
        if attempted_count is not None:
            extended["attempted_count"] = int(attempted_count)
        extended["heartbeat_at"] = datetime.now(timezone.utc).isoformat()
        extended["current_ticker"] = None
        if telemetry:
            for key in ("price_cache_hits", "price_fetched", "price_failures"):
                if key in telemetry:
                    extended[key] = int(telemetry[key])
        try:
            self.client.table("flow_scan_runs").update(extended).eq("id", run_id).execute()
        except Exception:
            self.client.table("flow_scan_runs").update(base).eq("id", run_id).execute()

    def upsert_broker_flows(self, frame: pd.DataFrame) -> int:
        b = normalize_broker_summary(frame)
        if b.empty: return 0
        cols=["ticker","trade_date","broker_code","market_type","buy_value","sell_value","buy_volume","sell_volume","buy_avg","sell_avg","source"]
        rows=_records(b[cols])
        for i in range(0,len(rows),500):
            self.client.table("flow_broker_flows").upsert(
                rows[i:i+500], on_conflict="ticker,trade_date,broker_code,market_type,source"
            ).execute()
        return len(rows)

    def load_broker_flows(self, tickers: Iterable[str], lookback_calendar_days: int = 120) -> pd.DataFrame:
        names=list(dict.fromkeys(canonical_ticker(t) for t in tickers if canonical_ticker(t)))
        if not names: return pd.DataFrame()
        since=(date.today()-timedelta(days=int(lookback_calendar_days))).isoformat()
        all_rows=[]
        for i in range(0,len(names),40):
            chunk=names[i:i+40]
            resp=(self.client.table("flow_broker_flows").select(
                "ticker,trade_date,broker_code,buy_value,sell_value,buy_volume,sell_volume,buy_avg,sell_avg,market_type,source"
            ).in_("ticker",chunk).gte("trade_date",since).order("trade_date").execute())
            all_rows.extend(resp.data or [])
        return normalize_broker_summary(pd.DataFrame(all_rows)) if all_rows else pd.DataFrame()

    def upsert_prices(self, ticker: str, frame: pd.DataFrame, source: str = "YFINANCE") -> int:
        p=normalize_price_frame(frame,ticker)
        if p.empty: return 0
        rows=[]
        for row in p.to_dict("records"):
            close=float(row["close"])
            volume=row.get("volume")
            rows.append({
                "ticker":canonical_ticker(ticker), "trade_date":pd.Timestamp(row["date"]).date().isoformat(),
                "open":row.get("open"), "high":row.get("high"), "low":row.get("low"), "close":close,
                "volume":volume, "traded_value":float(close*volume) if pd.notna(volume) else None, "source":source,
            })
        for i in range(0,len(rows),500):
            self.client.table("flow_daily_prices").upsert(rows[i:i+500],on_conflict="ticker,trade_date,source").execute()
        return len(rows)

    def _load_legacy_price_cache(self, ticker: str, min_rows: int, limit: int) -> pd.DataFrame:
        t=canonical_ticker(ticker)
        try:
            resp=(self.client.table("ohlcv_daily_cache")
                  .select("ticker,payload_compact,payload_codec,last_bar_date")
                  .in_("ticker", [t, f"{t}.JK"])
                  .order("last_bar_date", desc=True)
                  .limit(1).execute())
            rows=resp.data or []
            if not rows:
                return pd.DataFrame()
            row=rows[0]
            frame=decode_legacy_ohlcv_compact(row.get("payload_compact"), row.get("payload_codec"), t)
            if len(frame) < min_rows:
                return pd.DataFrame()
            frame=frame.tail(int(limit)).reset_index(drop=True)
            try:
                self.upsert_prices(t, frame, source="LEGACY_SUPER_CACHE")
            except Exception:
                pass
            return frame
        except Exception:
            return pd.DataFrame()

    def load_prices(self, ticker: str, min_rows: int = 80, limit: int = 450) -> pd.DataFrame:
        t=canonical_ticker(ticker)
        resp=(self.client.table("flow_daily_prices").select("trade_date,open,high,low,close,volume")
              .eq("ticker",t).order("trade_date",desc=True).limit(int(limit)).execute())
        rows=resp.data or []
        if len(rows)>=min_rows:
            f=pd.DataFrame(rows).rename(columns={"trade_date":"date"})
            return normalize_price_frame(f,t)
        if self.enable_legacy_cache:
            return self._load_legacy_price_cache(t, min_rows=min_rows, limit=limit)
        return pd.DataFrame()

    def prune_history(self, *, scan_days: int = 45, broker_days: int = 150, price_days: int = 550) -> None:
        now=date.today()
        self.client.table("flow_scan_runs").delete().lt("started_at", (now-timedelta(days=scan_days)).isoformat()).execute()
        self.client.table("flow_broker_flows").delete().lt("trade_date", (now-timedelta(days=broker_days)).isoformat()).execute()
        self.client.table("flow_daily_prices").delete().lt("trade_date", (now-timedelta(days=price_days)).isoformat()).execute()
