from pathlib import Path


def test_scan_run_status_schema_distinguishes_partial_completion():
    text = Path("supabase/migrations/20260829043800_allow_completed_partial_status.sql").read_text()
    assert "COMPLETED_PARTIAL" in text
    assert "status not in ('COMPLETED','COMPLETED_PARTIAL')" in text
