from __future__ import annotations

import json
from pathlib import Path

import pandas as pd


def test_ksei_history_mirror_contract() -> None:
    path = Path("data/cache/ksei_ownership_history_2026.json")
    assert path.exists()
    rows = json.loads(path.read_text(encoding="utf-8"))
    frame = pd.DataFrame(rows)

    assert len(frame) >= 22_000
    assert frame["ticker"].nunique() == 700
    assert frame["report_date"].nunique() == 8
    assert frame["provenance_state"].eq("VERIFIED_KSEI_REGISTRATION_COMPOSITION").all()
    assert frame["source_verified"].eq(True).all()

    latest = frame[frame["report_date"].eq("2026-08-31")]
    assert latest["ticker"].nunique() == 700
    per_ticker = latest.groupby("ticker")["holder_classification"].nunique()
    assert (per_ticker == 4).all()

    pct = pd.to_numeric(frame["ownership_percentage"], errors="coerce")
    assert pct.dropna().between(0, 100).all()

    foreign = frame[frame["holder_classification"].eq("KSEI_FOREIGN_TOTAL")]
    months = foreign.groupby("ticker")["report_date"].nunique()
    assert (months >= 2).sum() == 700
