from __future__ import annotations

from types import SimpleNamespace

import pandas as pd

import idx_flow_scanner.universe_broker_guard as guard


def test_load_universe_idx_broker_is_empty_without_cache(tmp_path, monkeypatch):
    monkeypatch.setattr(guard, "_root", lambda: tmp_path)
    result = guard.load_universe_idx_broker(["MMIX"])
    assert result.empty


def test_install_universe_wide_idx_broker_injects_official_rows(monkeypatch):
    official = pd.DataFrame([
        {
            "ticker": "MMIX",
            "trade_date": "2026-08-14",
            "broker_code": "YP",
            "buy_value": 10_000_000,
            "sell_value": 3_000_000,
            "source": "IDX_OFFICIAL_BROKER_SUMMARY",
            "source_verified": True,
        }
    ])
    captured = {}

    monkeypatch.setattr(guard, "load_universe_idx_broker", lambda universe: official.copy())
    monkeypatch.setattr(guard, "select_broker_evidence", lambda frame: (frame, {"selected": len(frame)}))

    def scan(*args, **kwargs):
        captured["broker_frame"] = args[2]
        return "ok"

    def finalist_loader(*args, **kwargs):
        return pd.DataFrame(), {"status": "CACHE_ONLY"}

    app = SimpleNamespace(scan_universe=scan, _load_indexalpha_for_finalists=finalist_loader)
    guard.install_universe_wide_idx_broker(app)

    result = app.scan_universe(["MMIX"], lambda _: pd.DataFrame(), pd.DataFrame())
    assert result == "ok"
    assert captured["broker_frame"].iloc[0]["source"] == "IDX_OFFICIAL_BROKER_SUMMARY"
