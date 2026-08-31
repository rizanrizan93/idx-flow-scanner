import re
from pathlib import Path


TELEMETRY_MIGRATION = Path(
    "supabase/migrations/20260831090000_completed_partial_run_evidence_telemetry.sql"
)


def test_scan_run_status_schema_distinguishes_partial_completion():
    text = Path("supabase/migrations/20260829043800_allow_completed_partial_status.sql").read_text()
    assert "COMPLETED_PARTIAL" in text
    assert "status not in ('COMPLETED','COMPLETED_PARTIAL')" in text


def test_run_evidence_telemetry_includes_every_terminal_status_only():
    text = TELEMETRY_MIGRATION.read_text(encoding="utf-8")
    guard = re.search(
        r"if new\.status not in \(([^)]+)\) then\s+return new;\s+end if;",
        text,
    )

    assert guard is not None
    assert set(re.findall(r"'([^']+)'", guard.group(1))) == {
        "COMPLETED",
        "COMPLETED_PARTIAL",
        "FAILED",
        "CANCELLED",
    }
    assert "RUNNING" not in guard.group(1)


def test_run_evidence_telemetry_preserves_the_existing_function_body():
    historical = Path(
        "supabase/migrations/20260816150444_run_evidence_telemetry_v032.sql"
    ).read_text(encoding="utf-8")
    historical_function = historical.split(
        "\n\nrevoke all on function public.flow_populate_run_evidence_telemetry()", 1
    )[0]
    expected = historical_function.replace(
        "('COMPLETED','FAILED','CANCELLED')",
        "('COMPLETED','COMPLETED_PARTIAL','FAILED','CANCELLED')",
    )

    assert TELEMETRY_MIGRATION.read_text(encoding="utf-8").strip() == expected.strip()
