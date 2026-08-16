from datetime import datetime, timedelta, timezone

from idx_flow_scanner.managed import decide_managed_run, universe_signature


def _run(status, minutes_ago, processed, version="0.1.3", sig="abc", count=400):
    now = datetime(2026, 8, 16, 1, 0, tzinfo=timezone.utc)
    stamp = now - timedelta(minutes=minutes_ago)
    return {
        "id": f"run-{status}-{minutes_ago}",
        "status": status,
        "universe_count": count,
        "processed_count": processed,
        "started_at": stamp.isoformat(),
        "completed_at": stamp.isoformat() if status != "RUNNING" else None,
        "heartbeat_at": stamp.isoformat(),
        "config": {"mode": "managed", "version": version, "universe_signature": sig},
    }


def test_managed_gate_blocks_fresh_success():
    now = datetime(2026, 8, 16, 1, 0, tzinfo=timezone.utc)
    d = decide_managed_run([_run("COMPLETED", 10, 395)], version="0.1.3", universe_count=400, signature="abc", now=now)
    assert d.should_run is False
    assert "valid" in d.reason


def test_managed_gate_retries_old_failure():
    now = datetime(2026, 8, 16, 1, 0, tzinfo=timezone.utc)
    d = decide_managed_run([_run("FAILED", 40, 0)], version="0.1.3", universe_count=400, signature="abc", now=now)
    assert d.should_run is True


def test_managed_gate_blocks_fresh_running():
    now = datetime(2026, 8, 16, 1, 0, tzinfo=timezone.utc)
    d = decide_managed_run([_run("RUNNING", 5, 0)], version="0.1.3", universe_count=400, signature="abc", now=now)
    assert d.should_run is False
    assert "running" in d.reason


def test_universe_signature_stable_and_order_sensitive():
    assert universe_signature(["ABMM", "ELSA"]) == universe_signature(["ABMM", "ELSA"])
    assert universe_signature(["ABMM", "ELSA"]) != universe_signature(["ELSA", "ABMM"])
